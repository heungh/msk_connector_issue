#!/bin/bash
# ============================================================
# Self-Managed Kafka Connect 전체 데모 스크립트
#
# 순서:
#   1. docker-compose로 환경 구축
#   2. Debezium 커넥터 등록
#   3. 정상 CDC 동작 확인
#   4. 장애 시뮬레이션 (MySQL 연결 끊기)
#   5. REST API로 FAILED 감지
#   6. Task 재시작으로 즉시 복구
#
# 사용법: ./demo.sh
# ============================================================

set -e

CONNECT_URL="http://localhost:8083"
CONNECTOR_NAME="debezium-cdc-demo"

RED='\033[0;91m'
GREEN='\033[0;92m'
YELLOW='\033[0;93m'
CYAN='\033[0;96m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

log() { echo -e "${DIM}[$(date '+%H:%M:%S')]${RESET} $1"; }
header() { echo ""; echo -e "${BOLD}═══ $1 ═══${RESET}"; echo ""; }
wait_key() { echo ""; echo -e "  ${DIM}[Enter]를 눌러 다음 단계로...${RESET}"; read -r; }

# ──────────────────────────────────────────────
header "Step 0: 환경 확인"
# ──────────────────────────────────────────────

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker가 설치되어 있지 않습니다.${RESET}"
    exit 1
fi

echo -e "  Docker: $(docker --version)"
echo -e "  Docker Compose: $(docker compose version 2>/dev/null || echo 'not found')"

# ──────────────────────────────────────────────
header "Step 1: 환경 구축 (MySQL + Kafka + Kafka Connect)"
# ──────────────────────────────────────────────

log "docker-compose up 실행 중..."
docker compose up -d

log "Kafka Connect 준비 대기 중..."
for i in $(seq 1 60); do
    if curl -s "${CONNECT_URL}/" > /dev/null 2>&1; then
        log "${GREEN}Kafka Connect 준비 완료!${RESET}"
        break
    fi
    if [ $i -eq 60 ]; then
        log "${RED}타임아웃! docker compose logs로 확인하세요.${RESET}"
        exit 1
    fi
    sleep 2
done

wait_key

# ──────────────────────────────────────────────
header "Step 2: Debezium 커넥터 등록"
# ──────────────────────────────────────────────

log "커넥터 등록: POST /connectors"
REGISTER_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -d @register-connector.json \
    "${CONNECT_URL}/connectors")

if [ "$REGISTER_RESPONSE" = "201" ] || [ "$REGISTER_RESPONSE" = "409" ]; then
    log "${GREEN}커넥터 등록 완료 (HTTP ${REGISTER_RESPONSE})${RESET}"
else
    log "${RED}커넥터 등록 실패 (HTTP ${REGISTER_RESPONSE})${RESET}"
    exit 1
fi

sleep 3

# ──────────────────────────────────────────────
header "Step 3: REST API로 상태 확인 (MSK Connect에서는 불가능)"
# ──────────────────────────────────────────────

log "${CYAN}GET /connectors/${CONNECTOR_NAME}/status${RESET}"
echo ""
curl -s "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" | python3 -m json.tool
echo ""

log "핵심: ${BOLD}tasks[0].state${RESET} 값을 직접 확인할 수 있습니다."
log "MSK Connect에서는 이 API에 접근 불가 → silent failure 감지 불가"

wait_key

# ──────────────────────────────────────────────
header "Step 4: 정상 CDC 동작 확인"
# ──────────────────────────────────────────────

log "MySQL에 데이터 INSERT..."
docker exec demo-mysql mysql -ucdc_user -pcdc_pass -e \
    "INSERT INTO recommendation.user_recent_paid_purchase (user_id, book_id, purchase_type, amount) VALUES (2001, 7001, 'ebook', 18000);" 2>/dev/null

sleep 2

log "Kafka 토픽에서 메시지 확인:"
echo ""
docker exec demo-kafka /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic cdc.recommendation.user_recent_paid_purchase \
    --from-beginning --max-messages 1 --timeout-ms 5000 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(메시지 대기 중...)"
echo ""

log "${GREEN}CDC 정상 동작 확인!${RESET}"

wait_key

# ──────────────────────────────────────────────
header "Step 5: 장애 시뮬레이션 — MySQL 연결 강제 끊기"
# ──────────────────────────────────────────────

log "${RED}MySQL CDC 유저의 연결을 강제로 끊습니다...${RESET}"

# CDC 유저의 thread ID를 찾아서 kill
docker exec demo-mysql mysql -uroot -prootpass -e "
SELECT ID, USER, HOST, COMMAND FROM information_schema.PROCESSLIST WHERE USER='cdc_user';
" 2>/dev/null

THREAD_IDS=$(docker exec demo-mysql mysql -uroot -prootpass -N -e \
    "SELECT ID FROM information_schema.PROCESSLIST WHERE USER='cdc_user' AND COMMAND='Binlog Dump';" 2>/dev/null)

if [ -n "$THREAD_IDS" ]; then
    for TID in $THREAD_IDS; do
        log "${RED}KILL thread ${TID}${RESET}"
        docker exec demo-mysql mysql -uroot -prootpass -e "KILL ${TID};" 2>/dev/null
    done
else
    log "${YELLOW}Binlog Dump 스레드를 찾지 못했습니다. 네트워크 차단으로 시뮬레이션...${RESET}"
    docker exec demo-mysql mysql -uroot -prootpass -e \
        "REVOKE REPLICATION SLAVE ON *.* FROM 'cdc_user'@'%'; FLUSH PRIVILEGES;" 2>/dev/null
fi

sleep 5

wait_key

# ──────────────────────────────────────────────
header "Step 6: REST API로 장애 감지 (핵심 데모)"
# ──────────────────────────────────────────────

log "${CYAN}GET /connectors/${CONNECTOR_NAME}/status${RESET}"
echo ""
STATUS_JSON=$(curl -s "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status")
echo "$STATUS_JSON" | python3 -m json.tool
echo ""

TASK_STATE=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['state'])" 2>/dev/null)
CONNECTOR_STATE=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['connector']['state'])" 2>/dev/null)

echo ""
log "┌─────────────────────────────────────────────────────────┐"
log "│  Connector 상태: ${CONNECTOR_STATE}                              │"
log "│  Task 상태:      ${BOLD}${TASK_STATE}${RESET}                                  │"
log "│                                                         │"

if [ "$TASK_STATE" = "FAILED" ]; then
    log "│  ${GREEN}→ Self-Managed: Task FAILED 감지 성공!${RESET}                 │"
    log "│  ${RED}→ MSK Connect:  여전히 RUNNING으로 보임 (감지 불가)${RESET}  │"
else
    log "│  ${YELLOW}→ Task가 아직 FAILED가 아닙니다. 잠시 후 재확인...${RESET}      │"
fi
log "└─────────────────────────────────────────────────────────┘"

wait_key

# ──────────────────────────────────────────────
header "Step 7: Task 즉시 재시작 (MSK Connect에서는 불가능)"
# ──────────────────────────────────────────────

# 권한 복구 (장애 시뮬레이션 해제)
docker exec demo-mysql mysql -uroot -prootpass -e \
    "GRANT REPLICATION SLAVE ON *.* TO 'cdc_user'@'%'; FLUSH PRIVILEGES;" 2>/dev/null

log "${YELLOW}POST /connectors/${CONNECTOR_NAME}/tasks/0/restart${RESET}"

RESTART_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/tasks/0/restart")

log "응답: HTTP ${RESTART_CODE}"

if [ "$RESTART_CODE" = "204" ] || [ "$RESTART_CODE" = "200" ]; then
    log "${GREEN}${BOLD}Task 재시작 성공!${RESET}"
else
    log "${YELLOW}Task 재시작 실패, 커넥터 전체 재시작...${RESET}"
    curl -s -X POST "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/restart?includeTasks=true" > /dev/null
fi

sleep 3

log "복구 후 상태 확인:"
curl -s "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" | python3 -m json.tool

echo ""
log "┌─────────────────────────────────────────────────────────┐"
log "│  ${BOLD}MSK Connect vs Self-Managed 비교${RESET}                       │"
log "│                                                         │"
log "│  MSK Connect:                                           │"
log "│    감지: CloudWatch 알람 (2~5분)                         │"
log "│    복구: 커넥터 삭제/재생성 (5~10분)                      │"
log "│    총: 10~15분                                           │"
log "│                                                         │"
log "│  Self-Managed:                                           │"
log "│    감지: REST API 폴링 (수초)                             │"
log "│    복구: Task 재시작 (수초)                                │"
log "│    ${GREEN}${BOLD}총: ~10초${RESET}                                           │"
log "└─────────────────────────────────────────────────────────┘"

wait_key

# ──────────────────────────────────────────────
header "Step 8: 복구 후 CDC 정상 동작 확인"
# ──────────────────────────────────────────────

log "MySQL에 데이터 INSERT..."
docker exec demo-mysql mysql -ucdc_user -pcdc_pass -e \
    "INSERT INTO recommendation.user_recent_paid_purchase (user_id, book_id, purchase_type, amount) VALUES (3001, 8001, 'audiobook', 22000);" 2>/dev/null

sleep 2

log "Kafka 토픽에서 새 메시지 확인:"
docker exec demo-kafka /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic cdc.recommendation.user_recent_paid_purchase \
    --from-beginning --max-messages 5 --timeout-ms 5000 2>/dev/null | tail -1 | python3 -m json.tool 2>/dev/null || echo "(확인 중...)"

echo ""
log "${GREEN}${BOLD}데모 완료!${RESET}"

echo ""
echo -e "${BOLD}================================================================="
echo "  정리: docker compose down -v"
echo "=================================================================${RESET}"
