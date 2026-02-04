-- CDC 대상 테이블 생성 (고객 환경과 유사)
CREATE DATABASE IF NOT EXISTS recommendation;
USE recommendation;

CREATE TABLE user_recent_paid_purchase (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT NOT NULL,
    book_id BIGINT NOT NULL,
    purchase_type VARCHAR(50) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    purchased_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- CDC 유저 권한 부여
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'cdc_user'@'%';
FLUSH PRIVILEGES;

-- 초기 테스트 데이터
INSERT INTO user_recent_paid_purchase (user_id, book_id, purchase_type, amount) VALUES
(1001, 5001, 'ebook', 12000),
(1002, 5002, 'audiobook', 15000),
(1003, 5003, 'ebook', 9000);
