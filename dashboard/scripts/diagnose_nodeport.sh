#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-xpushare-system}
SERVICE=${SERVICE:-xpushare-dashboard}
NODEPORT=${NODEPORT:-32050}
KUBECTL_BIN=${KUBECTL_BIN:-kubectl}
DEBUG_POD=${DEBUG_POD:-nodeport-debug}
DEBUG_IMAGE=${DEBUG_IMAGE:-registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:v0.1-46de863}

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
ARTIFACT_DIR="${DASHBOARD_DIR}/artifacts/$(date +%Y%m%d-%H%M%S)-nodeport-diagnose"
mkdir -p "${ARTIFACT_DIR}"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${ARTIFACT_DIR}/run.log"
}

cleanup() {
  kctl -n "${NAMESPACE}" delete pod "${DEBUG_POD}" --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "namespace=${NAMESPACE} service=${SERVICE} nodePort=${NODEPORT}"
kctl -n "${NAMESPACE}" get svc "${SERVICE}" -o yaml >"${ARTIFACT_DIR}/service.yaml"
kctl -n "${NAMESPACE}" get endpoints "${SERVICE}" -o yaml >"${ARTIFACT_DIR}/endpoints.yaml"
kctl get nodes -o wide >"${ARTIFACT_DIR}/nodes.txt"

CLUSTER_IP=$(kctl -n "${NAMESPACE}" get svc "${SERVICE}" -o jsonpath='{.spec.clusterIP}')
log "clusterIP=${CLUSTER_IP}"

kctl -n "${NAMESPACE}" delete pod "${DEBUG_POD}" --ignore-not-found=true >/dev/null 2>&1 || true
kctl -n "${NAMESPACE}" run "${DEBUG_POD}" --image="${DEBUG_IMAGE}" --restart=Never --command -- sh -c 'sleep 3600' >/dev/null
kctl -n "${NAMESPACE}" wait --for=condition=Ready pod/"${DEBUG_POD}" --timeout=120s >/dev/null
kctl -n "${NAMESPACE}" get pod "${DEBUG_POD}" -o wide >"${ARTIFACT_DIR}/debug_pod.txt"

probe() {
  local target=$1
  local out=$2
  kctl -n "${NAMESPACE}" exec "${DEBUG_POD}" -- sh -c "wget -S -O- -T 4 http://${target}/api/v1/healthz 2>&1" >"${out}" || true
}

probe "${CLUSTER_IP}:80" "${ARTIFACT_DIR}/probe_clusterip_80.txt"

while read -r node_ip; do
  [[ -z "${node_ip}" ]] && continue
  safe_name=${node_ip//./_}
  probe "${node_ip}:${NODEPORT}" "${ARTIFACT_DIR}/probe_node_${safe_name}_${NODEPORT}.txt"
done < <(kctl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

log "diagnose completed. artifacts=${ARTIFACT_DIR}"
ls -1 "${ARTIFACT_DIR}" | sed 's/^/  - /' | tee -a "${ARTIFACT_DIR}/run.log"
