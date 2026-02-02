#!/usr/bin/env python3
"""
MSK Connect Debezium Silent Failure 감지/복구 데모

3개의 독립 스레드가 동시에 동작합니다:
  [커넥터]  - 정상 producing → 랜덤 시점에 silent failure 발생
  [모니터]  - 주기적으로 메트릭을 폴링하여 이상 감지
  [복구]    - 모니터가 알람을 발생시키면 자동으로 커넥터 재시작

모니터는 커넥터의 내부 상태를 모릅니다.
오직 외부에서 관찰 가능한 메트릭(Connected, offset commit 시간)만 봅니다.

실행: python3 simulate_silent_failure.py
"""

import time
import threading
import random
from datetime import datetime
from enum import Enum


# ─────────────────────────────────────────────
# 색상 (터미널 출력용)
# ─────────────────────────────────────────────
class C:
    RESET = "\033[0m"
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    CYAN = "\033[96m"
    DIM = "\033[2m"
    BOLD = "\033[1m"


lock = threading.Lock()


def log(tag, color, msg):
    timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    with lock:
        print(f"{C.DIM}[{timestamp}]{C.RESET} {color}[{tag:^10}]{C.RESET} {msg}")


# ─────────────────────────────────────────────
# 커넥터 시뮬레이터
# ─────────────────────────────────────────────
class ConnectorState(Enum):
    RUNNING = "RUNNING"
    SILENT_FAILURE = "SILENT_FAILURE"
    RESTARTING = "RESTARTING"


class DebeziumConnector:
    def __init__(self):
        self._state = ConnectorState.RUNNING
        self._lock = threading.Lock()
        # 외부에서 관찰 가능한 메트릭 (CloudWatch에 해당)
        self.connected_metric = 1
        self.last_offset_commit = datetime.now()
        self.total_messages = 0
        self.restart_count = 0

    def get_api_status(self):
        """MSK Connect API 반환값 — silent failure여도 RUNNING"""
        return "RUNNING" if self._state != ConnectorState.RESTARTING else "RESTARTING"

    @property
    def is_healthy(self):
        return self._state == ConnectorState.RUNNING

    def produce_tick(self):
        """1초마다 호출됨"""
        if self._state == ConnectorState.RUNNING:
            n = random.randint(50, 200)
            self.total_messages += n
            self.last_offset_commit = datetime.now()
            return n
        return 0

    def trigger_silent_failure(self):
        with self._lock:
            self._state = ConnectorState.SILENT_FAILURE
            self.connected_metric = 0

    def restart(self):
        with self._lock:
            self._state = ConnectorState.RESTARTING
            self.connected_metric = 0
        time.sleep(3)  # 재시작 소요
        with self._lock:
            self._state = ConnectorState.RUNNING
            self.connected_metric = 1
            self.restart_count += 1


# ─────────────────────────────────────────────
# 스레드 1: 커넥터 (producing + 랜덤 장애)
# ─────────────────────────────────────────────
def connector_thread(connector: DebeziumConnector, stop_event: threading.Event):
    """
    정상 producing을 하다가 랜덤 시점에 silent failure 발생.
    장애는 외부에서 복구해줘야 다시 동작함.
    """
    failure_triggered = False
    tick = 0

    while not stop_event.is_set():
        tick += 1

        # 8~15초 사이 랜덤 시점에 silent failure 발생
        if not failure_triggered and tick >= random.randint(8, 15) and connector.is_healthy:
            log("Connector", C.RED,
                f"{C.BOLD}SILENT FAILURE 발생! "
                f"(내부 상태 변경, 에러 로그 없음){C.RESET}")
            connector.trigger_silent_failure()
            failure_triggered = True

        n = connector.produce_tick()
        if n > 0:
            log("Connector", C.GREEN,
                f"Committing offsets for {n} msgs "
                f"| API status: {connector.get_api_status()} "
                f"| Connected: {connector.connected_metric}")
        else:
            # silent failure 상태 — 아무것도 출력 안 함 (실제와 동일)
            # 다만 데모 가시성을 위해 dim으로 표시
            log("Connector", C.DIM,
                f"(silence)  msgs: 0 "
                f"| API status: {connector.get_api_status()} "
                f"| Connected: {connector.connected_metric}")

        # 복구 후 다시 failure cycle 시작
        if failure_triggered and connector.is_healthy:
            failure_triggered = False
            tick = 0

        time.sleep(1)


# ─────────────────────────────────────────────
# 스레드 2: 모니터 (CloudWatch 알람 시뮬레이션)
# ─────────────────────────────────────────────
def monitor_thread(connector: DebeziumConnector, alarm_event: threading.Event,
                   stop_event: threading.Event):
    """
    커넥터 내부 상태를 모름.
    오직 외부 메트릭만 폴링:
      1) Connected 메트릭 == 0
      2) last_offset_commit이 N초 이상 지남
    """
    POLL_INTERVAL = 2        # 폴링 주기 (초)
    OFFSET_THRESHOLD = 5     # offset commit 없으면 알람 (초)
    alarm_active = False

    while not stop_event.is_set():
        connected = connector.connected_metric
        offset_age = (datetime.now() - connector.last_offset_commit).total_seconds()

        # 정상
        if connected == 1 and offset_age < OFFSET_THRESHOLD:
            if alarm_active:
                log("Monitor", C.CYAN,
                    f"OK — Connected: {connected}, Offset age: {offset_age:.0f}s "
                    f"→ 알람 해제")
                alarm_active = False
            else:
                log("Monitor", C.DIM,
                    f"OK — Connected: {connected}, Offset age: {offset_age:.0f}s")

        # 이상 감지!
        else:
            reasons = []
            if connected == 0:
                reasons.append(f"Connected=0")
            if offset_age >= OFFSET_THRESHOLD:
                reasons.append(f"Offset commit {offset_age:.0f}s 지연")

            if not alarm_active:
                log("Monitor", C.RED,
                    f"{C.BOLD}ALARM! {', '.join(reasons)} "
                    f"→ EventBridge로 Lambda 트리거{C.RESET}")
                alarm_active = True
                alarm_event.set()  # 복구 스레드에 신호
            else:
                log("Monitor", C.YELLOW,
                    f"ALARM 지속 — {', '.join(reasons)}")

        time.sleep(POLL_INTERVAL)


# ─────────────────────────────────────────────
# 스레드 3: 자동 복구 (Lambda 시뮬레이션)
# ─────────────────────────────────────────────
def recovery_thread(connector: DebeziumConnector, alarm_event: threading.Event,
                    stop_event: threading.Event):
    """
    alarm_event가 set되면 커넥터를 재시작.
    실제 환경: EventBridge → Lambda → MSK Connect API
    """
    while not stop_event.is_set():
        # 알람 신호 대기
        triggered = alarm_event.wait(timeout=1)
        if not triggered:
            continue
        alarm_event.clear()

        log("Lambda", C.YELLOW,
            f"알람 수신! 커넥터 상태 확인: API={connector.get_api_status()}, "
            f"Connected={connector.connected_metric}")
        log("Lambda", C.YELLOW, "커넥터 삭제/재생성 시작...")

        connector.restart()

        log("Lambda", C.GREEN,
            f"{C.BOLD}커넥터 복구 완료! "
            f"(재시작 #{connector.restart_count}){C.RESET}")


# ─────────────────────────────────────────────
# 메인
# ─────────────────────────────────────────────
def main():
    print()
    print(f"{C.BOLD}{'=' * 65}")
    print(f"  MSK Connect Debezium Silent Failure — 감지/복구 실시간 데모")
    print(f"{'=' * 65}{C.RESET}")
    print()
    print(f"  3개의 독립 스레드가 동시에 동작합니다:")
    print(f"    {C.GREEN}[Connector]{C.RESET}  정상 producing → 랜덤 시점에 silent failure")
    print(f"    {C.CYAN}[ Monitor ]{C.RESET}  외부 메트릭만 폴링하여 이상 감지")
    print(f"    {C.YELLOW}[  Lambda ]{C.RESET}  알람 수신 시 자동 복구")
    print()
    print(f"  모니터는 커넥터 내부 상태를 {C.BOLD}모릅니다{C.RESET}.")
    print(f"  오직 Connected 메트릭과 offset commit 시간만 관찰합니다.")
    print()
    print(f"  {C.DIM}Ctrl+C로 종료{C.RESET}")
    print(f"{C.BOLD}{'-' * 65}{C.RESET}")
    print()

    connector = DebeziumConnector()
    alarm_event = threading.Event()
    stop_event = threading.Event()

    threads = [
        threading.Thread(target=connector_thread,
                         args=(connector, stop_event), daemon=True),
        threading.Thread(target=monitor_thread,
                         args=(connector, alarm_event, stop_event), daemon=True),
        threading.Thread(target=recovery_thread,
                         args=(connector, alarm_event, stop_event), daemon=True),
    ]

    for t in threads:
        t.start()

    try:
        # 40초 동작 (silent failure → 복구 사이클 2~3회 관찰 가능)
        time.sleep(40)
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        for t in threads:
            t.join(timeout=3)

    print()
    print(f"{C.BOLD}{'=' * 65}")
    print(f"  데모 종료 — 결과 요약")
    print(f"{'=' * 65}{C.RESET}")
    print(f"  총 생산 메시지:     {connector.total_messages:,}")
    print(f"  자동 복구 횟수:     {connector.restart_count}")
    print(f"  감지 방법:          Connected 메트릭 + Offset commit 지연")
    print(f"  Zombie Thread:     없음 (use.nongraceful.disconnect 미사용)")
    print()


if __name__ == "__main__":
    main()
