#!/usr/bin/env python3
"""
MSK Connect vs Self-Managed Kafka Connect 비교 시뮬레이션

Docker 없이 실행 가능한 시뮬레이션입니다.
두 환경에서 동일한 Silent Failure가 발생했을 때 감지/복구 시간을 비교합니다.

실행: python3 simulate_comparison.py
"""

import time
import threading
import random
from datetime import datetime
from enum import Enum


class C:
    RESET = "\033[0m"
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    CYAN = "\033[96m"
    MAGENTA = "\033[95m"
    DIM = "\033[2m"
    BOLD = "\033[1m"


lock = threading.Lock()


def log(tag, color, msg):
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    with lock:
        print(f"{C.DIM}[{ts}]{C.RESET} {color}[{tag:^16}]{C.RESET} {msg}")


# ─────────────────────────────────────────────
# 커넥터 시뮬레이터
# ─────────────────────────────────────────────
class Connector:
    def __init__(self, name):
        self.name = name
        self.running = True
        self.task_state = "RUNNING"  # REST API로 조회 가능 (self-managed만)
        self.connected_metric = 1     # CloudWatch 메트릭
        self.last_offset = datetime.now()
        self.total_msgs = 0
        self.restarts = 0
        self._lock = threading.Lock()

    def tick(self):
        if self.running and self.task_state == "RUNNING":
            n = random.randint(50, 200)
            self.total_msgs += n
            self.last_offset = datetime.now()
            return n
        return 0

    def silent_failure(self):
        with self._lock:
            self.running = False
            self.task_state = "FAILED"  # Self-managed에서는 이걸 볼 수 있음
            self.connected_metric = 0

    def restart_task(self):
        """Self-managed: Task 단위 재시작 (수초)"""
        with self._lock:
            self.task_state = "RESTARTING"
        time.sleep(1)  # Task 재시작은 빠름
        with self._lock:
            self.running = True
            self.task_state = "RUNNING"
            self.connected_metric = 1
            self.restarts += 1

    def recreate_connector(self):
        """MSK Connect: 커넥터 삭제/재생성 (느림)"""
        with self._lock:
            self.task_state = "DELETING"
        time.sleep(5)  # 삭제 대기
        time.sleep(3)  # 재생성 대기
        with self._lock:
            self.running = True
            self.task_state = "RUNNING"
            self.connected_metric = 1
            self.restarts += 1


# ─────────────────────────────────────────────
# MSK Connect 방식: CloudWatch 메트릭 폴링 → Lambda → 재생성
# ─────────────────────────────────────────────
def msk_connect_monitor(conn, alarm, stop):
    """CloudWatch 알람 시뮬레이션 (Period=60s, EvalPeriods=2)"""
    POLL = 3  # 데모용 (실제: 60초)
    THRESHOLD = 6  # 데모용 (실제: 2분)
    alarm_active = False

    while not stop.is_set():
        offset_age = (datetime.now() - conn.last_offset).total_seconds()

        if conn.connected_metric == 0 or offset_age >= THRESHOLD:
            if not alarm_active:
                log("MSK-Monitor", C.RED,
                    f"{C.BOLD}ALARM! Connected={conn.connected_metric}, "
                    f"Offset age={offset_age:.0f}s → Lambda 트리거{C.RESET}")
                alarm_active = True
                alarm.set()
            else:
                log("MSK-Monitor", C.YELLOW,
                    f"ALARM 지속... (Connected={conn.connected_metric})")
        else:
            if alarm_active:
                log("MSK-Monitor", C.GREEN, "OK → 알람 해제")
                alarm_active = False
            else:
                log("MSK-Monitor", C.DIM,
                    f"OK — Connected={conn.connected_metric}")
        time.sleep(POLL)


def msk_connect_recovery(conn, alarm, stop):
    """Lambda → 커넥터 삭제/재생성"""
    while not stop.is_set():
        if not alarm.wait(timeout=1):
            continue
        alarm.clear()
        log("MSK-Lambda", C.YELLOW, "알람 수신! 커넥터 삭제/재생성 시작...")
        log("MSK-Lambda", C.YELLOW, "삭제 대기 중... (실제: 3~5분)")
        conn.recreate_connector()
        log("MSK-Lambda", C.GREEN,
            f"{C.BOLD}복구 완료! (재시작 #{conn.restarts}){C.RESET}")


# ─────────────────────────────────────────────
# Self-Managed 방식: REST API 폴링 → Task 재시작
# ─────────────────────────────────────────────
def self_managed_monitor(conn, alarm, stop):
    """REST API로 Task 상태 직접 조회"""
    POLL = 2

    while not stop.is_set():
        task_state = conn.task_state  # REST API: GET /connectors/.../status

        if task_state == "RUNNING":
            log("Self-Monitor", C.DIM,
                f"OK — task_state={task_state}")
        elif task_state == "FAILED":
            log("Self-Monitor", C.RED,
                f"{C.BOLD}FAILED 감지! task_state={task_state} "
                f"→ 즉시 Task 재시작{C.RESET}")
            alarm.set()
        else:
            log("Self-Monitor", C.YELLOW,
                f"task_state={task_state}")
        time.sleep(POLL)


def self_managed_recovery(conn, alarm, stop):
    """REST API → Task 단위 재시작"""
    while not stop.is_set():
        if not alarm.wait(timeout=1):
            continue
        alarm.clear()
        log("Self-Recovery", C.YELLOW,
            "POST /connectors/.../tasks/0/restart")
        conn.restart_task()
        log("Self-Recovery", C.GREEN,
            f"{C.BOLD}Task 복구 완료! (#{conn.restarts}) — 약 1초{C.RESET}")


# ─────────────────────────────────────────────
# 공통: 커넥터 producing + 랜덤 장애
# ─────────────────────────────────────────────
def connector_thread(conn, label, color, stop):
    tick = 0
    failed = False

    while not stop.is_set():
        tick += 1

        if not failed and tick >= random.randint(10, 15) and conn.task_state == "RUNNING":
            log(label, C.RED,
                f"{C.BOLD}SILENT FAILURE!{C.RESET}")
            conn.silent_failure()
            failed = True

        n = conn.tick()
        if n > 0:
            log(label, color,
                f"Producing {n} msgs | task={conn.task_state}")
        else:
            log(label, C.DIM,
                f"(silence) task={conn.task_state} "
                f"| API status=RUNNING")

        if failed and conn.task_state == "RUNNING":
            failed = False
            tick = 0

        time.sleep(1)


def run_side_by_side():
    print()
    print(f"{C.BOLD}{'=' * 72}")
    print(f"  MSK Connect vs Self-Managed Kafka Connect 비교 데모")
    print(f"{'=' * 72}{C.RESET}")
    print()
    print(f"  동일한 Debezium 커넥터에서 동일한 Silent Failure가 발생합니다.")
    print(f"  감지 방법과 복구 속도의 차이를 비교합니다.")
    print()
    print(f"  {C.MAGENTA}[MSK-*]{C.RESET}   CloudWatch 메트릭 → Lambda → 삭제/재생성 (느림)")
    print(f"  {C.CYAN}[Self-*]{C.RESET}  REST API → Task 재시작 (빠름)")
    print()
    print(f"  {C.DIM}Ctrl+C로 종료{C.RESET}")
    print(f"{C.BOLD}{'-' * 72}{C.RESET}")
    print()

    # MSK Connect 환경
    msk_conn = Connector("MSK-Connect")
    msk_alarm = threading.Event()

    # Self-Managed 환경
    self_conn = Connector("Self-Managed")
    self_alarm = threading.Event()

    stop = threading.Event()

    threads = [
        # MSK Connect 측
        threading.Thread(target=connector_thread,
                         args=(msk_conn, "MSK-Connector", C.MAGENTA, stop), daemon=True),
        threading.Thread(target=msk_connect_monitor,
                         args=(msk_conn, msk_alarm, stop), daemon=True),
        threading.Thread(target=msk_connect_recovery,
                         args=(msk_conn, msk_alarm, stop), daemon=True),
        # Self-Managed 측
        threading.Thread(target=connector_thread,
                         args=(self_conn, "Self-Connector", C.CYAN, stop), daemon=True),
        threading.Thread(target=self_managed_monitor,
                         args=(self_conn, self_alarm, stop), daemon=True),
        threading.Thread(target=self_managed_recovery,
                         args=(self_conn, self_alarm, stop), daemon=True),
    ]

    for t in threads:
        t.start()

    try:
        time.sleep(45)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        for t in threads:
            t.join(timeout=3)

    print()
    print(f"{C.BOLD}{'=' * 72}")
    print(f"  결과 비교")
    print(f"{'=' * 72}{C.RESET}")
    print()
    print(f"  {'':30} {C.MAGENTA}MSK Connect{C.RESET}    {C.CYAN}Self-Managed{C.RESET}")
    print(f"  {'─' * 60}")
    print(f"  {'감지 방법':30} CloudWatch       REST API")
    print(f"  {'감지 소요 (데모)':30} ~6초             ~2초")
    print(f"  {'감지 소요 (실제)':30} 2~5분            수초")
    print(f"  {'복구 방법':30} 삭제/재생성      Task 재시작")
    print(f"  {'복구 소요 (데모)':30} ~8초             ~1초")
    print(f"  {'복구 소요 (실제)':30} 5~10분           수초")
    print(f"  {C.BOLD}{'총 복구 시간 (실제)':30} 10~15분          ~10초{C.RESET}")
    print(f"  {'자동 복구 횟수':30} {msk_conn.restarts}                {self_conn.restarts}")
    print(f"  {'생산 메시지':30} {msk_conn.total_msgs:,}          {self_conn.total_msgs:,}")
    print(f"  {'Consumer 변경':30} 불필요           불필요")
    print(f"  {'Zombie Thread':30} 없음             없음")
    print()


if __name__ == "__main__":
    run_side_by_side()
