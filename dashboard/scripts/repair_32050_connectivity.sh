#!/usr/bin/env bash
set -euo pipefail

PUBLIC_HOST=${PUBLIC_HOST:-aliyun}
PUBLIC_IP=${PUBLIC_IP:-139.196.28.96}
PUBLIC_PORT=${PUBLIC_PORT:-32050}
LOCAL_PORT=${LOCAL_PORT:-18080}
NAMESPACE=${NAMESPACE:-xpushare-system}
SERVICE=${SERVICE:-xpushare-dashboard}
KUBECTL_BIN=${KUBECTL_BIN:-kubectl}
SSH_BIN=${SSH_BIN:-ssh}

read -r -a KUBECTL_CMD <<< "${KUBECTL_BIN}"
kctl() {
  "${KUBECTL_CMD[@]}" "$@"
}

if ! command -v "${KUBECTL_CMD[0]}" >/dev/null 2>&1; then
  echo "${KUBECTL_CMD[0]} not found"
  exit 1
fi
if ! command -v "${SSH_BIN}" >/dev/null 2>&1; then
  echo "${SSH_BIN} not found"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DASHBOARD_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
ARTIFACT_DIR="${DASHBOARD_DIR}/artifacts/$(date +%Y%m%d-%H%M%S)-repair-32050"
mkdir -p "${ARTIFACT_DIR}"
STATE_FILE="${DASHBOARD_DIR}/artifacts/repair-32050.state"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${ARTIFACT_DIR}/run.log"
}

wait_local_healthz() {
  local url=$1
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 "${url}" >"${ARTIFACT_DIR}/local_healthz.json" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_public_healthz() {
  local url=$1
  for _ in $(seq 1 15); do
    if curl -fsS --max-time 4 "${url}" >"${ARTIFACT_DIR}/public_healthz.json" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

log "verifying service ${NAMESPACE}/${SERVICE}"
kctl -n "${NAMESPACE}" get svc "${SERVICE}" >"${ARTIFACT_DIR}/service.txt"

log "cleaning stale remote sshd listener on port ${PUBLIC_PORT}"
${SSH_BIN} "${PUBLIC_HOST}" "pids=\$(ss -lntp 2>/dev/null | awk '/:${PUBLIC_PORT}[[:space:]]/ && /sshd/ {if (match(\$0,/pid=([0-9]+)/,a)) print a[1]}' | sort -u); for p in \$pids; do kill \$p >/dev/null 2>&1 || true; done; ss -lntp | grep ':${PUBLIC_PORT} ' || true" >"${ARTIFACT_DIR}/remote_listener_before.txt" 2>&1 || true

log "starting local port-forward ${LOCAL_PORT} -> svc/${SERVICE}:80"
nohup "${KUBECTL_CMD[@]}" -n "${NAMESPACE}" port-forward svc/"${SERVICE}" "${LOCAL_PORT}:80" >"${ARTIFACT_DIR}/port_forward.log" 2>&1 &
PF_PID=$!

echo "PF_PID=${PF_PID}" >"${STATE_FILE}"

after_local="http://127.0.0.1:${LOCAL_PORT}/api/v1/healthz"
if ! wait_local_healthz "${after_local}"; then
  log "local port-forward healthz failed: ${after_local}"
  exit 1
fi
log "local port-forward is healthy"

log "creating reverse tunnel ${PUBLIC_HOST}:${PUBLIC_PORT} -> 127.0.0.1:${LOCAL_PORT}"
${SSH_BIN} -fNT \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -R "0.0.0.0:${PUBLIC_PORT}:127.0.0.1:${LOCAL_PORT}" \
  "${PUBLIC_HOST}"

PUBLIC_HEALTHZ="http://${PUBLIC_IP}:${PUBLIC_PORT}/api/v1/healthz"
if wait_public_healthz "${PUBLIC_HEALTHZ}"; then
  log "public healthz passed: ${PUBLIC_HEALTHZ}"
else
  log "public healthz failed: ${PUBLIC_HEALTHZ}"
  curl -v --max-time 8 "${PUBLIC_HEALTHZ}" >"${ARTIFACT_DIR}/public_healthz_verbose.txt" 2>&1 || true
  exit 1
fi

${SSH_BIN} "${PUBLIC_HOST}" "ss -lntp | grep ':${PUBLIC_PORT} ' || true" >"${ARTIFACT_DIR}/remote_listener_after.txt" 2>&1 || true

cat >"${ARTIFACT_DIR}/summary.txt" <<TXT
public_url=http://${PUBLIC_IP}:${PUBLIC_PORT}
local_port_forward=http://127.0.0.1:${LOCAL_PORT}
namespace=${NAMESPACE}
service=${SERVICE}
public_port=${PUBLIC_PORT}
state_file=${STATE_FILE}
TXT

log "repair completed. artifacts=${ARTIFACT_DIR}"
ls -1 "${ARTIFACT_DIR}" | sed 's/^/  - /' | tee -a "${ARTIFACT_DIR}/run.log"
