#!/usr/bin/env bash
# 推送镜像到阿里云容器镜像服务（ACR，上海地域个人版）
#
#   1) 先在控制台创建命名空间与仓库（个人版必须预先建仓库）
#      https://cr.console.aliyun.com/cn-shanghai/instance/repositories
#   2) 登录：docker login --username=<阿里云账号全名> crpi-jjrtzj5uuz1ioat1.cn-shanghai.personal.cr.aliyuncs.com
#   3) 推送：./scripts/push-aliyun.sh
#
# 可用环境变量覆盖：
#   REGISTRY  默认 crpi-jjrtzj5uuz1ioat1.cn-shanghai.personal.cr.aliyuncs.com
#   NAMESPACE 默认 liunidie
#   REPO      默认 gwentmirror-all-in-one
#   TAG       默认 1.0.0
#   LOCAL_IMAGE 默认 gwentmirror-all-in-one:1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-crpi-jjrtzj5uuz1ioat1.cn-shanghai.personal.cr.aliyuncs.com}"
NAMESPACE="${NAMESPACE:-liunidie}"
REPO="${REPO:-gwentmirror-all-in-one}"
TAG="${TAG:-1.4.0}"
LOCAL_IMAGE="${LOCAL_IMAGE:-gwentmirror-all-in-one:1.4.0}"
REMOTE="${REGISTRY}/${NAMESPACE}/${REPO}:${TAG}"

echo "==> docker tag ${LOCAL_IMAGE} ${REMOTE}"
docker tag "${LOCAL_IMAGE}" "${REMOTE}"

echo "==> docker push ${REMOTE}"
docker push "${REMOTE}"

echo
echo "==> 推送完成，拉取运行："
echo "    docker pull ${REMOTE}"
echo "    docker run -d --name gwent-mirror -p 8080:80 -p 8081:8081 ${REMOTE}"

