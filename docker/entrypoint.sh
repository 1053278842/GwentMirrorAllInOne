#!/bin/bash
# ---------------------------------------------------------------------------
# GwentMirror 一体化容器启动脚本
#   1. 首次启动时初始化 MySQL 数据目录
#   2. 临时拉起 mysqld 导入 GwentMirror.sql（仅当库为空）
#   3. 关闭临时实例，交给 supervisord 统一托管 mysqld / 后端 / nginx
# ---------------------------------------------------------------------------
set -euo pipefail

DB_NAME="${GWENT_DB_NAME:-GwentMirror}"
DB_USER="${GWENT_DB_USER:-gwent}"
DB_PASS="${GWENT_DB_PASS:-gwent123}"
DATADIR=/var/lib/mysql
SOCKET=/run/mysqld/mysqld.sock
DUMP=/docker-entrypoint-initdb.d/GwentMirror.sql

log() { echo "[entrypoint] $*"; }

mkdir -p /run/mysqld /www/jar/GwentMirror/uploads /app/logs
chown -R mysql:mysql /run/mysqld "$DATADIR" || true

# --------------------------------------------------------------- 1. 初始化 --
if [ ! -d "$DATADIR/mysql" ]; then
  log "初始化 MySQL 数据目录（首次启动）..."
  mysqld --initialize-insecure --user=mysql --datadir="$DATADIR" >/var/log/mysqld-init.log 2>&1 \
    || { log "初始化失败，日志："; cat /var/log/mysqld-init.log; exit 1; }
fi

# --------------------------------------------------- 2. 临时实例 + 导入数据 --
log "启动临时 MySQL 实例用于建库..."
mysqld --user=mysql --datadir="$DATADIR" --socket="$SOCKET" \
       --skip-networking --skip-log-bin --pid-file=/run/mysqld/init.pid \
       >/var/log/mysqld-bootstrap.log 2>&1 &
BOOT_PID=$!

for i in $(seq 1 60); do
  if mysqladmin --socket="$SOCKET" -uroot ping >/dev/null 2>&1; then break; fi
  if ! kill -0 "$BOOT_PID" 2>/dev/null; then
    log "临时实例启动失败，日志："; cat /var/log/mysqld-bootstrap.log; exit 1
  fi
  sleep 1
done
mysqladmin --socket="$SOCKET" -uroot ping >/dev/null 2>&1 \
  || { log "MySQL 启动超时"; cat /var/log/mysqld-bootstrap.log; exit 1; }

# root 暂时保持免密（socket 登录），等导入完成后再设密码
mysql --socket="$SOCKET" -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

TABLE_CNT=$(mysql --socket="$SOCKET" -uroot -N -B -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
if [ "${TABLE_CNT}" = "0" ]; then
  log "导入 GwentMirror.sql（表结构 + 样例卡组）..."
  mysql --socket="$SOCKET" -uroot --default-character-set=utf8mb4 "$DB_NAME" < "$DUMP"
  log "导入完成。"
else
  log "数据库已存在 ${TABLE_CNT} 张表，跳过导入。"
fi

# 兜底：保证版本表至少有一条记录，前端 /version/api/getId 不会拿到 null
mysql --socket="$SOCKET" -uroot "$DB_NAME" -e \
  "INSERT INTO version (name, create_time, update_time)
   SELECT 'GwentMirror All-in-One', NOW(), NOW()
   FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM version);" 2>/dev/null || true

# 导入完成后再给 root 设置密码（容器内维护用；业务连接一律走 ${DB_USER}）
mysql --socket="$SOCKET" -uroot -e \
  "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'root123'; FLUSH PRIVILEGES;" \
  || log "设置 root 密码失败（不影响业务账号）"

log "关闭临时实例..."
mysqladmin --socket="$SOCKET" -uroot -proot123 shutdown 2>/dev/null \
  || mysqladmin --socket="$SOCKET" -uroot shutdown 2>/dev/null || true
wait "$BOOT_PID" 2>/dev/null || true

# ------------------------------------------------------- 3. 交给 supervisord --
log "启动 supervisord（mysqld + GwentMirror 后端 + nginx）..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/gwent.conf