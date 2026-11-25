#!/usr/bin/env bash
# 构建 GwentMirror 一体化镜像
#   ./scripts/build.sh                # 默认 tag: gwentmirror-all-in-one:1.4.0
#   IMAGE=gwent/gwentmirror:dev ./scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-gwentmirror-all-in-one:1.4.0}"
echo "==> 构建镜像 ${IMAGE}"
docker build -f docker/Dockerfile -t "${IMAGE}" "$@" .
echo "==> 完成: ${IMAGE}"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep -E 'REPOSITORY|gwentmirror' || true
