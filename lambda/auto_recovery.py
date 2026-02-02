"""
MSK Connect Debezium 커넥터 자동 복구 Lambda 함수

CloudWatch Alarm → EventBridge → 이 Lambda 함수

동작 방식:
1. CloudWatch Alarm (Connected=0 또는 Offset commit 중단) 발생
2. EventBridge가 이 Lambda를 트리거
3. Lambda가 MSK Connect 커넥터를 삭제 후 재생성

환경 변수:
- CONNECTOR_ARN: MSK Connect 커넥터 ARN
- CONNECTOR_CONFIG_S3_BUCKET: 커넥터 설정이 저장된 S3 버킷
- CONNECTOR_CONFIG_S3_KEY: 커넥터 설정 S3 키
- SNS_TOPIC_ARN: 알림용 SNS Topic ARN
"""

import json
import os
import time
import boto3
from datetime import datetime

kafkaconnect = boto3.client("kafkaconnect")
sns = boto3.client("sns")
s3 = boto3.client("s3")

CONNECTOR_ARN = os.environ.get("CONNECTOR_ARN", "")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
CONFIG_BUCKET = os.environ.get("CONNECTOR_CONFIG_S3_BUCKET", "")
CONFIG_KEY = os.environ.get("CONNECTOR_CONFIG_S3_KEY", "")


def lambda_handler(event, context):
    print(f"[{datetime.utcnow().isoformat()}] 알람 이벤트 수신: {json.dumps(event)}")

    alarm_name = extract_alarm_name(event)
    print(f"알람 이름: {alarm_name}")

    # 1. 현재 커넥터 상태 확인
    connector_info = get_connector_info()
    if not connector_info:
        notify(f"[WARN] 커넥터 정보를 가져올 수 없습니다: {CONNECTOR_ARN}")
        return {"statusCode": 500, "body": "커넥터 정보 조회 실패"}

    connector_state = connector_info.get("connectorState", "UNKNOWN")
    print(f"현재 커넥터 상태: {connector_state}")

    # 2. 커넥터 삭제
    print("커넥터 삭제 시작...")
    delete_result = delete_connector()
    if not delete_result:
        notify(f"[ERROR] 커넥터 삭제 실패: {CONNECTOR_ARN}")
        return {"statusCode": 500, "body": "커넥터 삭제 실패"}

    # 3. 삭제 완료 대기
    print("커넥터 삭제 완료 대기 중...")
    wait_for_deletion()

    # 4. 커넥터 재생성
    print("커넥터 재생성 시작...")
    create_result = recreate_connector()
    if not create_result:
        notify(f"[CRITICAL] 커넥터 재생성 실패! 수동 조치 필요: {CONNECTOR_ARN}")
        return {"statusCode": 500, "body": "커넥터 재생성 실패"}

    # 5. 성공 알림
    notify(
        f"[RECOVERED] Debezium 커넥터 자동 복구 완료\n"
        f"- 알람: {alarm_name}\n"
        f"- 이전 상태: {connector_state}\n"
        f"- 복구 시각: {datetime.utcnow().isoformat()}Z\n"
        f"- 신규 커넥터 ARN: {create_result}"
    )

    return {"statusCode": 200, "body": f"커넥터 복구 완료: {create_result}"}


def extract_alarm_name(event):
    """EventBridge 이벤트에서 알람 이름 추출"""
    try:
        detail = event.get("detail", {})
        return detail.get("alarmName", "Unknown")
    except Exception:
        return "Unknown"


def get_connector_info():
    """MSK Connect 커넥터 정보 조회"""
    try:
        response = kafkaconnect.describe_connector(connectorArn=CONNECTOR_ARN)
        return response
    except Exception as e:
        print(f"커넥터 조회 실패: {e}")
        return None


def delete_connector():
    """MSK Connect 커넥터 삭제"""
    try:
        # 현재 버전 조회
        info = kafkaconnect.describe_connector(connectorArn=CONNECTOR_ARN)
        current_version = info["currentVersion"]

        kafkaconnect.delete_connector(
            connectorArn=CONNECTOR_ARN,
            currentVersion=current_version,
        )
        print(f"커넥터 삭제 요청 완료 (version: {current_version})")
        return True
    except Exception as e:
        print(f"커넥터 삭제 실패: {e}")
        return False


def wait_for_deletion(max_wait_sec=300):
    """커넥터 삭제 완료 대기"""
    elapsed = 0
    while elapsed < max_wait_sec:
        try:
            info = kafkaconnect.describe_connector(connectorArn=CONNECTOR_ARN)
            state = info.get("connectorState", "")
            print(f"  삭제 대기 중... 상태: {state} ({elapsed}s)")
            if state == "DELETED":
                return True
        except kafkaconnect.exceptions.NotFoundException:
            print("  커넥터 삭제 확인됨")
            return True
        except Exception as e:
            print(f"  상태 확인 중 오류: {e}")

        time.sleep(10)
        elapsed += 10

    print(f"삭제 대기 타임아웃 ({max_wait_sec}s)")
    return False


def recreate_connector():
    """S3에 저장된 설정으로 커넥터 재생성"""
    try:
        # S3에서 커넥터 생성 파라미터 로드
        config_obj = s3.get_object(Bucket=CONFIG_BUCKET, Key=CONFIG_KEY)
        config = json.loads(config_obj["Body"].read().decode("utf-8"))

        response = kafkaconnect.create_connector(**config)
        new_arn = response["connectorArn"]
        print(f"커넥터 재생성 완료: {new_arn}")
        return new_arn
    except Exception as e:
        print(f"커넥터 재생성 실패: {e}")
        return None


def notify(message):
    """SNS로 알림 전송"""
    if not SNS_TOPIC_ARN:
        print(f"[SNS 미설정] {message}")
        return

    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[MSK Connect] Debezium 커넥터 자동 복구",
            Message=message,
        )
        print(f"SNS 알림 전송 완료")
    except Exception as e:
        print(f"SNS 알림 전송 실패: {e}")
