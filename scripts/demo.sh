#!/usr/bin/env bash
# 一条命令跑完整演示：启动容器 -> 等健康 -> 爬官网卡组 -> 回放对局 -> 打印结果
#
#   ./scripts/demo.sh                # 使用本地已构建镜像
#   IMAGE=<镜像地址> ./scripts/demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-gwentmirror-all-in-one:1.4.0}"
NAME="${NAME:-gwent-mirror}"
WEB_PORT="${WEB_PORT:-8080}"
API_PORT="${API_PORT:-8081}"
BASE="http://localhost:${WEB_PORT}/gmapi"

echo "==> 清理旧容器"
docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "==> 启动 ${IMAGE}"
docker run -d --name "$NAME" -p "${WEB_PORT}:80" -p "${API_PORT}:8081" "$IMAGE" >/dev/null

echo "==> 等待就绪（首次启动要初始化 MySQL，最多 180s）"
for i in $(seq 1 90); do
  if curl -fsS "http://localhost:${WEB_PORT}/healthz" >/dev/null 2>&1 \
     && curl -fsS "${BASE}/deck/api/maxid" >/dev/null 2>&1; then
    echo "    就绪（第 ${i} 次探测）"
    break
  fi
  sleep 2
  if [ "$i" = "90" ]; then echo "启动超时，请查看: docker logs $NAME"; exit 1; fi
done

echo
echo "==> 1/2 抓取官网最新卡组"
python3 scripts/fetch_decks.py --base-url "$BASE" --since-days 30 --limit 20 || \
  echo "    (抓取失败，跳过；容器自带样例卡组仍可演示)"

echo
echo "==> 2/2 回放对局（模拟记牌器上报）"
python3 scripts/simulate_battle.py --base-url "$BASE" --matches 5

echo
echo "==> 数据库落库情况"
docker exec "$NAME" mysql -ugwent -pgwent123 GwentMirror -e \
  "SELECT 'deck' AS tbl, COUNT(*) AS rows_cnt FROM deck
   UNION ALL SELECT 'battle', COUNT(*) FROM battle
   UNION ALL SELECT 'player', COUNT(*) FROM player
   UNION ALL SELECT 'player_battle_info', COUNT(*) FROM player_battle_info;" 2>/dev/null

echo
echo "==> 打开 http://localhost:${WEB_PORT}  查看卡组站"
echo "==> 查看日志: docker logs -f ${NAME}"
