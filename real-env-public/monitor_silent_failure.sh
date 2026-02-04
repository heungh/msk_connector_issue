#!/bin/bash
# ============================================================
# Silent Failure 장시간 모니터링 스크립트
#
# 목적: use.nongraceful.disconnect=false 상태에서
#       Silent Failure 발생 여부 및 감지 가능 여부 테스트
#
# 모니터링 항목:
#   1. 커넥터 상태 (REST API)
#   2. CDC 동작 여부 (INSERT → Kafka 메시지 확인)
#   3. Binlog Dump 연결 상태 (MySQL PROCESSLIST)
#   4. TLS 연결 상태
#
# 사용법: ./monitor_silent_failure.sh [duration_hours]
#         기본값: 24시간
# ============================================================

DURATION_HOURS=${1:-24}
INTERVAL_SECONDS=60
CONNECTOR_NAME="aurora-cdc-silent-failure-test"
CONNECT_URL="http://localhost:8083"
AURORA_HOST="your-aurora-cluster.cluster-xxxxxxxxx.ap-northeast-2.rds.amazonaws.com"
AURORA_USER="your_db_user"
AURORA_PASS="********"
KAFKA_BOOTSTRAP="b-1.your-msk-cluster.xxxxxx.c3.kafka.ap-northeast-2.amazonaws.com:9092"
TOPIC="aurora-cdc.testdb.cdc_test"

LOG_FILE="/home/ec2-user/silent_failure_monitor_$(date +%Y%m%d_%H%M%S).log"
LAST_INSERT_ID=0
CONSECUTIVE_FAILURES=0

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
    STATUS=$(curl -s "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>/dev/null)
    CONNECTOR_STATE=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['connector']['state'])" 2>/dev/null)
    TASK_STATE=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['state'])" 2>/dev/null)
    echo "${CONNECTOR_STATE}|${TASK_STATE}"
}

check_binlog_connection() {
    BINLOG_CONN=$(docker run --rm mysql:8.0 mysql -h "$AURORA_HOST" -u "$AURORA_USER" -p"$AURORA_PASS" -N -e \
        "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='$AURORA_USER' AND COMMAND='Binlog Dump';" 2>/dev/null)
    echo "$BINLOG_CONN"
}

check_tls_version() {
    TLS_VER=$(docker run --rm mysql:8.0 mysql -h "$AURORA_HOST" -u "$AURORA_USER" -p"$AURORA_PASS" -N -e \
        "SHOW SESSION STATUS LIKE 'Ssl_version';" 2>/dev/null | awk '{print $2}')
    echo "$TLS_VER"
}

insert_test_data() {
    LAST_INSERT_ID=$((LAST_INSERT_ID + 1))
    TEST_DATA="monitor_test_${LAST_INSERT_ID}_$(date +%s)"
    docker run --rm mysql:8.0 mysql -h "$AURORA_HOST" -u "$AURORA_USER" -p"$AURORA_PASS" -e \
        "INSERT INTO testdb.cdc_test (user_id, data) VALUES (9000, '$TEST_DATA');" 2>/dev/null
    echo "$TEST_DATA"
}

check_kafka_message() {
    local SEARCH_DATA=$1
    # 최신 메시지 5개 확인
    MESSAGES=$(docker run --rm apache/kafka:3.7.0 /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server "$KAFKA_BOOTSTRAP" \
        --topic "$TOPIC" \
        --from-beginning --max-messages 100 --timeout-ms 5000 2>/dev/null | tail -10)

    if echo "$MESSAGES" | grep -q "$SEARCH_DATA"; then
        echo "FOUND"
    else
        echo "NOT_FOUND"
    fi
}

# ============================================================
# 메인 모니터링 루프
# ============================================================

header "Silent Failure 장시간 모니터링 시작"
log "설정:"
log "  - 모니터링 시간: ${DURATION_HOURS}시간"
log "  - 체크 간격: ${INTERVAL_SECONDS}초"
log "  - 커넥터: ${CONNECTOR_NAME}"
log "  - use.nongraceful.disconnect: false"
log "  - 로그 파일: ${LOG_FILE}"
log ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_HOURS * 3600))
CHECK_COUNT=0

while [ $(date +%s) -lt $END_TIME ]; do
    CHECK_COUNT=$((CHECK_COUNT + 1))

    log "--- 체크 #${CHECK_COUNT} ---"

    # 1. 커넥터 상태 확인
    STATUS_RESULT=$(check_connector_status)
    CONNECTOR_STATE=$(echo "$STATUS_RESULT" | cut -d'|' -f1)
    TASK_STATE=$(echo "$STATUS_RESULT" | cut -d'|' -f2)
    log "커넥터 상태: Connector=${CONNECTOR_STATE}, Task=${TASK_STATE}"

    # 2. Binlog Dump 연결 확인
    BINLOG_COUNT=$(check_binlog_connection)
    log "Binlog Dump 연결 수: ${BINLOG_COUNT}"

    # 3. 데이터 INSERT 및 CDC 확인
    TEST_DATA=$(insert_test_data)
    log "테스트 데이터 INSERT: ${TEST_DATA}"
    sleep 5

    CDC_RESULT=$(check_kafka_message "$TEST_DATA")
    log "Kafka 메시지 확인: ${CDC_RESULT}"

    # 4. 이상 감지
    if [ "$TASK_STATE" != "RUNNING" ]; then
        log "⚠️  경고: Task 상태가 RUNNING이 아님! (${TASK_STATE})"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    elif [ "$CDC_RESULT" = "NOT_FOUND" ]; then
        log "⚠️  경고: CDC 메시지가 Kafka에 도착하지 않음!"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    elif [ "$BINLOG_COUNT" = "0" ]; then
        log "⚠️  경고: Binlog Dump 연결이 없음!"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    else
        log "✅ 정상"
        CONSECUTIVE_FAILURES=0
    fi

    # 5. Silent Failure 감지 (3회 연속 실패)
    if [ $CONSECUTIVE_FAILURES -ge 3 ]; then
        header "🚨 SILENT FAILURE 감지!"
        log "3회 연속 실패 감지"
        log "Connector 상태: ${CONNECTOR_STATE}"
        log "Task 상태: ${TASK_STATE}"
        log "Binlog 연결: ${BINLOG_COUNT}"
        log "CDC 결과: ${CDC_RESULT}"

        # 상세 로그 수집
        log ""
        log "=== 커넥터 상세 상태 ==="
        curl -s "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" | python3 -m json.tool >> "$LOG_FILE" 2>&1

        log ""
        log "=== Kafka Connect 로그 (최근 50줄) ==="
        docker logs self-managed-connect --tail 50 >> "$LOG_FILE" 2>&1

        log ""
        log "Silent Failure 기록 완료. 모니터링 계속..."
        CONSECUTIVE_FAILURES=0
    fi

    # 6. 주기적 TLS 상태 확인 (10분마다)
    if [ $((CHECK_COUNT % 10)) -eq 0 ]; then
        TLS_VER=$(check_tls_version)
        log "TLS 버전 확인: ${TLS_VER}"
    fi

    log ""
    sleep $INTERVAL_SECONDS
done

header "모니터링 종료"
log "총 체크 횟수: ${CHECK_COUNT}"
log "로그 파일: ${LOG_FILE}"
