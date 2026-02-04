#!/bin/bash
# ============================================================
# Kafka Connect Health Check + 자동 복구 스크립트
#
# MSK Connect에서는 불가능하지만 Self-Managed에서는 가능한 것:
#   - REST API로 Task 상태를 직접 조회
#   - Task 단위 즉시 재시작 (커넥터 삭제/재생성 불필요)
#
# 사용법: ./health_check.sh
# ============================================================

CONNECT_URL="http://localhost:8083"
CONNECTOR_NAME="debezium-cdc-demo"
CHECK_INTERVAL=5

# 색상
RED='\033[0;91m'
GREEN='\033[0;92m'
YELLOW='\033[0;93m'
CYAN='\033[0;96m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

log() {
    echo -e "${DIM}[$(date '+%H:%M:%S')]${RESET} $1"
}

echo ""
echo -e "${BOLD}================================================================="
echo "  Self-Managed Kafka Connect — Health Check + 자동 복구"
echo "=================================================================${RESET}"
echo ""
echo -e "  ${GREEN}REST API${RESET}로 Task 상태를 직접 조회합니다."
echo -e "  MSK Connect에서는 이 API에 접근할 수 없습니다."
echo ""
echo -e "  ${CYAN}GET${RESET} ${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status"
echo ""
echo -e "  ${DIM}Ctrl+C로 종료${RESET}"
echo -e "${BOLD}-----------------------------------------------------------------${RESET}"
echo ""

RESTART_COUNT=0

while true; do
    # ─── REST API로 상태 조회 (MSK Connect에서는 불가능!) ───
    RESPONSE=$(curl -s "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
        log "${RED}[Health] Kafka Connect 접속 불가${RESET}"
        sleep $CHECK_INTERVAL
        continue
    fi

    # 커넥터 상태와 Task 상태를 분리해서 확인
    CONNECTOR_STATE=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['connector']['state'])" 2>/dev/null)
    TASK_STATE=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['state'])" 2>/dev/null)
    TASK_TRACE=$(echo "$RESPONSE" | python3 -c "import sys,json; t=json.load(sys.stdin)['tasks'][0]; print(t.get('trace','')[:100])" 2>/dev/null)

    # ─── MSK Connect vs Self-Managed 차이점 ───
    # MSK Connect: CONNECTOR_STATE만 보임 (항상 RUNNING)
    # Self-Managed: TASK_STATE까지 보임 (RUNNING / FAILED / PAUSED)

    if [ "$TASK_STATE" = "RUNNING" ]; then
        log "${GREEN}[Health]${RESET} Connector: ${GREEN}${CONNECTOR_STATE}${RESET} | Task: ${GREEN}${TASK_STATE}${RESET}  ✓"

    elif [ "$TASK_STATE" = "FAILED" ]; then
        log "${RED}${BOLD}[Health] TASK FAILED 감지!${RESET}"
        log "${RED}  Connector: ${CONNECTOR_STATE} | Task: ${TASK_STATE}${RESET}"
        if [ -n "$TASK_TRACE" ]; then
            log "${DIM}  Error: ${TASK_TRACE}${RESET}"
        fi

        # ─── Task 단위 즉시 재시작 (MSK Connect에서는 불가능!) ───
        log "${YELLOW}[복구] Task 재시작: POST /connectors/${CONNECTOR_NAME}/tasks/0/restart${RESET}"
        RESTART_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/tasks/0/restart")

        if [ "$RESTART_RESPONSE" = "204" ] || [ "$RESTART_RESPONSE" = "200" ]; then
            RESTART_COUNT=$((RESTART_COUNT + 1))
            log "${GREEN}${BOLD}[복구] Task 재시작 성공! (HTTP ${RESTART_RESPONSE}, 총 #${RESTART_COUNT})${RESET}"
        else
            log "${RED}[복구] Task 재시작 실패 (HTTP ${RESTART_RESPONSE}), 커넥터 전체 재시작 시도...${RESET}"
            curl -s -X POST "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/restart?includeTasks=true" > /dev/null
            RESTART_COUNT=$((RESTART_COUNT + 1))
            log "${YELLOW}[복구] 커넥터 전체 재시작 요청 완료 (#${RESTART_COUNT})${RESET}"
        fi

    elif [ "$TASK_STATE" = "PAUSED" ]; then
        log "${YELLOW}[Health] Task PAUSED 상태 — resume 시도${RESET}"
        curl -s -X PUT "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/resume" > /dev/null
        log "${CYAN}[복구] Resume 요청 완료${RESET}"

    else
        log "${YELLOW}[Health] Connector: ${CONNECTOR_STATE} | Task: ${TASK_STATE:-UNKNOWN}${RESET}"
    fi

    sleep $CHECK_INTERVAL
done
