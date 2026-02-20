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
SPLIT_ARCH_BUILD="${XP_SPLIT_ARCH_BUILD:-1}"
GO_BUILDER_IMAGE="${XP_GO_BUILDER_IMAGE:-docker.io/library/golang:1.15.15}"
GO_BUILDER_IMAGE_ARM64="${XP_GO_BUILDER_IMAGE_ARM64:-registry.cn-hangzhou.aliyuncs.com/lgytest1/golang:1.15.15-arm64}"
GO_BUILDER_IMAGE_AMD64="${XP_GO_BUILDER_IMAGE_AMD64:-registry.cn-hangzhou.aliyuncs.com/lgytest1/golang:1.15.15-amd64}"

NVSHARE_VIRTUAL_DEVICES="${XP_NVSHARE_VIRTUAL_DEVICES:-10}"

CUDA_DEVICE_RESOURCE_KEY="${XP_CUDA_DEVICE_RESOURCE_KEY:-nvidia.com/gpu}"
CUDA_DEVICE_RESOURCE_COUNT="${XP_CUDA_DEVICE_RESOURCE_COUNT:-2}"

CANN_DEVICE_RESOURCE_KEY="${XP_CANN_DEVICE_RESOURCE_KEY:-huawei.com/Ascend910}"
CANN_DEVICE_RESOURCE_COUNT="${XP_CANN_DEVICE_RESOURCE_COUNT:-1}"

CANN_WORKLOAD_RESOURCE_KEY="${XP_CANN_WORKLOAD_RESOURCE_KEY:-huawei.com/Ascend910}"
CANN_WORKLOAD_RESOURCE_COUNT="${XP_CANN_WORKLOAD_RESOURCE_COUNT:-1}"

DEFAULT_CUDA_WORKLOAD_IMAGE="registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b"
DEFAULT_CUDA_BENCH_IMAGE="registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b"
DEFAULT_CANN_BENCH_IMAGE="registry.cn-hangzhou.aliyuncs.com/lgytest1/ascend-pytorch:cann8.2-pt2.6"
CUDA_WORKLOAD_IMAGE="${CUDA_WORKLOAD_IMAGE:-$DEFAULT_CUDA_WORKLOAD_IMAGE}"
if [[ -n "${CANN_WORKLOAD_IMAGE:-}" ]]; then
  CANN_WORKLOAD_IMAGE_USER_SET=1
else
  CANN_WORKLOAD_IMAGE_USER_SET=0
fi
CANN_WORKLOAD_IMAGE="${CANN_WORKLOAD_IMAGE:-}"
if [[ -n "${CANN_BENCH_IMAGE:-}" ]]; then
  CANN_BENCH_IMAGE_USER_SET=1
else
  CANN_BENCH_IMAGE_USER_SET=0
fi
CANN_BENCH_IMAGE="${CANN_BENCH_IMAGE:-$DEFAULT_CANN_BENCH_IMAGE}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SKIP_SETUP=0
CLUSTERS_CSV="cuda,cann"
KEEP_SMOKE_POD=0
SMOKE_POD_TIMEOUT_SEC="${XP_SMOKE_POD_TIMEOUT_SEC:-900}"
PERF_BENCH="${XP_PERF_BENCH:-0}"
PERF_ONLY=0
PERF_ROUNDS="${XP_PERF_ROUNDS:-1}"
PERF_TIMEOUT_SEC="${XP_PERF_TIMEOUT_SEC:-1800}"
QUOTA_CHECK="${XP_QUOTA_CHECK:-0}"
QUOTA_ONLY=0
QUOTA_TIMEOUT_SEC="${XP_QUOTA_TIMEOUT_SEC:-1200}"
QUOTA_OBSERVE_TIMEOUT_SEC="${XP_QUOTA_OBSERVE_TIMEOUT_SEC:-180}"
CUDA_BENCH_IMAGE="${CUDA_BENCH_IMAGE:-$DEFAULT_CUDA_BENCH_IMAGE}"
CUDA_BENCH_ITERS="${CUDA_BENCH_ITERS:-80}"
CUDA_BENCH_MATMUL_SIZE="${CUDA_BENCH_MATMUL_SIZE:-2048}"
CANN_BENCH_ITERS="${CANN_BENCH_ITERS:-40000}"
CANN_BENCH_N="${CANN_BENCH_N:-14000}"
MANIFEST_PUSH_RETRIES="${XP_MANIFEST_PUSH_RETRIES:-8}"
MANIFEST_PUSH_RETRY_BASE_SEC="${XP_MANIFEST_PUSH_RETRY_BASE_SEC:-3}"
MANIFEST_PUSH_COOLDOWN_SEC="${XP_MANIFEST_PUSH_COOLDOWN_SEC:-2}"

CANN_QUOTA_MEM_STATIC_LIMIT="${XP_CANN_QUOTA_MEM_STATIC_LIMIT:-1Gi}"
CANN_QUOTA_MEM_DYNAMIC_START_LIMIT="${XP_CANN_QUOTA_MEM_DYNAMIC_START_LIMIT:-1Gi}"
CANN_QUOTA_MEM_DYNAMIC_TARGET_LIMIT="${XP_CANN_QUOTA_MEM_DYNAMIC_TARGET_LIMIT:-2Gi}"
CANN_QUOTA_MEM_N="${XP_CANN_QUOTA_MEM_N:-14000}"
CANN_QUOTA_MEM_STATIC_SETTLE_SEC="${XP_CANN_QUOTA_MEM_STATIC_SETTLE_SEC:-20}"
CANN_QUOTA_CORE_N="${XP_CANN_QUOTA_CORE_N:-4096}"
CANN_QUOTA_CORE_DURATION_SEC="${XP_CANN_QUOTA_CORE_DURATION_SEC:-90}"
CANN_QUOTA_CORE_STATIC_ITERS="${XP_CANN_QUOTA_CORE_STATIC_ITERS:-5000}"
CANN_QUOTA_CORE_STATIC_WARMUP_ITERS="${XP_CANN_QUOTA_CORE_STATIC_WARMUP_ITERS:-20}"
CANN_QUOTA_CORE_STATIC_LOW="${XP_CANN_QUOTA_CORE_STATIC_LOW:-50}"
CANN_QUOTA_CORE_STATIC_HIGH="${XP_CANN_QUOTA_CORE_STATIC_HIGH:-80}"
CANN_QUOTA_CORE_STATIC_RETRIES="${XP_CANN_QUOTA_CORE_STATIC_RETRIES:-2}"
CANN_QUOTA_CORE_RETRY_BACKOFF_SEC="${XP_CANN_QUOTA_CORE_RETRY_BACKOFF_SEC:-8}"
CANN_QUOTA_CORE_DYNAMIC_START="${XP_CANN_QUOTA_CORE_DYNAMIC_START:-20}"
CANN_QUOTA_CORE_DYNAMIC_TARGET="${XP_CANN_QUOTA_CORE_DYNAMIC_TARGET:-80}"
CANN_QUOTA_CORE_GAIN_THRESHOLD="${XP_CANN_QUOTA_CORE_GAIN_THRESHOLD:-1.70}"

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --skip-setup            Skip local commit, sync and remote build.
  --clusters <csv>        Clusters to run: cuda,cann (default: cuda,cann).
  --run-id <id>           Reuse specified run id.
  --keep-smoke-pod        Do not delete smoke pod after test.
  --perf-bench            Run native vs nvshare performance benchmark.
  --perf-only             Run only performance benchmark (skip smoke).
  --perf-rounds <n>       Benchmark rounds per mode (default: 1).
  --perf-timeout-sec <n>  Timeout for each benchmark pod (default: 1800).
  --quota-check           Run CANN quota test cases (memory/core + dynamic updates).
  --quota-only            Run only CANN quota test cases (skip smoke/perf).
  -h, --help              Show this help.

Environment overrides:
  XP_REMOTE_HOST, XP_REMOTE_USER, XP_REMOTE_PORT, XP_REMOTE_DIR
  XP_KUBECONFIG_CUDA, XP_KUBECONFIG_CANN
  XP_DOCKERHUB, XP_IMAGE_NAME, XP_REMOTE_MAKE_TARGET, XP_BASE_IMAGE, XP_BUILD_PLATFORMS, XP_SPLIT_ARCH_BUILD
  XP_GO_BUILDER_IMAGE, XP_GO_BUILDER_IMAGE_ARM64, XP_GO_BUILDER_IMAGE_AMD64
  XP_SMOKE_POD_TIMEOUT_SEC
  XP_PERF_BENCH, XP_PERF_ROUNDS, XP_PERF_TIMEOUT_SEC
  XP_QUOTA_CHECK, XP_QUOTA_TIMEOUT_SEC, XP_QUOTA_OBSERVE_TIMEOUT_SEC
  XP_MANIFEST_PUSH_RETRIES, XP_MANIFEST_PUSH_RETRY_BASE_SEC, XP_MANIFEST_PUSH_COOLDOWN_SEC
  CUDA_WORKLOAD_IMAGE, CANN_WORKLOAD_IMAGE, CUDA_BENCH_IMAGE, CANN_BENCH_IMAGE
  CUDA_BENCH_ITERS, CUDA_BENCH_MATMUL_SIZE, CANN_BENCH_ITERS, CANN_BENCH_N
  XP_CANN_QUOTA_MEM_STATIC_LIMIT, XP_CANN_QUOTA_MEM_DYNAMIC_START_LIMIT, XP_CANN_QUOTA_MEM_DYNAMIC_TARGET_LIMIT
  XP_CANN_QUOTA_MEM_N, XP_CANN_QUOTA_MEM_STATIC_SETTLE_SEC
  XP_CANN_QUOTA_CORE_N, XP_CANN_QUOTA_CORE_DURATION_SEC
  XP_CANN_QUOTA_CORE_STATIC_ITERS, XP_CANN_QUOTA_CORE_STATIC_WARMUP_ITERS
  XP_CANN_QUOTA_CORE_STATIC_LOW, XP_CANN_QUOTA_CORE_STATIC_HIGH
  XP_CANN_QUOTA_CORE_STATIC_RETRIES, XP_CANN_QUOTA_CORE_RETRY_BACKOFF_SEC
  XP_CANN_QUOTA_CORE_DYNAMIC_START, XP_CANN_QUOTA_CORE_DYNAMIC_TARGET, XP_CANN_QUOTA_CORE_GAIN_THRESHOLD
  CUDA_PROBE_CMD, CANN_PROBE_CMD
  CUDA_BENCH_CMD, CANN_BENCH_CMD
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
    --perf-bench)
      PERF_BENCH=1
      shift
      ;;
    --perf-only)
      PERF_ONLY=1
      PERF_BENCH=1
      shift
      ;;
    --perf-rounds)
      PERF_ROUNDS="$2"
      PERF_BENCH=1
      shift 2
      ;;
    --perf-timeout-sec)
      PERF_TIMEOUT_SEC="$2"
      PERF_BENCH=1
      shift 2
      ;;
    --quota-check)
      QUOTA_CHECK=1
      shift
      ;;
    --quota-only)
      QUOTA_ONLY=1
      QUOTA_CHECK=1
      PERF_ONLY=0
      PERF_BENCH=0
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

if ! [[ "$PERF_ROUNDS" =~ ^[0-9]+$ ]] || [[ "$PERF_ROUNDS" -le 0 ]]; then
  echo "Invalid --perf-rounds: $PERF_ROUNDS"
  exit 1
fi

if ! [[ "$PERF_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$PERF_TIMEOUT_SEC" -le 0 ]]; then
  echo "Invalid --perf-timeout-sec: $PERF_TIMEOUT_SEC"
  exit 1
fi

if [[ "$PERF_BENCH" != "0" && "$PERF_BENCH" != "1" ]]; then
  echo "Invalid XP_PERF_BENCH: $PERF_BENCH (expect 0 or 1)"
  exit 1
fi

if [[ "$QUOTA_CHECK" != "0" && "$QUOTA_CHECK" != "1" ]]; then
  echo "Invalid XP_QUOTA_CHECK: $QUOTA_CHECK (expect 0 or 1)"
  exit 1
fi

if ! [[ "$QUOTA_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$QUOTA_TIMEOUT_SEC" -le 0 ]]; then
  echo "Invalid XP_QUOTA_TIMEOUT_SEC: $QUOTA_TIMEOUT_SEC"
  exit 1
fi

if ! [[ "$QUOTA_OBSERVE_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$QUOTA_OBSERVE_TIMEOUT_SEC" -le 0 ]]; then
  echo "Invalid XP_QUOTA_OBSERVE_TIMEOUT_SEC: $QUOTA_OBSERVE_TIMEOUT_SEC"
  exit 1
fi

if ! [[ "$CANN_QUOTA_MEM_STATIC_SETTLE_SEC" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_MEM_STATIC_SETTLE_SEC" -lt 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_MEM_STATIC_SETTLE_SEC: $CANN_QUOTA_MEM_STATIC_SETTLE_SEC"
  exit 1
fi

if ! [[ "$CANN_QUOTA_CORE_STATIC_RETRIES" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_CORE_STATIC_RETRIES" -le 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_CORE_STATIC_RETRIES: $CANN_QUOTA_CORE_STATIC_RETRIES"
  exit 1
fi

if ! [[ "$CANN_QUOTA_CORE_RETRY_BACKOFF_SEC" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_CORE_RETRY_BACKOFF_SEC" -lt 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_CORE_RETRY_BACKOFF_SEC: $CANN_QUOTA_CORE_RETRY_BACKOFF_SEC"
  exit 1
fi

if ! [[ "$CANN_QUOTA_CORE_STATIC_ITERS" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_CORE_STATIC_ITERS" -le 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_CORE_STATIC_ITERS: $CANN_QUOTA_CORE_STATIC_ITERS"
  exit 1
fi

if ! [[ "$CANN_QUOTA_CORE_STATIC_WARMUP_ITERS" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_CORE_STATIC_WARMUP_ITERS" -lt 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_CORE_STATIC_WARMUP_ITERS: $CANN_QUOTA_CORE_STATIC_WARMUP_ITERS"
  exit 1
fi

if [[ "$SPLIT_ARCH_BUILD" != "0" && "$SPLIT_ARCH_BUILD" != "1" ]]; then
  echo "Invalid XP_SPLIT_ARCH_BUILD: $SPLIT_ARCH_BUILD (expect 0 or 1)"
  exit 1
fi

if ! [[ "$MANIFEST_PUSH_RETRIES" =~ ^[0-9]+$ ]] || [[ "$MANIFEST_PUSH_RETRIES" -le 0 ]]; then
  echo "Invalid XP_MANIFEST_PUSH_RETRIES: $MANIFEST_PUSH_RETRIES"
  exit 1
fi

if ! [[ "$MANIFEST_PUSH_RETRY_BASE_SEC" =~ ^[0-9]+$ ]] || [[ "$MANIFEST_PUSH_RETRY_BASE_SEC" -le 0 ]]; then
  echo "Invalid XP_MANIFEST_PUSH_RETRY_BASE_SEC: $MANIFEST_PUSH_RETRY_BASE_SEC"
  exit 1
fi

if ! [[ "$MANIFEST_PUSH_COOLDOWN_SEC" =~ ^[0-9]+$ ]] || [[ "$MANIFEST_PUSH_COOLDOWN_SEC" -lt 0 ]]; then
  echo "Invalid XP_MANIFEST_PUSH_COOLDOWN_SEC: $MANIFEST_PUSH_COOLDOWN_SEC"
  exit 1
fi

LOG_ROOT="${PROJECT_ROOT}/.tmplog/${RUN_ID}/remote-smoke"
mkdir -p "$LOG_ROOT"

RUN_SUMMARY="${LOG_ROOT}/run-summary.tsv"
printf "cluster\tstatus\tsummary\n" > "$RUN_SUMMARY"
PERF_SUMMARY="${LOG_ROOT}/perf-summary.tsv"
printf "cluster\tmode\tpass_rounds\tavg_wall_ms\tavg_bench_ms\n" > "$PERF_SUMMARY"

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

CUDA_BENCH_CMD_DEFAULT=""

CANN_BENCH_CMD_DEFAULT=$(cat <<'EOC'
python3 - <<'PY'
import os
import sys
import time
import torch

try:
    import torch_npu  # noqa: F401
except Exception as e:
    print(f"torch_npu import failed: {e}")
    sys.exit(2)

iters = int(os.getenv("CANN_BENCH_ITERS", "40000"))
n = int(os.getenv("CANN_BENCH_N", "14000"))

if not hasattr(torch, "npu") or not torch.npu.is_available():
    print("NPU not available")
    sys.exit(3)

device = torch.device("npu:0")
torch.npu.set_device(device)
start_time = time.time()
x = torch.ones([n, n], dtype=torch.float32).to(device)
y = torch.ones([n, n], dtype=torch.float32).to(device)
for _ in range(iters):
    z = torch.add(x, y)
torch.npu.synchronize()
print("PASS")
print("--- %s seconds ---" % (time.time() - start_time))
PY
EOC
)

CUDA_PROBE_CMD="${CUDA_PROBE_CMD:-$CUDA_PROBE_CMD_DEFAULT}"
CANN_PROBE_CMD="${CANN_PROBE_CMD:-$CANN_PROBE_CMD_DEFAULT}"
CUDA_BENCH_CMD="${CUDA_BENCH_CMD:-$CUDA_BENCH_CMD_DEFAULT}"
CANN_BENCH_CMD="${CANN_BENCH_CMD:-$CANN_BENCH_CMD_DEFAULT}"

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

image_with_arch_tag() {
  local image="$1"
  local arch="$2"
  echo "${image}-${arch}"
}

ensure_local_buildx_builder() {
  docker buildx inspect nvshare-local-builder >/dev/null 2>&1 || \
    docker buildx create --name nvshare-local-builder --driver docker-container --use >/dev/null
  docker buildx use nvshare-local-builder >/dev/null 2>&1 || true
  docker buildx inspect --bootstrap >/dev/null
}

build_components_local_arm64() {
  local lib_arm64 scheduler_arm64 device_arm64
  lib_arm64=$(image_with_arch_tag "$LIB_IMAGE" "arm64")
  scheduler_arm64=$(image_with_arch_tag "$SCHEDULER_IMAGE" "arm64")
  device_arm64=$(image_with_arch_tag "$DEVICE_PLUGIN_IMAGE" "arm64")

  log_info "local build arm64: lib=${lib_arm64} scheduler=${scheduler_arm64} device=${device_arm64}"
  (
    cd "$PROJECT_ROOT"
    docker buildx build --platform linux/arm64 -f Dockerfile.libnvshare --build-arg BASE_IMAGE="${BASE_IMAGE}" -t "${lib_arm64}" --push .
    sleep 10
    docker buildx build --platform linux/arm64 -f Dockerfile.scheduler --build-arg BASE_IMAGE="${BASE_IMAGE}" -t "${scheduler_arm64}" --push .
    sleep 10
    docker buildx build --platform linux/arm64 -f Dockerfile.device_plugin --build-arg BASE_IMAGE="${BASE_IMAGE}" --build-arg GO_BUILDER_IMAGE="${GO_BUILDER_IMAGE_ARM64}" -t "${device_arm64}" --push .
  )
}

build_components_remote_amd64() {
  local remote_prefix="$1"
  local remote_builder_setup="$2"

  local lib_amd64 scheduler_amd64 device_amd64
  lib_amd64=$(image_with_arch_tag "$LIB_IMAGE" "amd64")
  scheduler_amd64=$(image_with_arch_tag "$SCHEDULER_IMAGE" "amd64")
  device_amd64=$(image_with_arch_tag "$DEVICE_PLUGIN_IMAGE" "amd64")

  log_info "remote build amd64: lib=${lib_amd64} scheduler=${scheduler_amd64} device=${device_amd64}"
  ssh -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
    "${remote_prefix} && ${remote_builder_setup} && \
     docker buildx build --platform 'linux/amd64' -f Dockerfile.libnvshare --build-arg BASE_IMAGE='${BASE_IMAGE}' -t '${lib_amd64}' --push . && \
     sleep 10 && \
     docker buildx build --platform 'linux/amd64' -f Dockerfile.scheduler --build-arg BASE_IMAGE='${BASE_IMAGE}' -t '${scheduler_amd64}' --push . && \
     sleep 10 && \
     docker buildx build --platform 'linux/amd64' -f Dockerfile.device_plugin --build-arg BASE_IMAGE='${BASE_IMAGE}' --build-arg GO_BUILDER_IMAGE='${GO_BUILDER_IMAGE_AMD64}' -t '${device_amd64}' --push ."
}

publish_component_multiarch_manifest() {
  local final_image="$1"
  local amd64_image="$2"
  local arm64_image="$3"
  local attempt=1
  local err_file
  err_file=$(mktemp)

  while [[ "$attempt" -le "$MANIFEST_PUSH_RETRIES" ]]; do
    # `buildx imagetools create` is tolerant when source refs are manifest or index.
    if docker buildx imagetools create --tag "$final_image" "$amd64_image" "$arm64_image" > /dev/null 2>"$err_file"; then
      if [[ "$MANIFEST_PUSH_COOLDOWN_SEC" -gt 0 ]]; then
        sleep "$MANIFEST_PUSH_COOLDOWN_SEC"
      fi
      rm -f "$err_file"
      return 0
    fi

    if grep -Eiq '429|too many requests|toomanyrequests' "$err_file"; then
      local wait_sec
      wait_sec=$((MANIFEST_PUSH_RETRY_BASE_SEC * attempt))
      log_warn "manifest push rate-limited for ${final_image}; retry ${attempt}/${MANIFEST_PUSH_RETRIES} after ${wait_sec}s"
      sleep "$wait_sec"
      attempt=$((attempt + 1))
      continue
    fi

    log_error "manifest push failed for ${final_image}"
    cat "$err_file" >&2
    rm -f "$err_file"
    return 1
  done

  log_error "manifest push failed after retries for ${final_image}"
  cat "$err_file" >&2
  rm -f "$err_file"
  return 1
}

publish_multiarch_manifests() {
  local lib_amd64 lib_arm64 scheduler_amd64 scheduler_arm64 device_amd64 device_arm64
  lib_amd64=$(image_with_arch_tag "$LIB_IMAGE" "amd64")
  lib_arm64=$(image_with_arch_tag "$LIB_IMAGE" "arm64")
  scheduler_amd64=$(image_with_arch_tag "$SCHEDULER_IMAGE" "amd64")
  scheduler_arm64=$(image_with_arch_tag "$SCHEDULER_IMAGE" "arm64")
  device_amd64=$(image_with_arch_tag "$DEVICE_PLUGIN_IMAGE" "amd64")
  device_arm64=$(image_with_arch_tag "$DEVICE_PLUGIN_IMAGE" "arm64")

  log_info "publish multi-arch manifests to canonical tags"
  publish_component_multiarch_manifest "$LIB_IMAGE" "$lib_amd64" "$lib_arm64"
  publish_component_multiarch_manifest "$SCHEDULER_IMAGE" "$scheduler_amd64" "$scheduler_arm64"
  publish_component_multiarch_manifest "$DEVICE_PLUGIN_IMAGE" "$device_amd64" "$device_arm64"
}

remote_build_and_push() {
  log_info "remote build target=${REMOTE_MAKE_TARGET} base_image=${BASE_IMAGE} go_builder_image=${GO_BUILDER_IMAGE} go_builder_arm64=${GO_BUILDER_IMAGE_ARM64} go_builder_amd64=${GO_BUILDER_IMAGE_AMD64} platforms=${BUILD_PLATFORMS}"
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
    if [[ "$SPLIT_ARCH_BUILD" == "1" ]]; then
      log_info "build strategy: split-arch (local arm64 + remote amd64 + local manifest merge)"
      ensure_local_buildx_builder
      build_components_local_arm64
      build_components_remote_amd64 "$remote_prefix" "$remote_builder_setup"
      publish_multiarch_manifests
    else
      ssh -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
        "${remote_prefix} && ${remote_builder_setup} && \
         docker buildx build --platform '${BUILD_PLATFORMS}' -f Dockerfile.libnvshare --build-arg BASE_IMAGE='${BASE_IMAGE}' -t '${LIB_IMAGE}' --push . && \
         docker buildx build --platform '${BUILD_PLATFORMS}' -f Dockerfile.scheduler --build-arg BASE_IMAGE='${BASE_IMAGE}' -t '${SCHEDULER_IMAGE}' --push . && \
         docker buildx build --platform '${BUILD_PLATFORMS}' -f Dockerfile.device_plugin --build-arg BASE_IMAGE='${BASE_IMAGE}' --build-arg GO_BUILDER_IMAGE='${GO_BUILDER_IMAGE}' -t '${DEVICE_PLUGIN_IMAGE}' --push ."
    fi
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
          set -eu
          LIB=/host-var-run-nvshare/libnvshare.so
          SRC=/libnvshare.so
          trap "umount -l \$LIB >/dev/null 2>&1 || true; rm -rf \$LIB >/dev/null 2>&1 || true; exit 0" TERM INT EXIT
          if grep -qs " \$LIB " /proc/mounts; then
            umount -l "\$LIB" >/dev/null 2>&1 || true
          fi
          if [ -d "\$LIB" ]; then
            rm -rf "\$LIB" || true
          fi
          rm -f "\$LIB" || true
          touch "\$LIB"
          mount --bind "\$SRC" "\$LIB"
          if [ ! -f "\$LIB" ]; then
            echo "nvshare-lib bind mount failed: \$LIB is not a regular file"
            ls -ld "\$LIB" || true
            exit 1
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
  local node_selector=""
  local tolerations=""
  local shell_bin="/bin/bash"
  local shell_opt="-lc"

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
    shell_opt="-c"
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
    - ${shell_opt}
    - |
${cmd_block}
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    resources:
      limits:
        nvshare.com/gpu: 1
${node_selector}
${tolerations}
EOF
}

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

extract_bench_ms() {
  local logfile="$1"
  local val
  val=$(rg -o 'BENCH_MS=[0-9]+([.][0-9]+)?' "$logfile" 2>/dev/null | tail -n1 | cut -d'=' -f2 || true)
  if [[ -z "${val}" ]]; then
    local sec
    sec=$(rg -o -- '--- [0-9]+([.][0-9]+)? seconds ---' "$logfile" 2>/dev/null | tail -n1 | sed -E 's/--- ([0-9]+([.][0-9]+)?) seconds ---/\1/' || true)
    if [[ "${sec:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      val=$(awk -v s="$sec" 'BEGIN { printf "%.2f", s * 1000.0 }')
    fi
  fi
  if [[ -z "${val}" ]]; then
    echo "NA"
  else
    echo "${val}"
  fi
}

prepare_cluster_stack() {
  local cluster="$1"
  local cluster_log_dir="$2"

  if [[ "$SKIP_SETUP" -eq 1 ]]; then
    log_info "[${cluster}] skip scheduler/device-plugin update (--skip-setup)"
    kube "$cluster" -n "$SYSTEM_NAMESPACE" get ds nvshare-scheduler >/dev/null
    kube "$cluster" -n "$SYSTEM_NAMESPACE" get ds nvshare-device-plugin >/dev/null
    kube "$cluster" -n "$SYSTEM_NAMESPACE" rollout status ds/nvshare-scheduler --timeout=240s
    kube "$cluster" -n "$SYSTEM_NAMESPACE" rollout status ds/nvshare-device-plugin --timeout=240s
    return 0
  fi

  local scheduler_manifest="${cluster_log_dir}/scheduler.yaml"
  local device_manifest="${cluster_log_dir}/device-plugin.yaml"

  log_info "[${cluster}] render manifests"
  render_scheduler_manifest "$cluster" "$scheduler_manifest"
  render_device_plugin_manifest "$cluster" "$device_manifest"

  log_info "[${cluster}] deploy scheduler and device-plugin"
  deploy_stack "$cluster" "$scheduler_manifest" "$device_manifest"
}

render_perf_pod_manifest() {
  local cluster="$1"
  local mode="$2"
  local outfile="$3"
  local pod_name="$4"
  local round="$5"

  local image=""
  local bench_cmd=""
  local shell_bin="/bin/bash"
  local shell_opt="-lc"
  local resource_limits=""
  local node_selector=""
  local tolerations=""
  local extra_env=""
  local command_section=""

  if [[ "$cluster" == "cuda" ]]; then
    image="$CUDA_BENCH_IMAGE"
    bench_cmd="$CUDA_BENCH_CMD"
    if [[ -n "$bench_cmd" ]]; then
      local cmd_block_cuda
      cmd_block_cuda="$(printf '%s\n' "$bench_cmd" | sed 's/^/      /')"
      command_section=$(cat <<EOF
    command:
    - ${shell_bin}
    - ${shell_opt}
    - |
${cmd_block_cuda}
EOF
)
      extra_env=$(cat <<EOF
    - name: BENCH_ITERS
      value: "${CUDA_BENCH_ITERS}"
    - name: BENCH_MATMUL_SIZE
      value: "${CUDA_BENCH_MATMUL_SIZE}"
EOF
)
    fi
    if [[ "$mode" == "native" ]]; then
      resource_limits="        ${CUDA_DEVICE_RESOURCE_KEY}: 1"
    else
      resource_limits="        nvshare.com/gpu: 1"
    fi
    tolerations=$(cat <<'EOB'
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
EOB
)
  else
    image="$CANN_BENCH_IMAGE"
    bench_cmd="$CANN_BENCH_CMD"
    shell_bin="/bin/sh"
    shell_opt="-c"
    local cmd_block_cann
    cmd_block_cann="$(printf '%s\n' "$bench_cmd" | sed 's/^/      /')"
    command_section=$(cat <<EOF
    command:
    - ${shell_bin}
    - ${shell_opt}
    - |
${cmd_block_cann}
EOF
)
    extra_env=$(cat <<EOF
    - name: CANN_BENCH_ITERS
      value: "${CANN_BENCH_ITERS}"
    - name: CANN_BENCH_N
      value: "${CANN_BENCH_N}"
EOF
)
    if [[ "$mode" == "native" ]]; then
      resource_limits="        ${CANN_WORKLOAD_RESOURCE_KEY}: ${CANN_WORKLOAD_RESOURCE_COUNT}"
    else
      resource_limits="        nvshare.com/gpu: 1"
    fi
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

  cat > "$outfile" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${WORKLOAD_NAMESPACE}
  labels:
    app: nvshare-remote-perf
    bench-cluster: ${cluster}
    bench-mode: ${mode}
    bench-round: "${round}"
spec:
  restartPolicy: Never
  containers:
  - name: bench
    image: ${image}
    imagePullPolicy: IfNotPresent
${command_section}
    env:
    - name: NVSHARE_DEBUG
      value: "1"
${extra_env}
    resources:
      limits:
${resource_limits}
${node_selector}
${tolerations}
EOF
}

wait_for_pod_phase() {
  local cluster="$1"
  local pod_name="$2"
  local target_phase="$3"
  local timeout_sec="$4"
  local start_ts
  start_ts=$(date +%s)

  while true; do
    local phase
    phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [[ "$phase" == "$target_phase" ]]; then
      return 0
    fi
    if [[ "$phase" == "Failed" ]] || [[ "$phase" == "Succeeded" ]]; then
      return 1
    fi

    local now
    now=$(date +%s)
    if (( now - start_ts > timeout_sec )); then
      log_warn "pod ${pod_name} wait for phase=${target_phase} timeout after ${timeout_sec}s (phase=${phase})"
      return 2
    fi
    sleep 3
  done
}

wait_for_log_pattern() {
  local cluster="$1"
  local pod_name="$2"
  local pattern="$3"
  local timeout_sec="$4"
  local logfile="$5"
  local start_ts
  start_ts=$(date +%s)

  while true; do
    kube "$cluster" -n "$WORKLOAD_NAMESPACE" logs "$pod_name" > "$logfile" 2>&1 || true
    if grep -q "$pattern" "$logfile"; then
      return 0
    fi

    local phase
    phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [[ "$phase" == "Failed" ]] || [[ "$phase" == "Succeeded" ]]; then
      return 1
    fi

    local now
    now=$(date +%s)
    if (( now - start_ts > timeout_sec )); then
      return 2
    fi
    sleep 3
  done
}

fetch_cluster_metrics_snapshot() {
  local cluster="$1"
  local outfile="$2"
  local sched_pod
  local pf_log="${outfile}.port-forward.log"
  local port
  port=$((19400 + RANDOM % 1000))

  sched_pod=$(kube "$cluster" -n "$SYSTEM_NAMESPACE" get pod -l name=nvshare-scheduler -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$sched_pod" ]]; then
    log_warn "[${cluster}] scheduler pod not found for metrics snapshot"
    return 1
  fi

  : > "$outfile"
  kube "$cluster" -n "$SYSTEM_NAMESPACE" port-forward "pod/${sched_pod}" "${port}:9402" > "$pf_log" 2>&1 &
  local pf_pid=$!
  sleep 2
  curl -s "http://127.0.0.1:${port}/metrics" > "$outfile" 2>/dev/null || true
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true

  if ! grep -q '^nvshare_' "$outfile"; then
    kube "$cluster" get --raw "/api/v1/namespaces/${SYSTEM_NAMESPACE}/pods/${sched_pod}:9402/proxy/metrics" > "$outfile" 2>>"$pf_log" || true
  fi

  grep -q '^nvshare_' "$outfile"
}

metric_value_for_pod() {
  local metric="$1"
  local pod_name="$2"
  local metric_file="$3"

  awk -v m="$metric" -v p="$pod_name" '
    $0 ~ ("^" m "{") && $0 ~ ("pod=\"" p "\"") {v=$NF}
    END {if (v != "") print v}
  ' "$metric_file"
}

extract_total_iters() {
  local logfile="$1"
  rg -o 'TOTAL_ITERS=[0-9]+' "$logfile" 2>/dev/null | tail -n1 | cut -d'=' -f2 || true
}

extract_elapsed_sec() {
  local logfile="$1"
  rg -o 'ELAPSED_SEC=[0-9]+(\.[0-9]+)?' "$logfile" 2>/dev/null | tail -n1 | cut -d'=' -f2 || true
}

capture_scheduler_case_log() {
  local cluster="$1"
  local outfile="$2"
  kube "$cluster" -n "$SYSTEM_NAMESPACE" logs -l name=nvshare-scheduler --since=40m --timestamps > "$outfile" 2>&1 || true
}

cleanup_quota_pods() {
  local cluster="$1"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod -l app=nvshare-remote-quota --ignore-not-found=true --wait=true || true
}

RUN_QUOTA_POD_LAST_WAIT_RC="NA"
RUN_QUOTA_POD_LAST_PHASE="NA"
RUN_QUOTA_POD_LAST_ATTEMPT="NA"

run_quota_pod_with_retry() {
  local cluster="$1"
  local pod_name="$2"
  local manifest="$3"
  local timeout_sec="$4"
  local log_file="$5"
  local desc_file="$6"
  local max_attempts="${7:-1}"
  local retry_backoff_sec="${8:-0}"

  local attempt=1
  while (( attempt <= max_attempts )); do
    kube "$cluster" apply -f "$manifest"

    local wait_rc=0
    wait_for_pod_terminal "$cluster" "$pod_name" "$timeout_sec" || wait_rc=$?

    local attempt_log="${log_file}.attempt${attempt}"
    local attempt_desc="${desc_file}.attempt${attempt}"
    kube "$cluster" -n "$WORKLOAD_NAMESPACE" logs "$pod_name" > "$attempt_log" 2>&1 || true
    kube "$cluster" -n "$WORKLOAD_NAMESPACE" describe pod "$pod_name" > "$attempt_desc" 2>&1 || true

    cp -f "$attempt_log" "$log_file" || true
    cp -f "$attempt_desc" "$desc_file" || true

    local phase
    phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    RUN_QUOTA_POD_LAST_WAIT_RC="$wait_rc"
    RUN_QUOTA_POD_LAST_PHASE="$phase"
    RUN_QUOTA_POD_LAST_ATTEMPT="$attempt"

    if [[ "$wait_rc" -eq 0 && "$phase" == "Succeeded" ]]; then
      return 0
    fi

    if (( attempt < max_attempts )) && {
      grep -q "NPU not available" "$attempt_log" ||
      grep -q "rtGetDeviceCount: Error code=507000" "$attempt_log" ||
      grep -q "drvRet=87" "$attempt_log" ||
      grep -q "FailedCreatePodSandBox" "$attempt_desc";
    }; then
      log_warn "[${cluster}] ${pod_name} transient NPU/sandbox issue, retrying (${attempt}/${max_attempts})"
      kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=true || true
      if [[ "$retry_backoff_sec" -gt 0 ]]; then
        sleep "$retry_backoff_sec"
      fi
      attempt=$((attempt + 1))
      continue
    fi

    return 1
  done

  return 1
}

render_cann_quota_pod_manifest() {
  local outfile="$1"
  local pod_name="$2"
  local core_limit="$3"
  local memory_limit="$4"
  local command_text="$5"

  local annotation_block
  local command_block
  annotation_block="    nvshare.com/gpu-core-limit: \"${core_limit}\""
  if [[ -n "$memory_limit" ]]; then
    annotation_block="${annotation_block}
    nvshare.com/gpu-memory-limit: \"${memory_limit}\""
  fi

  command_block="$(printf '%s\n' "$command_text" | sed 's/^/      /')"

  cat > "$outfile" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${WORKLOAD_NAMESPACE}
  labels:
    app: nvshare-remote-quota
    quota-cluster: cann
  annotations:
${annotation_block}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/arch: arm64
    accelerator: huawei-Ascend910
  tolerations:
  - key: ${CANN_WORKLOAD_RESOURCE_KEY}
    operator: Exists
    effect: NoSchedule
  containers:
  - name: quota
    image: ${CANN_BENCH_IMAGE}
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - |
${command_block}
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    - name: CANN_QUOTA_MEM_N
      value: "${CANN_QUOTA_MEM_N}"
    - name: CANN_QUOTA_MEM_STATIC_SETTLE_SEC
      value: "${CANN_QUOTA_MEM_STATIC_SETTLE_SEC}"
    - name: CANN_QUOTA_CORE_N
      value: "${CANN_QUOTA_CORE_N}"
    - name: CANN_QUOTA_CORE_DURATION_SEC
      value: "${CANN_QUOTA_CORE_DURATION_SEC}"
    - name: CANN_QUOTA_CORE_STATIC_ITERS
      value: "${CANN_QUOTA_CORE_STATIC_ITERS}"
    - name: CANN_QUOTA_CORE_STATIC_WARMUP_ITERS
      value: "${CANN_QUOTA_CORE_STATIC_WARMUP_ITERS}"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF
}

run_cann_quota_case_mem_static() {
  local cluster="$1"
  local quota_dir="$2"
  local run_summary_file="$3"
  local case_id="cann-quota-mem-static"
  local case_dir="${quota_dir}/${case_id}"
  local pod_name="nvshare-quota-cann-mem-static"
  local manifest="${case_dir}/${pod_name}.yaml"
  local pod_log="${case_dir}/${pod_name}.log"
  local pod_desc="${case_dir}/${pod_name}.describe.txt"
  local sched_log="${case_dir}/scheduler.log"
  local status="PASS"
  local summary="ok"
  mkdir -p "$case_dir"

  local quota_cmd
  quota_cmd=$(cat <<'EOC'
python3 -u - <<'PY'
import os
import sys
import time
import torch

try:
    import torch_npu  # noqa: F401
except Exception as e:
    print(f"torch_npu import failed: {e}")
    sys.exit(2)

if not hasattr(torch, "npu") or not torch.npu.is_available():
    print("NPU not available")
    sys.exit(3)

n = int(os.getenv("CANN_QUOTA_MEM_N", "14000"))
settle_sec = int(os.getenv("CANN_QUOTA_MEM_STATIC_SETTLE_SEC", "20"))
dev = torch.device("npu:0")
torch.npu.set_device(dev)

try:
    a = torch.ones([n, n], dtype=torch.float32).to(dev)
    torch.npu.synchronize()
    print("ALLOC_OK_A", flush=True)
    print(f"WAIT_SETTLE_SEC={settle_sec}", flush=True)
    time.sleep(settle_sec)
    b = torch.ones([n, n], dtype=torch.float32).to(dev)
    torch.npu.synchronize()
    print("ALLOC_OK_B_UNEXPECTED", flush=True)
    print("FAIL_NO_OOM", flush=True)
    sys.exit(10)
except Exception as e:
    print("EXPECTED_OOM", flush=True)
    print(f"OOM_MSG={e}", flush=True)
    print("PASS", flush=True)
PY
EOC
)

  cleanup_quota_pods "$cluster"
  render_cann_quota_pod_manifest "$manifest" "$pod_name" "100" "$CANN_QUOTA_MEM_STATIC_LIMIT" "$quota_cmd"
  kube "$cluster" apply -f "$manifest"

  local wait_rc=0
  wait_for_pod_terminal "$cluster" "$pod_name" "$QUOTA_TIMEOUT_SEC" || wait_rc=$?
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" logs "$pod_name" > "$pod_log" 2>&1 || true
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" describe pod "$pod_name" > "$pod_desc" 2>&1 || true
  capture_scheduler_case_log "$cluster" "$sched_log"

  local phase
  phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

  if [[ "$wait_rc" -ne 0 || "$phase" != "Succeeded" ]]; then
    status="FAIL"
    summary="phase=${phase},wait_rc=${wait_rc}"
  elif ! grep -q "PASS" "$pod_log" || ! grep -q "EXPECTED_OOM" "$pod_log" || grep -q "FAIL_NO_OOM" "$pod_log"; then
    status="FAIL"
    summary="expected OOM behavior not observed"
  else
    summary="limit=${CANN_QUOTA_MEM_STATIC_LIMIT}, settle_sec=${CANN_QUOTA_MEM_STATIC_SETTLE_SEC}, expected OOM observed"
  fi

  printf "%s\t%s\t%s\n" "$case_id" "$status" "$summary" >> "$run_summary_file"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=true || true
  [[ "$status" == "PASS" ]]
}

run_cann_quota_case_mem_dynamic() {
  local cluster="$1"
  local quota_dir="$2"
  local run_summary_file="$3"
  local case_id="cann-quota-mem-dynamic"
  local case_dir="${quota_dir}/${case_id}"
  local pod_name="nvshare-quota-cann-mem-dynamic"
  local manifest="${case_dir}/${pod_name}.yaml"
  local pod_log="${case_dir}/${pod_name}.log"
  local pod_desc="${case_dir}/${pod_name}.describe.txt"
  local sched_log="${case_dir}/scheduler.log"
  local metrics_before="${case_dir}/metrics-before.txt"
  local metrics_after="${case_dir}/metrics-after.txt"
  local status="PASS"
  local summary="ok"
  mkdir -p "$case_dir"

  local quota_cmd
  quota_cmd=$(cat <<'EOC'
python3 -u - <<'PY'
import os
import sys
import time
import torch

try:
    import torch_npu  # noqa: F401
except Exception as e:
    print(f"torch_npu import failed: {e}")
    sys.exit(2)

if not hasattr(torch, "npu") or not torch.npu.is_available():
    print("NPU not available")
    sys.exit(3)

n = int(os.getenv("CANN_QUOTA_MEM_N", "14000"))
dev = torch.device("npu:0")
torch.npu.set_device(dev)

def alloc(tag):
    try:
        t = torch.ones([n, n], dtype=torch.float32).to(dev)
        torch.npu.synchronize()
        print(f"ALLOC_OK_{tag}", flush=True)
        return t
    except Exception as e:
        print(f"ALLOC_FAIL_{tag}", flush=True)
        print(f"ALLOC_ERR_{tag}={e}", flush=True)
        return None

a = alloc("A")
if a is None:
    print("FAIL_A", flush=True)
    sys.exit(10)

time.sleep(8)
b = alloc("B")
if b is not None:
    print("FAIL_B_SHOULD_FAIL", flush=True)
    sys.exit(11)

print("WAITING_FOR_LIMIT_UPDATE", flush=True)
time.sleep(45)
c = alloc("C")
if c is None:
    print("FAIL_C_SHOULD_PASS_AFTER_UPDATE", flush=True)
    sys.exit(12)

print("PASS", flush=True)
PY
EOC
)

  cleanup_quota_pods "$cluster"
  render_cann_quota_pod_manifest "$manifest" "$pod_name" "100" "$CANN_QUOTA_MEM_DYNAMIC_START_LIMIT" "$quota_cmd"
  kube "$cluster" apply -f "$manifest"

  if ! wait_for_pod_phase "$cluster" "$pod_name" "Running" "$QUOTA_OBSERVE_TIMEOUT_SEC"; then
    status="FAIL"
    summary="pod not running in time"
  fi

  local before_quota="NA"
  if [[ "$status" == "PASS" ]]; then
    fetch_cluster_metrics_snapshot "$cluster" "$metrics_before" || true
    before_quota=$(metric_value_for_pod "nvshare_client_memory_quota_bytes" "$pod_name" "$metrics_before")
    before_quota=${before_quota:-0}
  fi

  if [[ "$status" == "PASS" ]]; then
    if ! wait_for_log_pattern "$cluster" "$pod_name" "WAITING_FOR_LIMIT_UPDATE" "$QUOTA_OBSERVE_TIMEOUT_SEC" "$pod_log"; then
      status="FAIL"
      summary="did not observe WAITING_FOR_LIMIT_UPDATE before timeout"
    fi
  fi

  if [[ "$status" == "PASS" ]]; then
    kube "$cluster" -n "$WORKLOAD_NAMESPACE" annotate pod "$pod_name" "nvshare.com/gpu-memory-limit=${CANN_QUOTA_MEM_DYNAMIC_TARGET_LIMIT}" --overwrite
  fi

  local observed_metric_update=0
  local metrics_after_val="NA"
  if [[ "$status" == "PASS" ]]; then
    local metric_poll_rounds
    metric_poll_rounds=$((QUOTA_OBSERVE_TIMEOUT_SEC / 5))
    if [[ "$metric_poll_rounds" -lt 1 ]]; then
      metric_poll_rounds=1
    fi
    local i
    for i in $(seq 1 "$metric_poll_rounds"); do
      fetch_cluster_metrics_snapshot "$cluster" "$metrics_after" || true
      metrics_after_val=$(metric_value_for_pod "nvshare_client_memory_quota_bytes" "$pod_name" "$metrics_after")
      if [[ -n "${metrics_after_val:-}" ]] && awk -v n="$metrics_after_val" -v o="$before_quota" 'BEGIN{exit !(n>o)}'; then
        observed_metric_update=1
        break
      fi
      sleep 5
    done
  fi

  local wait_rc=0
  wait_for_pod_terminal "$cluster" "$pod_name" "$QUOTA_TIMEOUT_SEC" || wait_rc=$?
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" logs "$pod_name" > "$pod_log" 2>&1 || true
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" describe pod "$pod_name" > "$pod_desc" 2>&1 || true
  capture_scheduler_case_log "$cluster" "$sched_log"

  local phase
  phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [[ "$status" == "PASS" ]]; then
    if [[ "$wait_rc" -ne 0 || "$phase" != "Succeeded" ]]; then
      status="FAIL"
      summary="phase=${phase},wait_rc=${wait_rc}"
    elif ! grep -q "PASS" "$pod_log" || ! grep -q "ALLOC_FAIL_B" "$pod_log" || ! grep -q "ALLOC_OK_C" "$pod_log"; then
      status="FAIL"
      summary="dynamic memory behavior check failed"
    elif [[ "$observed_metric_update" -ne 1 ]]; then
      status="FAIL"
      summary="memory quota metric did not increase after annotation"
    else
      summary="memory quota updated ${CANN_QUOTA_MEM_DYNAMIC_START_LIMIT}->${CANN_QUOTA_MEM_DYNAMIC_TARGET_LIMIT}, metric_before=${before_quota}, metric_after=${metrics_after_val}"
    fi
  fi

  printf "%s\t%s\t%s\n" "$case_id" "$status" "$summary" >> "$run_summary_file"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=true || true
  [[ "$status" == "PASS" ]]
}

run_cann_quota_case_core_static() {
  local cluster="$1"
  local quota_dir="$2"
  local run_summary_file="$3"
  local case_id="cann-quota-core-static"
  local case_dir="${quota_dir}/${case_id}"
  local pod_base="nvshare-quota-cann-core-base"
  local pod_limited="nvshare-quota-cann-core-limit"
  local manifest_base="${case_dir}/${pod_base}.yaml"
  local manifest_limited="${case_dir}/${pod_limited}.yaml"
  local log_base="${case_dir}/${pod_base}.log"
  local log_limited="${case_dir}/${pod_limited}.log"
  local desc_base="${case_dir}/${pod_base}.describe.txt"
  local desc_limited="${case_dir}/${pod_limited}.describe.txt"
  local status="PASS"
  local summary="ok"
  local baseline_limit=100
  local limited_limit="$CANN_QUOTA_CORE_STATIC_LOW"
  mkdir -p "$case_dir"

  local quota_cmd
  quota_cmd=$(cat <<'EOC'
python3 -u - <<'PY'
import os
import sys
import time
import torch

try:
    import torch_npu  # noqa: F401
except Exception as e:
    print(f"torch_npu import failed: {e}")
    sys.exit(2)

if not hasattr(torch, "npu") or not torch.npu.is_available():
    print("NPU not available")
    sys.exit(3)

n = int(os.getenv("CANN_QUOTA_CORE_N", "4096"))
iters = int(os.getenv("CANN_QUOTA_CORE_STATIC_ITERS", "5000"))
warmup = int(os.getenv("CANN_QUOTA_CORE_STATIC_WARMUP_ITERS", "20"))
dev = torch.device("npu:0")
torch.npu.set_device(dev)
x = torch.randn([n, n], dtype=torch.float16, device=dev)
y = torch.randn([n, n], dtype=torch.float16, device=dev)
for _ in range(warmup):
    z = torch.matmul(x, y)
torch.npu.synchronize()
t0 = time.time()
for i in range(iters):
    z = torch.matmul(x, y)
    if (i + 1) % 100 == 0:
        torch.npu.synchronize()
torch.npu.synchronize()
elapsed = time.time() - t0
print(f"ELAPSED_SEC={elapsed:.6f}", flush=True)
print(f"TOTAL_ITERS={iters}", flush=True)
print("PASS", flush=True)
PY
EOC
)

  cleanup_quota_pods "$cluster"
  render_cann_quota_pod_manifest "$manifest_base" "$pod_base" "$baseline_limit" "" "$quota_cmd"
  render_cann_quota_pod_manifest "$manifest_limited" "$pod_limited" "$limited_limit" "" "$quota_cmd"

  local run_base_rc=0
  local run_limited_rc=0
  local wait_base="NA"
  local wait_limited="NA"
  local phase_base="NotStarted"
  local phase_limited="NotStarted"
  local attempt_base="NA"
  local attempt_limited="NA"

  run_quota_pod_with_retry "$cluster" "$pod_base" "$manifest_base" "$QUOTA_TIMEOUT_SEC" "$log_base" "$desc_base" "$CANN_QUOTA_CORE_STATIC_RETRIES" "$CANN_QUOTA_CORE_RETRY_BACKOFF_SEC" || run_base_rc=$?
  wait_base="$RUN_QUOTA_POD_LAST_WAIT_RC"
  phase_base="$RUN_QUOTA_POD_LAST_PHASE"
  attempt_base="$RUN_QUOTA_POD_LAST_ATTEMPT"

  if [[ "$run_base_rc" -eq 0 ]]; then
    run_quota_pod_with_retry "$cluster" "$pod_limited" "$manifest_limited" "$QUOTA_TIMEOUT_SEC" "$log_limited" "$desc_limited" "$CANN_QUOTA_CORE_STATIC_RETRIES" "$CANN_QUOTA_CORE_RETRY_BACKOFF_SEC" || run_limited_rc=$?
    wait_limited="$RUN_QUOTA_POD_LAST_WAIT_RC"
    phase_limited="$RUN_QUOTA_POD_LAST_PHASE"
    attempt_limited="$RUN_QUOTA_POD_LAST_ATTEMPT"
  else
    run_limited_rc=1
    phase_limited="Skipped"
    wait_limited="Skipped"
  fi

  capture_scheduler_case_log "$cluster" "${case_dir}/scheduler.log"

  local base_elapsed limited_elapsed ratio
  base_elapsed=$(extract_elapsed_sec "$log_base")
  limited_elapsed=$(extract_elapsed_sec "$log_limited")
  ratio="NA"
  if [[ -n "${base_elapsed:-}" ]] && [[ -n "${limited_elapsed:-}" ]]; then
    if awk -v b="$base_elapsed" 'BEGIN{exit !(b>0)}'; then
      ratio=$(awk -v b="$base_elapsed" -v l="$limited_elapsed" 'BEGIN {printf "%.4f", l/b}')
    fi
  fi

  local base_desc_limit_seen=0
  local limited_desc_limit_seen=0
  local base_runtime_limit_seen=0
  local limited_runtime_limit_seen=0
  grep -Fq "nvshare.com/gpu-core-limit: ${baseline_limit}" "$desc_base" && base_desc_limit_seen=1 || true
  grep -Fq "nvshare.com/gpu-core-limit: ${limited_limit}" "$desc_limited" && limited_desc_limit_seen=1 || true
  (grep -Fq "Core limit = ${baseline_limit}%" "$log_base" || grep -Fq "UPDATE_CORE_LIMIT: new core limit = ${baseline_limit}%" "$log_base") && base_runtime_limit_seen=1 || true
  (grep -Fq "Core limit = ${limited_limit}%" "$log_limited" || grep -Fq "UPDATE_CORE_LIMIT: new core limit = ${limited_limit}%" "$log_limited") && limited_runtime_limit_seen=1 || true

  if [[ "$run_base_rc" -ne 0 || "$run_limited_rc" -ne 0 || "$phase_base" != "Succeeded" || "$phase_limited" != "Succeeded" ]]; then
    status="FAIL"
    summary="phase_base=${phase_base},phase_limited=${phase_limited},wait_base=${wait_base},wait_limited=${wait_limited},attempt_base=${attempt_base},attempt_limited=${attempt_limited}"
  elif ! grep -q "PASS" "$log_base" || ! grep -q "PASS" "$log_limited"; then
    status="FAIL"
    summary="PASS marker missing in core static logs"
  elif [[ "$base_desc_limit_seen" -ne 1 || "$limited_desc_limit_seen" -ne 1 ]]; then
    status="FAIL"
    summary="pod annotation core-limit missing in describe output"
  elif [[ "$base_runtime_limit_seen" -ne 1 || "$limited_runtime_limit_seen" -ne 1 ]]; then
    status="FAIL"
    summary="runtime core limit banner missing in pod logs"
  elif [[ "$ratio" == "NA" ]]; then
    status="FAIL"
    summary="unable to extract ELAPSED_SEC from logs"
  elif ! awk -v r="$ratio" -v th="$CANN_QUOTA_CORE_GAIN_THRESHOLD" 'BEGIN{exit !(r>=th)}'; then
    status="FAIL"
    summary="core quota slowdown insufficient: ratio=${ratio}, threshold=${CANN_QUOTA_CORE_GAIN_THRESHOLD}, base=${base_elapsed}, limited=${limited_elapsed}, limit=${limited_limit}"
  else
    summary="base=${base_elapsed}s, limited=${limited_elapsed}s, ratio=${ratio}, threshold=${CANN_QUOTA_CORE_GAIN_THRESHOLD}, limit_base=${baseline_limit},limit_limited=${limited_limit}, attempt_base=${attempt_base},attempt_limited=${attempt_limited}"
  fi

  printf "%s\t%s\t%s\n" "$case_id" "$status" "$summary" >> "$run_summary_file"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_base" "$pod_limited" --ignore-not-found=true --wait=true || true
  [[ "$status" == "PASS" ]]
}

run_cann_quota_case_core_dynamic() {
  local cluster="$1"
  local quota_dir="$2"
  local run_summary_file="$3"
  local case_id="cann-quota-core-dynamic"
  local case_dir="${quota_dir}/${case_id}"
  local pod_name="nvshare-quota-cann-core-dynamic"
  local manifest="${case_dir}/${pod_name}.yaml"
  local pod_log="${case_dir}/${pod_name}.log"
  local pod_desc="${case_dir}/${pod_name}.describe.txt"
  local sched_log="${case_dir}/scheduler.log"
  local metrics_file="${case_dir}/metrics.txt"
  local status="PASS"
  local summary="ok"
  mkdir -p "$case_dir"

  local quota_cmd
  quota_cmd=$(cat <<'EOC'
python3 -u - <<'PY'
import os
import sys
import time
import torch

try:
    import torch_npu  # noqa: F401
except Exception as e:
    print(f"torch_npu import failed: {e}")
    sys.exit(2)

if not hasattr(torch, "npu") or not torch.npu.is_available():
    print("NPU not available")
    sys.exit(3)

n = int(os.getenv("CANN_QUOTA_CORE_N", "4096"))
duration = int(os.getenv("CANN_QUOTA_CORE_DURATION_SEC", "90"))
dev = torch.device("npu:0")
torch.npu.set_device(dev)
x = torch.ones([n, n], dtype=torch.float32).to(dev)
y = torch.ones([n, n], dtype=torch.float32).to(dev)
t0 = time.time()
last = t0
it = 0
while True:
    z = torch.add(x, y)
    it += 1
    now = time.time()
    if now - last >= 5:
        rate = it / max(now - t0, 1e-6)
        print(f"STAT elapsed={now-t0:.1f}s it={it} rate={rate:.2f}", flush=True)
        last = now
    if now - t0 >= duration:
        break
torch.npu.synchronize()
print(f"TOTAL_ITERS={it}", flush=True)
print("PASS", flush=True)
PY
EOC
)

  cleanup_quota_pods "$cluster"
  render_cann_quota_pod_manifest "$manifest" "$pod_name" "$CANN_QUOTA_CORE_DYNAMIC_START" "" "$quota_cmd"
  kube "$cluster" apply -f "$manifest"

  if ! wait_for_pod_phase "$cluster" "$pod_name" "Running" "$QUOTA_OBSERVE_TIMEOUT_SEC"; then
    status="FAIL"
    summary="pod not running in time"
  fi

  local start_metric="NA"
  if [[ "$status" == "PASS" ]]; then
    local metric_poll_rounds
    metric_poll_rounds=$((QUOTA_OBSERVE_TIMEOUT_SEC / 5))
    if [[ "$metric_poll_rounds" -lt 1 ]]; then
      metric_poll_rounds=1
    fi
    local i
    for i in $(seq 1 "$metric_poll_rounds"); do
      fetch_cluster_metrics_snapshot "$cluster" "$metrics_file" || true
      start_metric=$(metric_value_for_pod "nvshare_client_core_quota_config_percent" "$pod_name" "$metrics_file")
      if [[ -n "${start_metric:-}" ]] && awk -v m="$start_metric" -v s="$CANN_QUOTA_CORE_DYNAMIC_START" 'BEGIN{exit !(m>=s-1 && m<=s+1)}'; then
        break
      fi
      sleep 5
    done
    if [[ -z "${start_metric:-}" ]] || ! awk -v m="${start_metric:-0}" -v s="$CANN_QUOTA_CORE_DYNAMIC_START" 'BEGIN{exit !(m>=s-1 && m<=s+1)}'; then
      status="FAIL"
      summary="failed to observe initial core quota metric=${start_metric}"
    fi
  fi

  if [[ "$status" == "PASS" ]]; then
    kube "$cluster" -n "$WORKLOAD_NAMESPACE" annotate pod "$pod_name" "nvshare.com/gpu-core-limit=${CANN_QUOTA_CORE_DYNAMIC_TARGET}" --overwrite
  fi

  local observed_target=0
  local target_metric="NA"
  if [[ "$status" == "PASS" ]]; then
    local metric_poll_rounds
    metric_poll_rounds=$((QUOTA_OBSERVE_TIMEOUT_SEC / 5))
    if [[ "$metric_poll_rounds" -lt 1 ]]; then
      metric_poll_rounds=1
    fi
    local i
    for i in $(seq 1 "$metric_poll_rounds"); do
      fetch_cluster_metrics_snapshot "$cluster" "$metrics_file" || true
      target_metric=$(metric_value_for_pod "nvshare_client_core_quota_config_percent" "$pod_name" "$metrics_file")
      if [[ -n "${target_metric:-}" ]] && awk -v m="$target_metric" -v t="$CANN_QUOTA_CORE_DYNAMIC_TARGET" 'BEGIN{exit !(m>=t-1)}'; then
        observed_target=1
        break
      fi
      sleep 5
    done
  fi

  local wait_rc=0
  wait_for_pod_terminal "$cluster" "$pod_name" "$QUOTA_TIMEOUT_SEC" || wait_rc=$?
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" logs "$pod_name" > "$pod_log" 2>&1 || true
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" describe pod "$pod_name" > "$pod_desc" 2>&1 || true
  capture_scheduler_case_log "$cluster" "$sched_log"

  local phase
  phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [[ "$status" == "PASS" ]]; then
    if [[ "$wait_rc" -ne 0 || "$phase" != "Succeeded" ]]; then
      status="FAIL"
      summary="phase=${phase},wait_rc=${wait_rc}"
    elif ! grep -q "PASS" "$pod_log"; then
      status="FAIL"
      summary="PASS marker missing in core dynamic log"
    elif [[ "$observed_target" -ne 1 ]]; then
      status="FAIL"
      summary="core quota metric not updated to target"
    else
      summary="core quota metric ${start_metric}->${target_metric}, target=${CANN_QUOTA_CORE_DYNAMIC_TARGET}"
    fi
  fi

  printf "%s\t%s\t%s\n" "$case_id" "$status" "$summary" >> "$run_summary_file"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=true || true
  [[ "$status" == "PASS" ]]
}

run_cluster_cann_quota() {
  local cluster="$1"
  local need_prepare="${2:-0}"
  local run_summary_file="${3:-$RUN_SUMMARY}"
  local cluster_log_dir="${LOG_ROOT}/${cluster}"
  local quota_dir="${cluster_log_dir}/quota"
  local rc=0
  mkdir -p "$quota_dir"

  if [[ "$cluster" != "cann" ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-quota" "SKIP" "quota suite is only implemented for cann cluster" >> "$run_summary_file"
    return 0
  fi

  if [[ "$need_prepare" -eq 1 ]]; then
    prepare_cluster_stack "$cluster" "$cluster_log_dir"
  fi

  cleanup_quota_pods "$cluster"

  log_info "[${cluster}][quota] case: mem-static"
  if ! run_cann_quota_case_mem_static "$cluster" "$quota_dir" "$run_summary_file"; then
    rc=1
  fi

  log_info "[${cluster}][quota] case: mem-dynamic"
  if ! run_cann_quota_case_mem_dynamic "$cluster" "$quota_dir" "$run_summary_file"; then
    rc=1
  fi

  log_info "[${cluster}][quota] case: core-static"
  if ! run_cann_quota_case_core_static "$cluster" "$quota_dir" "$run_summary_file"; then
    rc=1
  fi

  log_info "[${cluster}][quota] case: core-dynamic"
  if ! run_cann_quota_case_core_dynamic "$cluster" "$quota_dir" "$run_summary_file"; then
    rc=1
  fi

  cleanup_quota_pods "$cluster"

  if [[ "$rc" -eq 0 ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-quota" "PASS" "all cann quota cases passed" >> "$run_summary_file"
    log_info "[${cluster}][quota] PASS"
  else
    printf "%s\t%s\t%s\n" "${cluster}-quota" "FAIL" "one or more cann quota cases failed" >> "$run_summary_file"
    log_error "[${cluster}][quota] FAIL"
  fi

  return "$rc"
}

summarize_perf_results() {
  local cluster="$1"
  local results_tsv="$2"
  local summary_tsv="$3"
  local compare_tsv="$4"

  awk -F'\t' -v cluster="$cluster" '
    BEGIN {
      OFS="\t";
      print "cluster\tmode\tpass_rounds\tavg_wall_ms\tavg_bench_ms";
    }
    NR > 1 && $8 == "PASS" {
      mode = $2;
      cnt[mode]++;
      wall[mode] += $6;
      if ($7 != "NA" && $7 != "") {
        bench[mode] += $7;
        bench_cnt[mode]++;
      }
    }
    END {
      modes[1] = "native";
      modes[2] = "nvshare";
      for (i = 1; i <= 2; i++) {
        m = modes[i];
        if (cnt[m] > 0) {
          avg_wall = wall[m] / cnt[m];
          if (bench_cnt[m] > 0) {
            avg_bench = bench[m] / bench_cnt[m];
            printf "%s\t%s\t%d\t%.2f\t%.2f\n", cluster, m, cnt[m], avg_wall, avg_bench;
          } else {
            printf "%s\t%s\t%d\t%.2f\tNA\n", cluster, m, cnt[m], avg_wall;
          }
        } else {
          printf "%s\t%s\t0\tNA\tNA\n", cluster, m;
        }
      }
    }
  ' "$results_tsv" > "$summary_tsv"

  local native_wall native_bench nvshare_wall nvshare_bench
  native_wall=$(awk -F'\t' '$2=="native"{print $4}' "$summary_tsv")
  native_bench=$(awk -F'\t' '$2=="native"{print $5}' "$summary_tsv")
  nvshare_wall=$(awk -F'\t' '$2=="nvshare"{print $4}' "$summary_tsv")
  nvshare_bench=$(awk -F'\t' '$2=="nvshare"{print $5}' "$summary_tsv")

  local wall_ratio="NA"
  local bench_ratio="NA"

  if [[ "$native_wall" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$nvshare_wall" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    wall_ratio=$(awk -v n="$native_wall" -v s="$nvshare_wall" 'BEGIN { if (n > 0) printf "%.4f", s / n; else print "NA"; }')
  fi
  if [[ "$native_bench" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$nvshare_bench" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    bench_ratio=$(awk -v n="$native_bench" -v s="$nvshare_bench" 'BEGIN { if (n > 0) printf "%.4f", s / n; else print "NA"; }')
  fi

  {
    echo -e "cluster\tnative_avg_wall_ms\tnvshare_avg_wall_ms\twall_ratio_nvshare_vs_native\tnative_avg_bench_ms\tnvshare_avg_bench_ms\tbench_ratio_nvshare_vs_native"
    echo -e "${cluster}\t${native_wall}\t${nvshare_wall}\t${wall_ratio}\t${native_bench}\t${nvshare_bench}\t${bench_ratio}"
  } > "$compare_tsv"
}

run_cluster_perf() {
  local cluster="$1"
  local need_prepare="${2:-0}"
  local run_summary_file="${3:-$RUN_SUMMARY}"
  local perf_summary_file="${4:-$PERF_SUMMARY}"
  local cluster_log_dir="${LOG_ROOT}/${cluster}"
  local perf_dir="${cluster_log_dir}/perf"
  mkdir -p "$perf_dir"

  if [[ "$need_prepare" -eq 1 ]]; then
    prepare_cluster_stack "$cluster" "$cluster_log_dir"
  fi

  local results_tsv="${perf_dir}/results.tsv"
  local summary_tsv="${perf_dir}/summary.tsv"
  local compare_tsv="${perf_dir}/compare.tsv"
  printf "cluster\tmode\tround\tpod\tphase\twall_ms\tbench_ms\tstatus\treason\n" > "$results_tsv"

  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod -l app=nvshare-remote-perf --ignore-not-found=true --wait=true || true

  local mode round
  local rc=0
  for mode in native nvshare; do
    for round in $(seq 1 "$PERF_ROUNDS"); do
      local pod_name="nvshare-perf-${cluster}-${mode}-${round}"
      local pod_manifest="${perf_dir}/${pod_name}.yaml"
      local pod_log="${perf_dir}/${pod_name}.log"
      local pod_desc="${perf_dir}/${pod_name}.describe.txt"
      local t0 t1 wait_rc phase wall_ms bench_ms status reason

      render_perf_pod_manifest "$cluster" "$mode" "$pod_manifest" "$pod_name" "$round"

      t0=$(now_ms)
      kube "$cluster" apply -f "$pod_manifest"
      wait_rc=0
      wait_for_pod_terminal "$cluster" "$pod_name" "$PERF_TIMEOUT_SEC" || wait_rc=$?
      t1=$(now_ms)

      phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
      wall_ms=$((t1 - t0))
      kube "$cluster" -n "$WORKLOAD_NAMESPACE" logs "$pod_name" > "$pod_log" 2>&1 || true
      kube "$cluster" -n "$WORKLOAD_NAMESPACE" describe pod "$pod_name" > "$pod_desc" 2>&1 || true
      bench_ms=$(extract_bench_ms "$pod_log")

      status="PASS"
      reason="ok"
      if [[ "$wait_rc" -ne 0 || "$phase" != "Succeeded" ]]; then
        status="FAIL"
        reason="phase=${phase},wait_rc=${wait_rc}"
      elif ! grep -q "PASS" "$pod_log"; then
        status="FAIL"
        reason="PASS missing"
      elif [[ "$bench_ms" == "NA" ]]; then
        status="FAIL"
        reason="bench time missing"
      fi

      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$cluster" "$mode" "$round" "$pod_name" "$phase" "$wall_ms" "$bench_ms" "$status" "$reason" >> "$results_tsv"

      kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=false || true

      if [[ "$status" != "PASS" ]]; then
        rc=1
      fi
    done
  done

  summarize_perf_results "$cluster" "$results_tsv" "$summary_tsv" "$compare_tsv"
  awk 'NR > 1' "$summary_tsv" >> "$perf_summary_file"

  local compare_row wall_ratio bench_ratio native_wall nvshare_wall
  compare_row=$(awk 'NR==2{print $0}' "$compare_tsv")
  native_wall=$(echo "$compare_row" | awk -F'\t' '{print $2}')
  nvshare_wall=$(echo "$compare_row" | awk -F'\t' '{print $3}')
  wall_ratio=$(echo "$compare_row" | awk -F'\t' '{print $4}')
  bench_ratio=$(echo "$compare_row" | awk -F'\t' '{print $7}')
  local summary="native_wall_ms=${native_wall},nvshare_wall_ms=${nvshare_wall},wall_ratio=${wall_ratio},bench_ratio=${bench_ratio}"

  if [[ "$rc" -eq 0 ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-perf" "PASS" "$summary" >> "$run_summary_file"
    log_info "[${cluster}][perf] PASS - ${summary}"
  else
    printf "%s\t%s\t%s\n" "${cluster}-perf" "FAIL" "$summary" >> "$run_summary_file"
    log_error "[${cluster}][perf] FAIL - ${summary}"
  fi

  return "$rc"
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
  local run_summary_file="${2:-$RUN_SUMMARY}"
  local cluster_log_dir="${LOG_ROOT}/${cluster}"
  mkdir -p "$cluster_log_dir"

  local pod_manifest="${cluster_log_dir}/smoke-pod.yaml"
  local pod_name="nvshare-smoke-${cluster}"

  prepare_cluster_stack "$cluster" "$cluster_log_dir"
  render_smoke_pod_manifest "$cluster" "$pod_manifest" "$pod_name"

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

  printf "%s\t%s\t%s\n" "$cluster" "$status" "$summary" >> "$run_summary_file"

  if [[ "$status" == "PASS" ]]; then
    log_info "[${cluster}] PASS - ${summary}"
    return 0
  fi

  log_error "[${cluster}] FAIL - ${summary}"
  return 1
}

run_cluster_suite() {
  local cluster="$1"
  local run_summary_file="$2"
  local perf_summary_file="$3"

  local cluster_rc=0
  if [[ "$QUOTA_ONLY" -eq 1 ]]; then
    if ! run_cluster_cann_quota "$cluster" 1 "$run_summary_file"; then
      cluster_rc=1
    fi
    return "$cluster_rc"
  fi

  local smoke_rc=0
  if [[ "$PERF_ONLY" -eq 0 ]]; then
    if ! run_cluster_smoke "$cluster" "$run_summary_file"; then
      cluster_rc=1
      smoke_rc=1
    fi
  fi

  if [[ "$PERF_BENCH" -eq 1 ]]; then
    if [[ "$PERF_ONLY" -eq 1 ]]; then
      if ! run_cluster_perf "$cluster" 1 "$run_summary_file" "$perf_summary_file"; then
        cluster_rc=1
      fi
    elif [[ "$smoke_rc" -eq 0 ]]; then
      if ! run_cluster_perf "$cluster" 0 "$run_summary_file" "$perf_summary_file"; then
        cluster_rc=1
      fi
    else
      printf "%s\t%s\t%s\n" "${cluster}-perf" "SKIP" "smoke failed, benchmark skipped" >> "$run_summary_file"
      log_warn "[${cluster}][perf] SKIP - smoke failed, benchmark skipped"
    fi
  fi

  if [[ "$QUOTA_CHECK" -eq 1 ]]; then
    if [[ "$cluster" == "cann" ]]; then
      if [[ "$smoke_rc" -eq 0 || "$PERF_ONLY" -eq 1 ]]; then
        if ! run_cluster_cann_quota "$cluster" 0 "$run_summary_file"; then
          cluster_rc=1
        fi
      else
        printf "%s\t%s\t%s\n" "${cluster}-quota" "SKIP" "smoke failed, cann quota suite skipped" >> "$run_summary_file"
        log_warn "[${cluster}][quota] SKIP - smoke failed"
      fi
    else
      printf "%s\t%s\t%s\n" "${cluster}-quota" "SKIP" "quota suite is only implemented for cann cluster" >> "$run_summary_file"
    fi
  fi

  return "$cluster_rc"
}

main() {
  log_info "run_id=${RUN_ID}"
  log_info "log_root=${LOG_ROOT}"
  log_info "clusters=${CLUSTERS[*]}"
  log_info "perf_bench=${PERF_BENCH} perf_only=${PERF_ONLY} perf_rounds=${PERF_ROUNDS}"
  log_info "quota_check=${QUOTA_CHECK} quota_only=${QUOTA_ONLY}"
  log_info "split_arch_build=${SPLIT_ARCH_BUILD}"

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
  local -a pids=()
  local -a pid_clusters=()
  local -a run_parts=()
  local -a perf_parts=()

  for cluster in "${CLUSTERS[@]}"; do
    local cluster_log_dir="${LOG_ROOT}/${cluster}"
    local run_part="${cluster_log_dir}/run-summary.part.tsv"
    local perf_part="${cluster_log_dir}/perf-summary.part.tsv"
    mkdir -p "$cluster_log_dir"
    : > "$run_part"
    : > "$perf_part"

    run_cluster_suite "$cluster" "$run_part" "$perf_part" &
    local pid=$!
    pids+=("$pid")
    pid_clusters+=("$cluster")
    run_parts+=("$run_part")
    perf_parts+=("$perf_part")
    log_info "[${cluster}] started in background pid=${pid}"
  done

  local i
  for i in "${!pids[@]}"; do
    local pid="${pids[$i]}"
    local done_cluster="${pid_clusters[$i]}"
    local run_part="${run_parts[$i]}"
    local perf_part="${perf_parts[$i]}"

    if ! wait "$pid"; then
      overall_rc=1
    fi

    if [[ -s "$run_part" ]]; then
      cat "$run_part" >> "$RUN_SUMMARY"
    fi
    if [[ "$PERF_BENCH" -eq 1 ]] && [[ -s "$perf_part" ]]; then
      cat "$perf_part" >> "$PERF_SUMMARY"
    fi
    log_info "[${done_cluster}] finished"
  done

  log_info "run summary: ${RUN_SUMMARY}"
  if [[ "$PERF_BENCH" -eq 1 ]]; then
    log_info "perf summary: ${PERF_SUMMARY}"
  fi
  if [[ "$overall_rc" -ne 0 ]]; then
    log_error "smoke run finished with failures"
  else
    log_info "smoke run passed"
  fi
  return "$overall_rc"
}

main "$@"
