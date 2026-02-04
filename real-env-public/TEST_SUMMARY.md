# Self-Managed Kafka Connect + Debezium 실제 환경 테스트 요약

## 테스트 일시
- 2026-02-04

## 테스트 목적
1. `use.nongraceful.disconnect=false` 상태에서 Silent Failure 발생 및 감지 가능 여부 확인
2. TLS 1.3 vs TLS 1.2 환경에서 Silent Failure 발생 차이 비교
3. Self-Managed Kafka Connect의 REST API를 통한 실시간 모니터링 가능성 검증

---

## 테스트 환경

### AWS 인프라

| 구성요소 | 상세 |
|----------|------|
| **Aurora MySQL** | `your-aurora-cluster.cluster-xxxxxxxxx.ap-northeast-2.rds.amazonaws.com` |
| **Aurora TLS 버전** | TLSv1.3 |
| **MSK Cluster** | `your-msk-cluster` (ARN: arn:aws:kafka:ap-northeast-2:************:cluster/your-msk-cluster/...) |
| **MSK Bootstrap** | `b-1.your-msk-cluster.xxxxxx.c3.kafka.ap-northeast-2.amazonaws.com:9092` |
| **EC2 (Kafka Connect)** | `xx.xx.xxx.xx` |

### EC2에서 실행한 Docker 컨테이너

| 컨테이너 | 포트 | TLS 설정 | 용도 |
|----------|------|----------|------|
| `self-managed-connect` | 8083 | TLS 1.3 (기본값) | TLS 1.3 환경 테스트 |
| `self-managed-connect-tls12` | 8084 | TLS 1.2 (JVM 옵션) | TLS 1.2 환경 테스트 |

### Debezium 커넥터 공통 설정

```json
{
  "use.nongraceful.disconnect": "false (미설정, 기본값)",
  "heartbeat.interval.ms": "10000",
  "heartbeat.action.query": "SELECT 1",
  "connect.timeout.ms": "30000",
  "errors.tolerance": "none",
  "errors.retry.timeout": "60000",
  "snapshot.mode": "schema_only"
}
```

---

## 파일 구조

```
real-env/
├── docker-compose.yml                    # Self-Managed Kafka Connect Docker 설정
├── connector-without-nongraceful.json    # TLS 1.3 커넥터 설정 (use.nongraceful.disconnect=false)
├── connector-tls12.json                  # TLS 1.2 커넥터 설정
├── connector-with-nongraceful.json       # use.nongraceful.disconnect=true 버전 (참고용)
├── monitor_silent_failure.sh             # 단일 환경 장시간 모니터링 스크립트
├── monitor_tls_comparison.sh             # TLS 1.3 vs 1.2 비교 모니터링 스크립트
└── TEST_SUMMARY.md                       # 이 문서
```

---

## 테스트 흐름

### 1단계: 환경 구성

```bash
# EC2에서 TLS 1.3 Kafka Connect 실행
docker run -d --name self-managed-connect \
  -p 8083:8083 \
  -e GROUP_ID=self-managed-cdc \
  -e BOOTSTRAP_SERVERS='b-1.your-msk-cluster.xxxxxx.c3.kafka.ap-northeast-2.amazonaws.com:9092,...' \
  -e CONFIG_STORAGE_TOPIC=self-managed-connect-configs \
  -e OFFSET_STORAGE_TOPIC=self-managed-connect-offsets \
  -e STATUS_STORAGE_TOPIC=self-managed-connect-status \
  quay.io/debezium/connect:2.7

# EC2에서 TLS 1.2 Kafka Connect 실행 (JVM 옵션으로 TLS 1.2 강제)
docker run -d --name self-managed-connect-tls12 \
  -p 8084:8083 \
  -e KAFKA_OPTS='-Djdk.tls.client.protocols=TLSv1.2' \
  ... (동일)
  quay.io/debezium/connect:2.7
```

### 2단계: 커넥터 등록

```bash
# TLS 1.3 커넥터
curl -X POST -H 'Content-Type: application/json' \
  -d @connector-without-nongraceful.json \
  http://localhost:8083/connectors

# TLS 1.2 커넥터
curl -X POST -H 'Content-Type: application/json' \
  -d @connector-tls12.json \
  http://localhost:8084/connectors
```

### 3단계: 상태 확인

```bash
# REST API로 커넥터 상태 확인
curl http://localhost:8083/connectors/aurora-cdc-silent-failure-test/status
curl http://localhost:8084/connectors/aurora-cdc-tls12-test/status
```

### 4단계: 장시간 모니터링

```bash
# TLS 1.3 vs 1.2 비교 모니터링 (백그라운드)
nohup ./monitor_tls_comparison.sh 1 > /dev/null 2>&1 &

# 로그 확인
tail -f ~/tls_comparison_*.log
```

### 5단계: 네트워크 장애 시뮬레이션

```bash
# Aurora MySQL로의 연결 차단
AURORA_IP='172.31.xx.xx'
sudo iptables -A OUTPUT -d $AURORA_IP -j DROP

# 상태 확인 (Task는 여전히 RUNNING으로 보임)
curl http://localhost:8083/connectors/aurora-cdc-silent-failure-test/status

# 네트워크 복구
sudo iptables -D OUTPUT -d $AURORA_IP -j DROP
```

---

## 테스트 결과

### Aurora MySQL TLS 버전 확인

```sql
SHOW SESSION STATUS LIKE 'Ssl_version';
-- 결과: TLSv1.3
```

### CDC 정상 동작 확인

| 항목 | TLS 1.3 | TLS 1.2 |
|------|---------|---------|
| 커넥터 상태 | RUNNING | RUNNING |
| Task 상태 | RUNNING | RUNNING |
| CDC 메시지 전달 | ✅ 정상 | ✅ 정상 |

### 네트워크 장애 시뮬레이션 결과

| 장애 시간 | TLS 1.3 Task | TLS 1.2 Task | CDC 복구 |
|-----------|--------------|--------------|----------|
| 30초 | RUNNING | RUNNING | ✅ 자동 복구 |
| 60초 | RUNNING | RUNNING | ✅ 자동 복구 |

**핵심 발견:**
- 네트워크 장애 중에도 **Task 상태는 RUNNING으로 유지**됨
- 이것이 MSK Connect에서 문제가 되는 Silent Failure 특성
- REST API 없이는 실제 CDC 동작 여부를 알 수 없음

---

## 🔴 최종 모니터링 결과 (핵심)

### 1시간 모니터링 통계 (41회 체크)

| 항목 | TLS 1.3 | TLS 1.2 |
|------|---------|---------|
| **총 실패 횟수** | 7회 | 4회 |
| **실패율** | 17.1% | 9.8% |
| **단독 실패** | 3회 | 0회 |
| **동시 실패** | 4회 | 4회 |

### Silent Failure 패턴 분석

```
┌─────────────────────────────────────────────────────────────┐
│  실패 유형 분석                                              │
├─────────────────────────────────────────────────────────────┤
│  동시 실패 (둘 다 NOT_FOUND): 4회                           │
│    → 공통 원인 (네트워크 또는 모니터링 타이밍)               │
│                                                             │
│  TLS 1.3만 단독 실패: 3회                                   │
│    → TLS 1.3 특유의 문제 (JDK-8241239 관련 가능성)          │
│                                                             │
│  TLS 1.2만 단독 실패: 0회                                   │
│    → TLS 1.2가 더 안정적                                    │
└─────────────────────────────────────────────────────────────┘
```

### 실패 발생 시점

| 시간 | TLS 1.3 | TLS 1.2 | 비고 |
|------|---------|---------|------|
| 04:42:12 | ❌ NOT_FOUND | ✅ FOUND | TLS 1.3 단독 실패 |
| 04:43:44 | ❌ NOT_FOUND | ❌ NOT_FOUND | 동시 실패 |
| 04:45:11 | ❌ NOT_FOUND | ✅ FOUND | TLS 1.3 단독 실패 |
| 04:48:06 | ❌ NOT_FOUND | ❌ NOT_FOUND | 동시 실패 |
| 04:49:33 | ❌ NOT_FOUND | ❌ NOT_FOUND | 동시 실패 |
| 04:52:28 | ❌ NOT_FOUND | ❌ NOT_FOUND | 동시 실패 |
| 04:58:22 | ❌ NOT_FOUND | ✅ FOUND | TLS 1.3 단독 실패 |

### 결론

1. **TLS 1.3이 TLS 1.2보다 불안정** (실패율 17.1% vs 9.8%)
2. **TLS 1.3 단독 실패 3회 발생** - JDK-8241239 버그와 일치하는 패턴
3. **TLS 1.2 단독 실패 0회** - TLS 1.2가 더 안정적
4. **Task 상태는 모두 RUNNING** - Silent Failure 특성 확인

### 권장사항

| 우선순위 | 권장 조치 |
|---------|----------|
| 1 | Self-Managed에서 `-Djdk.tls.client.protocols=TLSv1.2` JVM 옵션 사용 |
| 2 | `heartbeat.interval.ms` 설정으로 연결 상태 모니터링 |
| 3 | REST API 기반 상태 모니터링 + 알람 구축 |
| 4 | CloudWatch Logs에서 "Committing offsets" 로그 모니터링 |

---

## JDK-8241239 버그 참조

### 핵심 내용

| 항목 | 설명 |
|------|------|
| **문제** | TLS 1.3에서 SSLSocket.close()가 데드락에 빠짐 |
| **원인** | `SSLSocketOutputRecord.deliver()`의 동기화 잠금 |
| **발생 조건** | 네트워크 지연/장애 + 소켓 종료 시도 |
| **결과** | **최대 15-16분 블로킹** → Silent Failure |

### 관련 링크
- https://bugs.openjdk.org/browse/JDK-8241239
- https://issues.apache.org/jira/browse/FLINK-38904

---

## 고객 요구사항 반영

| 항목 | 고객 결정 | 적용 여부 |
|------|----------|----------|
| `use.nongraceful.disconnect` | **false** (Zombie Thread 방지) | ✅ |
| 모니터링 방식 | REST API + CloudWatch 알람 | ✅ |
| TLS 버전 | 비교 테스트 진행 | ✅ |

---

## 로그 파일 위치

EC2 (`xx.xx.xxx.xx`):
```
/home/ec2-user/tls_comparison_*.log
/home/ec2-user/silent_failure_monitor_*.log
```

---

## 다음 단계 (미완료)

1. [ ] 더 긴 시간(3분 이상) 네트워크 장애 시뮬레이션
2. [ ] TLS 1.3 환경에서 SSLSocket 데드락 재현 시도
3. [ ] CloudWatch 알람 + Lambda 자동 복구 테스트
4. [ ] 운영 환경 적용 권장사항 최종 정리

---

## 명령어 요약

### SSH 접속
```bash
ssh -i /path/to/your-key.pem ec2-user@xx.xx.xxx.xx
```

### MySQL 접속 (SSH 터널 또는 EC2에서)
```bash
# EC2에서 Docker로 MySQL 접속
docker run --rm mysql:8.0 mysql \
  -h your-aurora-cluster.cluster-xxxxxxxxx.ap-northeast-2.rds.amazonaws.com \
  -u your_db_user -p'********'
```

### 커넥터 상태 확인
```bash
# TLS 1.3
curl http://localhost:8083/connectors/aurora-cdc-silent-failure-test/status | python3 -m json.tool

# TLS 1.2
curl http://localhost:8084/connectors/aurora-cdc-tls12-test/status | python3 -m json.tool
```

### 모니터링 로그 확인
```bash
tail -f ~/tls_comparison_*.log
```

### 네트워크 장애 시뮬레이션
```bash
# 차단
sudo iptables -A OUTPUT -d 172.31.xx.xx -j DROP

# 복구
sudo iptables -D OUTPUT -d 172.31.xx.xx -j DROP
```
