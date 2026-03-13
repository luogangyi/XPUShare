#!/usr/bin/env bash
set -euo pipefail

ENDPOINT=${1:-${DASHBOARD_ENDPOINT:-http://139.196.28.96:32050}}
NAMESPACE=${NAMESPACE:-xpushare-system}
APP_NAME=${APP_NAME:-xpushare-dashboard}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DASHBOARD_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
ARTIFACT_DIR="${DASHBOARD_DIR}/artifacts/$(date +%Y%m%d-%H%M%S)-cann-dashboard-test"
mkdir -p "${ARTIFACT_DIR}"

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

capture kubectl_deploy kubectl -n "${NAMESPACE}" get deployment "${APP_NAME}" -o wide
capture kubectl_pods kubectl -n "${NAMESPACE}" get pods -l app="${APP_NAME}" -o wide
capture kubectl_svc kubectl -n "${NAMESPACE}" get svc "${APP_NAME}" -o wide

capture healthz curl -fsS "${ENDPOINT}/api/v1/healthz"
capture overview curl -fsS "${ENDPOINT}/api/v1/overview"
capture nodes curl -fsS "${ENDPOINT}/api/v1/nodes/xpushare"
capture pods curl -fsS "${ENDPOINT}/api/v1/pods/xpushare"

log "basic endpoint tests passed"
log "saved outputs:"
ls -1 "${ARTIFACT_DIR}" | sed 's/^/  - /' | tee -a "${ARTIFACT_DIR}/run.log"

log "done"
