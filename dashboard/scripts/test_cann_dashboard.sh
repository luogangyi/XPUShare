#!/usr/bin/env bash
set -euo pipefail

ENDPOINT=${1:-${DASHBOARD_ENDPOINT:-http://139.196.28.96:32050}}
NAMESPACE=${NAMESPACE:-xpushare-system}
APP_NAME=${APP_NAME:-xpushare-dashboard}
KUBECTL_BIN=${KUBECTL_BIN:-kubectl}
FALLBACK_PORT_FORWARD=${FALLBACK_PORT_FORWARD:-1}
PORT_FORWARD_LOCAL_PORT=${PORT_FORWARD_LOCAL_PORT:-18080}

read -r -a KUBECTL_CMD <<< "${KUBECTL_BIN}"
kctl() {
  "${KUBECTL_CMD[@]}" "$@"
}

if ! command -v "${KUBECTL_CMD[0]}" >/dev/null 2>&1; then
  echo "${KUBECTL_CMD[0]} not found"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DASHBOARD_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
ARTIFACT_DIR="${DASHBOARD_DIR}/artifacts/$(date +%Y%m%d-%H%M%S)-cann-dashboard-test"
mkdir -p "${ARTIFACT_DIR}"

PF_PID=""
cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${ARTIFACT_DIR}/run.log"
}

capture() {
  local name=$1
  shift
  "$@" >"${ARTIFACT_DIR}/${name}.txt" 2>&1 || {
    log "command failed: $*"
    return 1
  }
}

log "endpoint=${ENDPOINT}"
log "artifact_dir=${ARTIFACT_DIR}"

capture kubectl_deploy kctl -n "${NAMESPACE}" get deployment "${APP_NAME}" -o wide
capture kubectl_pods kctl -n "${NAMESPACE}" get pods -l app="${APP_NAME}" -o wide
capture kubectl_svc kctl -n "${NAMESPACE}" get svc "${APP_NAME}" -o wide

ACTIVE_ENDPOINT="${ENDPOINT}"
if ! capture healthz_direct curl -fsS "${ACTIVE_ENDPOINT}/api/v1/healthz"; then
  if [[ "${FALLBACK_PORT_FORWARD}" != "1" ]]; then
    log "direct endpoint test failed and fallback disabled"
    exit 1
  fi

  log "direct endpoint failed, trying kubectl port-forward fallback"
  kctl -n "${NAMESPACE}" port-forward svc/${APP_NAME} ${PORT_FORWARD_LOCAL_PORT}:80 >"${ARTIFACT_DIR}/port_forward.log" 2>&1 &
  PF_PID=$!
  sleep 3

  ACTIVE_ENDPOINT="http://127.0.0.1:${PORT_FORWARD_LOCAL_PORT}"
  capture healthz_portforward curl -fsS "${ACTIVE_ENDPOINT}/api/v1/healthz"
fi

capture overview curl -fsS "${ACTIVE_ENDPOINT}/api/v1/overview"
capture nodes curl -fsS "${ACTIVE_ENDPOINT}/api/v1/nodes/xpushare"
capture pods curl -fsS "${ACTIVE_ENDPOINT}/api/v1/pods/xpushare"

log "basic endpoint tests passed"
log "active_endpoint=${ACTIVE_ENDPOINT}"
log "saved outputs:"
ls -1 "${ARTIFACT_DIR}" | sed 's/^/  - /' | tee -a "${ARTIFACT_DIR}/run.log"

log "done"
