#!/bin/bash
# 等待 MySQL 可用后拉起 Spring Boot 后端（supervisord 的 program:gwent-service）
set -euo pipefail

DB_NAME="${GWENT_DB_NAME:-GwentMirror}"
DB_USER="${GWENT_DB_USER:-gwent}"
DB_PASS="${GWENT_DB_PASS:-gwent123}"

echo "[backend] 等待 MySQL 就绪 ..."
for i in $(seq 1 90); do
  if mysql -h127.0.0.1 -P3306 -u"$DB_USER" -p"$DB_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    echo "[backend] MySQL 已就绪（第 ${i} 次探测）"
    break
  fi
  if [ "$i" = "90" ]; then
    echo "[backend] MySQL 90s 内未就绪，放弃启动" >&2
    exit 1
  fi
  sleep 1
done

exec java ${JAVA_OPTS:--Xms256m -Xmx512m -Dfile.encoding=UTF-8 -Duser.timezone=Asia/Shanghai} \
  -jar /app/backend/GwentMirror.jar \
  --server.port=8081 \
  --spring.datasource.url="jdbc:mysql://127.0.0.1:3306/${DB_NAME}?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai&useSSL=false&allowPublicKeyRetrieval=true&rewriteBatchedStatements=true" \
  --spring.datasource.username="$DB_USER" \
  --spring.datasource.password="$DB_PASS" \
  --spring.datasource.hikari.connection-test-query="SELECT 1"