#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PROJECT_ROOT="${SCRIPT_DIR}/.."
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
K8S_MANIFESTS_DIR="${PROJECT_ROOT}/kubernetes/manifests"

REMOTE_HOST="${XP_REMOTE_HOST:-139.196.28.96}"
REMOTE_USER="${XP_REMOTE_USER:-root}"
REMOTE_PORT="${XP_REMOTE_PORT:-22}"
REMOTE_DIR="${XP_REMOTE_DIR:-/root/code/nvshare}"

KUBECONFIG_CUDA="${XP_KUBECONFIG_CUDA:-$HOME/Code/configs/kubeconfig-kcs-gpu}"
KUBECONFIG_CANN="${XP_KUBECONFIG_CANN:-$HOME/Code/configs/kubeconfig-kcs-npu}"

SYSTEM_NAMESPACE="${XP_SYSTEM_NAMESPACE:-nvshare-system}"
WORKLOAD_NAMESPACE="${XP_WORKLOAD_NAMESPACE:-default}"
DOCKERHUB="${XP_DOCKERHUB:-registry.cn-hangzhou.aliyuncs.com/lgytest1}"
IMAGE_NAME="${XP_IMAGE_NAME:-nvshare}"
REMOTE_MAKE_TARGET="${XP_REMOTE_MAKE_TARGET:-buildx-push}"
BASE_IMAGE="${XP_BASE_IMAGE:-registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:baseubuntu}"
BUILD_PLATFORMS="${XP_BUILD_PLATFORMS:-linux/amd64,linux/arm64}"

NVSHARE_VIRTUAL_DEVICES="${XP_NVSHARE_VIRTUAL_DEVICES:-10}"

CUDA_DEVICE_RESOURCE_KEY="${XP_CUDA_DEVICE_RESOURCE_KEY:-nvidia.com/gpu}"
CUDA_DEVICE_RESOURCE_COUNT="${XP_CUDA_DEVICE_RESOURCE_COUNT:-2}"

CANN_DEVICE_RESOURCE_KEY="${XP_CANN_DEVICE_RESOURCE_KEY:-huawei.com/Ascend910}"
CANN_DEVICE_RESOURCE_COUNT="${XP_CANN_DEVICE_RESOURCE_COUNT:-1}"

CANN_WORKLOAD_RESOURCE_KEY="${XP_CANN_WORKLOAD_RESOURCE_KEY:-huawei.com/Ascend910}"
CANN_WORKLOAD_RESOURCE_COUNT="${XP_CANN_WORKLOAD_RESOURCE_COUNT:-1}"

DEFAULT_CUDA_WORKLOAD_IMAGE="registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b"
CUDA_WORKLOAD_IMAGE="${CUDA_WORKLOAD_IMAGE:-$DEFAULT_CUDA_WORKLOAD_IMAGE}"
if [[ -n "${CANN_WORKLOAD_IMAGE:-}" ]]; then
  CANN_WORKLOAD_IMAGE_USER_SET=1
else
  CANN_WORKLOAD_IMAGE_USER_SET=0
fi
CANN_WORKLOAD_IMAGE="${CANN_WORKLOAD_IMAGE:-}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SKIP_SETUP=0
CLUSTERS_CSV="cuda,cann"
KEEP_SMOKE_POD=0
SMOKE_POD_TIMEOUT_SEC="${XP_SMOKE_POD_TIMEOUT_SEC:-900}"

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --skip-setup            Skip local commit, sync and remote build.
  --clusters <csv>        Clusters to run: cuda,cann (default: cuda,cann).
  --run-id <id>           Reuse specified run id.
  --keep-smoke-pod        Do not delete smoke pod after test.
  -h, --help              Show this help.

Environment overrides:
  XP_REMOTE_HOST, XP_REMOTE_USER, XP_REMOTE_PORT, XP_REMOTE_DIR
  XP_KUBECONFIG_CUDA, XP_KUBECONFIG_CANN
  XP_DOCKERHUB, XP_IMAGE_NAME, XP_REMOTE_MAKE_TARGET, XP_BASE_IMAGE, XP_BUILD_PLATFORMS
  XP_SMOKE_POD_TIMEOUT_SEC
  CUDA_WORKLOAD_IMAGE, CANN_WORKLOAD_IMAGE
  CUDA_PROBE_CMD, CANN_PROBE_CMD
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-setup)
      SKIP_SETUP=1
      shift
      ;;
    --clusters)
      CLUSTERS_CSV="$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    --keep-smoke-pod)
      KEEP_SMOKE_POD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

IFS=',' read -r -a CLUSTERS <<< "$CLUSTERS_CSV"

for c in "${CLUSTERS[@]}"; do
  if [[ "$c" != "cuda" && "$c" != "cann" ]]; then
    echo "Unsupported cluster: $c"
    exit 1
  fi
done

LOG_ROOT="${PROJECT_ROOT}/.tmplog/${RUN_ID}/remote-smoke"
mkdir -p "$LOG_ROOT"

RUN_SUMMARY="${LOG_ROOT}/run-summary.tsv"
printf "cluster\tstatus\tsummary\n" > "$RUN_SUMMARY"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[SMOKE][INFO][$(date +%F' '%T)]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[SMOKE][WARN][$(date +%F' '%T)]${NC} $*"; }
log_error() { echo -e "${RED}[SMOKE][ERROR][$(date +%F' '%T)]${NC} $*"; }

get_kubeconfig() {
  local cluster="$1"
  case "$cluster" in
    cuda) echo "$KUBECONFIG_CUDA" ;;
    cann) echo "$KUBECONFIG_CANN" ;;
    *) return 1 ;;
  esac
}

kube() {
  local cluster="$1"
  shift
  local kcfg
  kcfg=$(get_kubeconfig "$cluster")
  kubectl --kubeconfig "$kcfg" "$@"
}

CUDA_PROBE_CMD_DEFAULT=$(cat <<'EOC'
python3 - <<'PY'
import sys
import torch
print("probe=CUDA start")
if not torch.cuda.is_available():
    print("CUDA not available")
    sys.exit(2)
idx = torch.cuda.current_device()
name = torch.cuda.get_device_name(idx)
a = torch.ones((1024, 1024), dtype=torch.float32, device='cuda')
b = a + a
torch.cuda.synchronize()
print(f"CUDA device {idx}: {name}")
print(f"checksum={float(b.sum().item())}")
print("PASS")
PY
EOC
)

CANN_PROBE_CMD_DEFAULT=$(cat <<'EOC'
echo "probe=CANN start"
uname -a
if [ ! -x /usr/local/bin/nvshare-scheduler ]; then
  echo "missing /usr/local/bin/nvshare-scheduler"
  exit 2
fi
echo "PASS"
EOC
)

CUDA_PROBE_CMD="${CUDA_PROBE_CMD:-$CUDA_PROBE_CMD_DEFAULT}"
CANN_PROBE_CMD="${CANN_PROBE_CMD:-$CANN_PROBE_CMD_DEFAULT}"

NVSHARE_TAG=""
LIB_IMAGE=""
SCHEDULER_IMAGE=""
DEVICE_PLUGIN_IMAGE=""

refresh_images_from_git() {
  NVSHARE_TAG=$(git -C "$PROJECT_ROOT" rev-parse HEAD | cut -c 1-8)
  LIB_IMAGE="${DOCKERHUB}/${IMAGE_NAME}:libnvshare-${NVSHARE_TAG}"
  SCHEDULER_IMAGE="${DOCKERHUB}/${IMAGE_NAME}:nvshare-scheduler-${NVSHARE_TAG}"
  DEVICE_PLUGIN_IMAGE="${DOCKERHUB}/${IMAGE_NAME}:nvshare-device-plugin-${NVSHARE_TAG}"
  if [[ "$CANN_WORKLOAD_IMAGE_USER_SET" -eq 0 ]]; then
    CANN_WORKLOAD_IMAGE="$SCHEDULER_IMAGE"
  fi
}

auto_commit_if_needed() {
  if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]]; then
    log_info "local changes detected, committing before remote sync"
    git -C "$PROJECT_ROOT" add -A
    git -C "$PROJECT_ROOT" commit -m "wip: auto-commit by remote-test-smoke.sh [$(date +%F_%T)]"
  else
    log_info "no local changes, skip commit"
  fi
}

sync_to_remote() {
  log_info "sync source to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
  rsync -az --delete \
    --exclude '.idea' \
    --exclude '.DS_Store' \
    --exclude '.tmplog' \
    -e "ssh -o StrictHostKeyChecking=no -p ${REMOTE_PORT}" \
    "${PROJECT_ROOT}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
}

remote_build_and_push() {
  log_info "remote build target=${REMOTE_MAKE_TARGET} base_image=${BASE_IMAGE} platforms=${BUILD_PLATFORMS}"
  local remote_prefix="cd '${REMOTE_DIR}'"
  local remote_builder_setup=""

  if [[ "${REMOTE_MAKE_TARGET}" == *"buildx"* ]]; then
    remote_builder_setup=" \
      docker buildx inspect nvshare-builder >/dev/null 2>&1 || \
      docker buildx create --name nvshare-builder --driver docker-container --use >/dev/null; \
      docker buildx use nvshare-builder >/dev/null 2>&1 || true; \
      docker buildx inspect --bootstrap >/dev/null"
  fi

  if [[ "${REMOTE_MAKE_TARGET}" == "buildx-push" || "${REMOTE_MAKE_TARGET}" == "buildx-push-components" ]]; then
    ssh -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
      "${remote_prefix} && ${remote_builder_setup} && \
       docker buildx build --platform '${BUILD_PLATFORMS}' -f Dockerfile.libnvshare --build-arg BASE_IMAGE='${BASE_IMAGE}' -t '${LIB_IMAGE}' --push . && \
       docker buildx build --platform '${BUILD_PLATFORMS}' -f Dockerfile.scheduler --build-arg BASE_IMAGE='${BASE_IMAGE}' -t '${SCHEDULER_IMAGE}' --push . && \
       docker buildx build --platform '${BUILD_PLATFORMS}' -f Dockerfile.device_plugin -t '${DEVICE_PLUGIN_IMAGE}' --push ."
  else
    ssh -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
      "${remote_prefix} && ${remote_builder_setup} && make ${REMOTE_MAKE_TARGET} DOCKERHUB='${DOCKERHUB}' IMAGE='${IMAGE_NAME}'"
  fi
}

render_scheduler_manifest() {
  local cluster="$1"
  local outfile="$2"
  local selector_block=""
  local toleration_key="nvidia.com/gpu"

  if [[ "$cluster" == "cann" ]]; then
    toleration_key="$CANN_DEVICE_RESOURCE_KEY"
    selector_block=$(cat <<'EOB'
      nodeSelector:
        kubernetes.io/arch: arm64
        accelerator: huawei-Ascend910
EOB
)
  fi

  cat > "$outfile" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvshare-scheduler
  namespace: ${SYSTEM_NAMESPACE}
spec:
  selector:
    matchLabels:
      name: nvshare-scheduler
  template:
    metadata:
      labels:
        name: nvshare-scheduler
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9402"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: nvshare-scheduler
      priorityClassName: system-node-critical
      hostPID: true
      containers:
      - name: nvshare-scheduler
        image: ${SCHEDULER_IMAGE}
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        ports:
        - containerPort: 9402
          name: metrics
          protocol: TCP
        volumeMounts:
        - name: nvshare-socket-directory
          mountPath: /var/run/nvshare
        env:
        - name: NVSHARE_DEBUG
          value: "1"
        - name: NVSHARE_METRICS_ENABLE
          value: "1"
        - name: NVSHARE_COMPUTE_WINDOW_MS
          value: "4000"
        - name: NVSHARE_QUOTA_CARRYOVER_PERCENT
          value: "0"
        - name: NVSHARE_QUOTA_SAMPLE_INTERVAL_MS
          value: "20"
        - name: NVSHARE_DROP_TAIL_BILLING_PERCENT
          value: "70"
      volumes:
      - name: nvshare-socket-directory
        hostPath:
          path: /var/run/nvshare
          type: DirectoryOrCreate
${selector_block}
      tolerations:
      - key: ${toleration_key}
        operator: Exists
        effect: NoSchedule
EOF
}

render_device_plugin_manifest() {
  local cluster="$1"
  local outfile="$2"
  local selector_block=""
  local toleration_key="$CUDA_DEVICE_RESOURCE_KEY"
  local resource_key="$CUDA_DEVICE_RESOURCE_KEY"
  local resource_count="$CUDA_DEVICE_RESOURCE_COUNT"
  local extra_env=""

  if [[ "$cluster" == "cann" ]]; then
    toleration_key="$CANN_DEVICE_RESOURCE_KEY"
    resource_key="$CANN_DEVICE_RESOURCE_KEY"
    resource_count="$CANN_DEVICE_RESOURCE_COUNT"
    selector_block=$(cat <<'EOB'
      nodeSelector:
        kubernetes.io/arch: arm64
        accelerator: huawei-Ascend910
EOB
)
    extra_env=$(cat <<'EOB'
        - name: NVIDIA_VISIBLE_DEVICES
          value: "ASCEND910-0"
EOB
)
  fi

  cat > "$outfile" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvshare-device-plugin
  namespace: ${SYSTEM_NAMESPACE}
spec:
  selector:
    matchLabels:
      name: nvshare-device-plugin
  template:
    metadata:
      labels:
        name: nvshare-device-plugin
    spec:
      priorityClassName: system-node-critical
      containers:
      - name: nvshare-lib
        image: ${LIB_IMAGE}
        command:
        - "/bin/sh"
        - "-c"
        - |
          LIB=/host-var-run-nvshare/libnvshare.so
          SRC=/libnvshare.so
          trap "umount \$LIB; rm -f \$LIB; exit 0" TERM INT EXIT
          if [ -d "\$LIB" ]; then
            rm -rf "\$LIB"
          fi
          if ! grep -qs "\$LIB" /proc/mounts; then
            touch \$LIB
            mount --bind \$SRC \$LIB
          fi
          sleep infinity & wait
        securityContext:
          privileged: true
        volumeMounts:
        - mountPath: /host-var-run-nvshare
          name: host-var-run-nvshare
          mountPropagation: Bidirectional
      - name: nvshare-device-plugin
        image: ${DEVICE_PLUGIN_IMAGE}
        imagePullPolicy: IfNotPresent
        env:
        - name: NVSHARE_VIRTUAL_DEVICES
          value: "${NVSHARE_VIRTUAL_DEVICES}"
${extra_env}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: device-plugin-socket
          mountPath: /var/lib/kubelet/device-plugins
        resources:
          limits:
            ${resource_key}: ${resource_count}
      volumes:
      - name: host-var-run-nvshare
        hostPath:
          path: /var/run/nvshare
          type: DirectoryOrCreate
      - name: device-plugin-socket
        hostPath:
          path: /var/lib/kubelet/device-plugins
${selector_block}
      tolerations:
      - key: ${toleration_key}
        operator: Exists
        effect: NoSchedule
EOF
}

render_smoke_pod_manifest() {
  local cluster="$1"
  local outfile="$2"
  local pod_name="$3"
  local image=""
  local probe_cmd=""
  local extra_limits=""
  local node_selector=""
  local tolerations=""
  local shell_bin="/bin/bash"

  if [[ "$cluster" == "cuda" ]]; then
    image="$CUDA_WORKLOAD_IMAGE"
    probe_cmd="$CUDA_PROBE_CMD"
    tolerations=$(cat <<'EOB'
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
EOB
)
  else
    image="$CANN_WORKLOAD_IMAGE"
    probe_cmd="$CANN_PROBE_CMD"
    shell_bin="/bin/sh"
    extra_limits="        ${CANN_WORKLOAD_RESOURCE_KEY}: ${CANN_WORKLOAD_RESOURCE_COUNT}"
    node_selector=$(cat <<'EOB'
  nodeSelector:
    kubernetes.io/arch: arm64
    accelerator: huawei-Ascend910
EOB
)
    tolerations=$(cat <<EOB
  tolerations:
  - key: ${CANN_WORKLOAD_RESOURCE_KEY}
    operator: Exists
    effect: NoSchedule
EOB
)
  fi

  local cmd_block
  cmd_block="$(printf '%s\n' "$probe_cmd" | sed 's/^/      /')"

  cat > "$outfile" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${WORKLOAD_NAMESPACE}
  labels:
    app: nvshare-remote-smoke
    smoke-cluster: ${cluster}
spec:
  restartPolicy: Never
  containers:
  - name: probe
    image: ${image}
    command:
    - ${shell_bin}
    - -lc
    - |
${cmd_block}
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    resources:
      limits:
        nvshare.com/gpu: 1
${extra_limits}
${node_selector}
${tolerations}
EOF
}

wait_for_pod_terminal() {
  local cluster="$1"
  local pod_name="$2"
  local timeout_sec="$3"
  local start_ts
  start_ts=$(date +%s)

  while true; do
    local phase
    phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "$phase" == "Succeeded" ]]; then
      return 0
    fi
    if [[ "$phase" == "Failed" ]]; then
      return 1
    fi

    local now
    now=$(date +%s)
    if (( now - start_ts > timeout_sec )); then
      log_warn "pod ${pod_name} timeout after ${timeout_sec}s (phase=${phase})"
      return 2
    fi

    sleep 5
  done
}

capture_cluster_logs() {
  local cluster="$1"
  local cluster_log_dir="$2"
  local pod_name="$3"

  kube "$cluster" get nodes -o wide > "${cluster_log_dir}/nodes.txt" 2>&1 || true
  kube "$cluster" -n "$SYSTEM_NAMESPACE" get pods -o wide > "${cluster_log_dir}/system-pods.txt" 2>&1 || true
  kube "$cluster" -n "$SYSTEM_NAMESPACE" logs -l name=nvshare-scheduler --timestamps > "${cluster_log_dir}/scheduler.log" 2>&1 || true
  kube "$cluster" -n "$SYSTEM_NAMESPACE" logs -l name=nvshare-device-plugin --timestamps > "${cluster_log_dir}/device-plugin.log" 2>&1 || true
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" logs "$pod_name" > "${cluster_log_dir}/workload.log" 2>&1 || true
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" describe pod "$pod_name" > "${cluster_log_dir}/workload.describe.txt" 2>&1 || true
}

check_metrics_endpoint() {
  local cluster="$1"
  local cluster_log_dir="$2"
  local port="$3"
  local sched_pod

  sched_pod=$(kube "$cluster" -n "$SYSTEM_NAMESPACE" get pod -l name=nvshare-scheduler -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "$sched_pod" ]]; then
    log_error "${cluster}: scheduler pod not found"
    return 1
  fi

  local pf_log="${cluster_log_dir}/port-forward.log"
  kube "$cluster" -n "$SYSTEM_NAMESPACE" port-forward "pod/${sched_pod}" "${port}:9402" > "$pf_log" 2>&1 &
  local pf_pid=$!
  sleep 2

  local health_code
  health_code="000"
  local i
  for i in $(seq 1 20); do
    health_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/healthz" || true)
    if [[ "$health_code" == "200" ]]; then
      break
    fi
    sleep 1
  done
  curl -s "http://127.0.0.1:${port}/metrics" > "${cluster_log_dir}/metrics.txt" || true

  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true

  if [[ "$health_code" == "000" ]]; then
    for i in $(seq 1 3); do
      sched_pod=$(kube "$cluster" -n "$SYSTEM_NAMESPACE" get pod -l name=nvshare-scheduler -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      if [[ -z "$sched_pod" ]]; then
        sleep 1
        continue
      fi
      local proxy_health=""
      proxy_health=$(kube "$cluster" get --raw "/api/v1/namespaces/${SYSTEM_NAMESPACE}/pods/${sched_pod}:9402/proxy/healthz" 2>>"$pf_log" || true)
      kube "$cluster" get --raw "/api/v1/namespaces/${SYSTEM_NAMESPACE}/pods/${sched_pod}:9402/proxy/metrics" > "${cluster_log_dir}/metrics.txt" 2>>"$pf_log" || true
      if [[ "$proxy_health" == "ok" ]]; then
        health_code="200"
        break
      fi
      sleep 1
    done
  fi

  if [[ "$health_code" != "200" ]]; then
    log_error "${cluster}: /healthz code=${health_code}"
    return 1
  fi

  if ! grep -q '^nvshare_scheduler_messages_total' "${cluster_log_dir}/metrics.txt"; then
    log_error "${cluster}: metrics missing nvshare_scheduler_messages_total"
    return 1
  fi

  if [[ "$cluster" == "cuda" ]]; then
    if ! grep -q 'nvshare_gpu_sampler_backend_info{backend="nvml"}' "${cluster_log_dir}/metrics.txt"; then
      log_warn "${cluster}: sampler backend is not nvml"
    fi
  else
    if ! grep -q '^nvshare_gpu_sampler_up' "${cluster_log_dir}/metrics.txt"; then
      log_warn "${cluster}: metrics missing nvshare_gpu_sampler_up"
    fi
  fi

  return 0
}

deploy_stack() {
  local cluster="$1"
  local scheduler_manifest="$2"
  local device_manifest="$3"

  kube "$cluster" apply -f "${MANIFESTS_DIR}/nvshare-system.yaml"
  kube "$cluster" apply -f "${MANIFESTS_DIR}/nvshare-system-quotas.yaml"
  kube "$cluster" apply -f "${K8S_MANIFESTS_DIR}/scheduler-rbac.yaml"

  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod -l app=nvshare-remote-smoke --ignore-not-found=true --wait=true || true
  kube "$cluster" -n "$SYSTEM_NAMESPACE" delete ds nvshare-scheduler nvshare-device-plugin --ignore-not-found=true --wait=true

  kube "$cluster" apply -f "$scheduler_manifest"
  kube "$cluster" apply -f "$device_manifest"

  kube "$cluster" -n "$SYSTEM_NAMESPACE" rollout status ds/nvshare-scheduler --timeout=240s
  kube "$cluster" -n "$SYSTEM_NAMESPACE" rollout status ds/nvshare-device-plugin --timeout=240s
}

run_cluster_smoke() {
  local cluster="$1"
  local cluster_log_dir="${LOG_ROOT}/${cluster}"
  mkdir -p "$cluster_log_dir"

  local scheduler_manifest="${cluster_log_dir}/scheduler.yaml"
  local device_manifest="${cluster_log_dir}/device-plugin.yaml"
  local pod_manifest="${cluster_log_dir}/smoke-pod.yaml"
  local pod_name="nvshare-smoke-${cluster}"

  log_info "[${cluster}] render manifests"
  render_scheduler_manifest "$cluster" "$scheduler_manifest"
  render_device_plugin_manifest "$cluster" "$device_manifest"
  render_smoke_pod_manifest "$cluster" "$pod_manifest" "$pod_name"

  log_info "[${cluster}] deploy scheduler and device-plugin"
  deploy_stack "$cluster" "$scheduler_manifest" "$device_manifest"

  log_info "[${cluster}] create smoke workload pod=${pod_name}"
  kube "$cluster" apply -f "$pod_manifest"

  local wait_rc=0
  wait_for_pod_terminal "$cluster" "$pod_name" "$SMOKE_POD_TIMEOUT_SEC" || wait_rc=$?

  capture_cluster_logs "$cluster" "$cluster_log_dir" "$pod_name"

  local phase
  phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

  local summary=""
  local status="PASS"

  if [[ "$wait_rc" -ne 0 ]]; then
    status="FAIL"
    summary="workload timeout_or_failure phase=${phase}"
  elif [[ "$phase" != "Succeeded" ]]; then
    status="FAIL"
    summary="workload not succeeded phase=${phase}"
  elif ! grep -q "PASS" "${cluster_log_dir}/workload.log"; then
    status="FAIL"
    summary="workload log missing PASS"
  fi

  if [[ "$status" == "PASS" ]]; then
    if ! check_metrics_endpoint "$cluster" "$cluster_log_dir" "$((19400 + RANDOM % 1000))"; then
      status="FAIL"
      summary="metrics check failed"
    else
      summary="workload and metrics passed"
    fi
  fi

  if [[ "$KEEP_SMOKE_POD" -eq 0 ]]; then
    kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=false || true
  fi

  printf "%s\t%s\t%s\n" "$cluster" "$status" "$summary" >> "$RUN_SUMMARY"

  if [[ "$status" == "PASS" ]]; then
    log_info "[${cluster}] PASS - ${summary}"
    return 0
  fi

  log_error "[${cluster}] FAIL - ${summary}"
  return 1
}

main() {
  log_info "run_id=${RUN_ID}"
  log_info "log_root=${LOG_ROOT}"
  log_info "clusters=${CLUSTERS[*]}"

  if [[ "$SKIP_SETUP" -eq 0 ]]; then
    auto_commit_if_needed
    refresh_images_from_git
    log_info "images: scheduler=${SCHEDULER_IMAGE} device=${DEVICE_PLUGIN_IMAGE} lib=${LIB_IMAGE}"
    sync_to_remote
    remote_build_and_push
  else
    refresh_images_from_git
    log_warn "setup skipped, using images by local HEAD tag=${NVSHARE_TAG}"
  fi

  local overall_rc=0
  local cluster
  for cluster in "${CLUSTERS[@]}"; do
    if ! run_cluster_smoke "$cluster"; then
      overall_rc=1
    fi
  done

  log_info "run summary: ${RUN_SUMMARY}"
  if [[ "$overall_rc" -ne 0 ]]; then
    log_error "smoke run finished with failures"
  else
    log_info "smoke run passed"
  fi
  return "$overall_rc"
}

main "$@"
