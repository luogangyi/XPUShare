#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DASHBOARD_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_DIR=$(cd "${DASHBOARD_DIR}/.." && pwd)

cd "${REPO_DIR}"

IMAGE_REPO=${IMAGE_REPO:-registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard}
IMAGE_TAG=${1:-${IMAGE_TAG:-dashboard-v0.1-$(git rev-parse --short HEAD)}}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}

IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"

echo "[build] image: ${IMAGE}"
echo "[build] platforms: ${PLATFORMS}"

docker buildx build \
  --platform "${PLATFORMS}" \
  -f "${DASHBOARD_DIR}/Dockerfile" \
  -t "${IMAGE}" \
  --push \
  "${DASHBOARD_DIR}"

echo "[done] pushed ${IMAGE}"
