#!/bin/bash
# ============================================================
# TLS 1.3 vs TLS 1.2 Silent Failure 비교 모니터링
#
# 목적: 동일한 Aurora MySQL에 대해
#       TLS 1.3과 TLS 1.2 환경에서 Silent Failure 발생 차이 비교
#
# 사용법: ./monitor_tls_comparison.sh [duration_hours]
#         기본값: 24시간
# ============================================================

DURATION_HOURS=${1:-24}
INTERVAL_SECONDS=60
AURORA_HOST="your-aurora-cluster.cluster-xxxxxxxxx.ap-northeast-2.rds.amazonaws.com"
AURORA_USER="your_db_user"
AURORA_PASS="********"
KAFKA_BOOTSTRAP="b-1.your-msk-cluster.xxxxxx.c3.kafka.ap-northeast-2.amazonaws.com:9092"

# TLS 1.3 환경
TLS13_CONNECT_URL="http://localhost:8083"
TLS13_CONNECTOR="aurora-cdc-silent-failure-test"
TLS13_TOPIC="aurora-cdc.testdb.cdc_test"

# TLS 1.2 환경
TLS12_CONNECT_URL="http://localhost:8084"
TLS12_CONNECTOR="aurora-cdc-tls12-test"
TLS12_TOPIC="aurora-cdc-tls12.testdb.cdc_test"

LOG_FILE="/home/ec2-user/tls_comparison_$(date +%Y%m%d_%H%M%S).log"
TLS13_FAILURES=0
TLS12_FAILURES=0
TEST_COUNT=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

header() {
    echo "" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "  $1" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
}

check_connector_status() {
    local URL=$1
    local CONNECTOR=$2
    STATUS=$(curl -s "${URL}/connectors/${CONNECTOR}/status" 2>/dev/null)
    TASK_STATE=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['state'])" 2>/dev/null)
    echo "$TASK_STATE"
}

check_kafka_message() {
    local TOPIC=$1
    local SEARCH_DATA=$2
    MESSAGES=$(docker run --rm apache/kafka:3.7.0 /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server "$KAFKA_BOOTSTRAP" \
        --topic "$TOPIC" \
        --from-beginning --max-messages 200 --timeout-ms 5000 2>/dev/null | tail -20)

    if echo "$MESSAGES" | grep -q "$SEARCH_DATA"; then
        echo "FOUND"
    else
        echo "NOT_FOUND"
    fi
}

# ============================================================
# 메인 모니터링 루프
# ============================================================

header "TLS 1.3 vs TLS 1.2 비교 모니터링 시작"
log "설정:"
log "  - 모니터링 시간: ${DURATION_HOURS}시간"
log "  - 체크 간격: ${INTERVAL_SECONDS}초"
log "  - TLS 1.3 커넥터: ${TLS13_CONNECTOR} (포트 8083)"
log "  - TLS 1.2 커넥터: ${TLS12_CONNECTOR} (포트 8084)"
log "  - use.nongraceful.disconnect: false (둘 다)"
log ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_HOURS * 3600))

while [ $(date +%s) -lt $END_TIME ]; do
    TEST_COUNT=$((TEST_COUNT + 1))

    log "--- 체크 #${TEST_COUNT} ---"

    # 테스트 데이터 INSERT
    TEST_DATA="compare_test_${TEST_COUNT}_$(date +%s)"
    docker run --rm mysql:8.0 mysql -h "$AURORA_HOST" -u "$AURORA_USER" -p"$AURORA_PASS" -e \
        "INSERT INTO testdb.cdc_test (user_id, data) VALUES (8000, '$TEST_DATA');" 2>/dev/null

    sleep 5

    # TLS 1.3 환경 확인
    TLS13_STATUS=$(check_connector_status "$TLS13_CONNECT_URL" "$TLS13_CONNECTOR")
    TLS13_CDC=$(check_kafka_message "$TLS13_TOPIC" "$TEST_DATA")

    # TLS 1.2 환경 확인
    TLS12_STATUS=$(check_connector_status "$TLS12_CONNECT_URL" "$TLS12_CONNECTOR")
    TLS12_CDC=$(check_kafka_message "$TLS12_TOPIC" "$TEST_DATA")

    # 결과 로깅
    log "┌─────────────────────────────────────────────────────────┐"
    log "│  TLS 1.3: Task=${TLS13_STATUS}, CDC=${TLS13_CDC}"
    log "│  TLS 1.2: Task=${TLS12_STATUS}, CDC=${TLS12_CDC}"

    # 이상 감지
    TLS13_OK="true"
    TLS12_OK="true"

    if [ "$TLS13_STATUS" != "RUNNING" ] || [ "$TLS13_CDC" = "NOT_FOUND" ]; then
        log "│  ⚠️  TLS 1.3 이상 감지!"
        TLS13_FAILURES=$((TLS13_FAILURES + 1))
        TLS13_OK="false"
    fi

    if [ "$TLS12_STATUS" != "RUNNING" ] || [ "$TLS12_CDC" = "NOT_FOUND" ]; then
        log "│  ⚠️  TLS 1.2 이상 감지!"
        TLS12_FAILURES=$((TLS12_FAILURES + 1))
        TLS12_OK="false"
    fi

    if [ "$TLS13_OK" = "true" ] && [ "$TLS12_OK" = "true" ]; then
        log "│  ✅ 둘 다 정상"
    fi

    log "│  누적 실패: TLS1.3=${TLS13_FAILURES}, TLS1.2=${TLS12_FAILURES}"
    log "└─────────────────────────────────────────────────────────┘"
    log ""

    # Silent Failure 감지 시 상세 로그
    if [ "$TLS13_OK" = "false" ] && [ "$TLS13_STATUS" = "RUNNING" ]; then
        header "🚨 TLS 1.3 SILENT FAILURE 감지!"
        log "Task는 RUNNING이지만 CDC가 동작하지 않음"
        log "=== 커넥터 상세 상태 ==="
        curl -s "${TLS13_CONNECT_URL}/connectors/${TLS13_CONNECTOR}/status" | python3 -m json.tool >> "$LOG_FILE" 2>&1
        log "=== Kafka Connect 로그 ==="
        docker logs self-managed-connect --tail 30 >> "$LOG_FILE" 2>&1
    fi

    if [ "$TLS12_OK" = "false" ] && [ "$TLS12_STATUS" = "RUNNING" ]; then
        header "🚨 TLS 1.2 SILENT FAILURE 감지!"
        log "Task는 RUNNING이지만 CDC가 동작하지 않음"
        log "=== 커넥터 상세 상태 ==="
        curl -s "${TLS12_CONNECT_URL}/connectors/${TLS12_CONNECTOR}/status" | python3 -m json.tool >> "$LOG_FILE" 2>&1
        log "=== Kafka Connect 로그 ==="
        docker logs self-managed-connect-tls12 --tail 30 >> "$LOG_FILE" 2>&1
    fi

    sleep $INTERVAL_SECONDS
done

header "모니터링 종료 - 최종 결과"
log "총 체크 횟수: ${TEST_COUNT}"
log ""
log "┌─────────────────────────────────────────────────────────┐"
log "│           TLS 1.3 vs TLS 1.2 비교 결과                  │"
log "├─────────────────────────────────────────────────────────┤"
log "│  TLS 1.3 실패 횟수: ${TLS13_FAILURES}"
log "│  TLS 1.2 실패 횟수: ${TLS12_FAILURES}"
log "│                                                         │"
if [ $TLS13_FAILURES -gt $TLS12_FAILURES ]; then
    log "│  결론: TLS 1.3에서 더 많은 문제 발생                    │"
elif [ $TLS13_FAILURES -lt $TLS12_FAILURES ]; then
    log "│  결론: TLS 1.2에서 더 많은 문제 발생                    │"
else
    log "│  결론: 두 환경 동일                                     │"
fi
log "└─────────────────────────────────────────────────────────┘"
log ""
log "로그 파일: ${LOG_FILE}"
