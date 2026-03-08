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
NVSHARE_ASCEND_EXCLUSIVE_MODE="${XP_NVSHARE_ASCEND_EXCLUSIVE_MODE:-0}"

CUDA_DEVICE_RESOURCE_KEY="${XP_CUDA_DEVICE_RESOURCE_KEY:-nvidia.com/gpu}"
CUDA_DEVICE_RESOURCE_COUNT="${XP_CUDA_DEVICE_RESOURCE_COUNT:-2}"

CANN_DEVICE_RESOURCE_KEY="${XP_CANN_DEVICE_RESOURCE_KEY:-huawei.com/Ascend910}"
CANN_DEVICE_RESOURCE_COUNT="${XP_CANN_DEVICE_RESOURCE_COUNT:-2}"

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
PERF_CONCURRENT="${XP_PERF_CONCURRENT:-1}"
PERF_DEBUG="${XP_PERF_DEBUG:-0}"
PERF_SCHEDULING_MODE="${XP_PERF_SCHEDULING_MODE:-auto}"
MEM_WM_HIGH_PERCENT="${XP_MEM_WM_HIGH_PERCENT:-95}"
MEM_WM_LOW_PERCENT="${XP_MEM_WM_LOW_PERCENT:-90}"
QUOTA_CHECK="${XP_QUOTA_CHECK:-0}"
QUOTA_ONLY=0
QUOTA_TIMEOUT_SEC="${XP_QUOTA_TIMEOUT_SEC:-1200}"
QUOTA_OBSERVE_TIMEOUT_SEC="${XP_QUOTA_OBSERVE_TIMEOUT_SEC:-180}"
KUBECTL_CAPTURE_TIMEOUT_SEC="${XP_KUBECTL_CAPTURE_TIMEOUT_SEC:-45}"
OVERSUB_CHECK="${XP_OVERSUB_CHECK:-0}"
OVERSUB_ONLY=0
OVERSUB_TIMEOUT_SEC="${XP_OVERSUB_TIMEOUT_SEC:-1800}"
OVERSUB_CASES="${XP_OVERSUB_CASES:-all}"
OVERSUB_CHUNK_MB="${XP_OVERSUB_CHUNK_MB:-512}"
OVERSUB_TARGET_FACTOR="${XP_OVERSUB_TARGET_FACTOR:-1.20}"
OVERSUB_MAX_ALLOC_GB="${XP_OVERSUB_MAX_ALLOC_GB:-96}"
OVERSUB_HOLD_SEC="${XP_OVERSUB_HOLD_SEC:-15}"
OVERSUB_PERF_CHECK="${XP_OVERSUB_PERF_CHECK:-0}"
OVERSUB_PERF_ONLY=0
OVERSUB_PERF_TIMEOUT_SEC="${XP_OVERSUB_PERF_TIMEOUT_SEC:-3600}"
OVERSUB_PERF_CASES="${XP_OVERSUB_PERF_CASES:-all}"
OVERSUB_PERF_BASE_FACTOR="${XP_OVERSUB_PERF_BASE_FACTOR:-0.75}"
OVERSUB_PERF_OVERSUB_FACTOR="${XP_OVERSUB_PERF_OVERSUB_FACTOR:-1.20}"
OVERSUB_PERF_ACCESS_LOOPS="${XP_OVERSUB_PERF_ACCESS_LOOPS:-4}"
OVERSUB_PERF_TOUCH_MB="${XP_OVERSUB_PERF_TOUCH_MB:-64}"
OVERSUB_PERF_HOLD_SEC="${XP_OVERSUB_PERF_HOLD_SEC:-5}"
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
CANN_QUOTA_CONCURRENT_N="${XP_CANN_QUOTA_CONCURRENT_N:-4096}"
CANN_QUOTA_CONCURRENT_DURATION_SEC="${XP_CANN_QUOTA_CONCURRENT_DURATION_SEC:-45}"
CANN_QUOTA_CASES="${XP_CANN_QUOTA_CASES:-all}"
CANN_QUOTA_NPU_API_TRACE="${XP_CANN_QUOTA_NPU_API_TRACE:-1}"
CANN_QUOTA_LOCK_GATE_MIN_DELTA="${XP_CANN_QUOTA_LOCK_GATE_MIN_DELTA:-2}"
CANN_NPU_DROP_SYNC_TIMEOUT="${XP_CANN_NPU_DROP_SYNC_TIMEOUT:-0}"
CANN_PERF_MIN_PHYSICAL_NPU_FOR_16="${XP_CANN_PERF_MIN_PHYSICAL_NPU_FOR_16:-2}"

# CANN kernel module validation (npu_bypass)
CANN_RESET_NPU_MODULE="${XP_CANN_RESET_NPU_MODULE:-1}"
CANN_VERIFY_NPU_MODULE="${XP_CANN_VERIFY_NPU_MODULE:-1}"
CANN_MODULE_EXPECT_SRCVERSION="${XP_CANN_MODULE_EXPECT_SRCVERSION:-}"
CANN_MODULE_REQUIRE_7HOOK="${XP_CANN_MODULE_REQUIRE_7HOOK:-1}"
CANN_NODE_SSH_HOST="${XP_CANN_NODE_SSH_HOST:-$REMOTE_HOST}"
CANN_NODE_SSH_USER="${XP_CANN_NODE_SSH_USER:-$REMOTE_USER}"
CANN_NODE_SSH_PORT="${XP_CANN_NODE_SSH_PORT:-32033}"
CANN_MODULE_RESET_TIMEOUT_SEC="${XP_CANN_MODULE_RESET_TIMEOUT_SEC:-30}"
CANN_MODULE_VERIFY_TIMEOUT_SEC="${XP_CANN_MODULE_VERIFY_TIMEOUT_SEC:-180}"

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
  --perf-concurrent <n>   Test with N concurrent pods per round (default: 1).
  --perf-debug <0|1>      Set NVSHARE_DEBUG for perf pods (default: 0).
  --perf-scheduling-mode <auto|serial|concurrent>
                          Set scheduler mode for tests (default: auto).
  --quota-check           Run CANN quota test cases (memory/core + dynamic updates).
  --quota-only            Run only CANN quota test cases (skip smoke/perf).
  --oversub-check         Run CANN oversubscription validation cases.
  --oversub-only          Run only CANN oversubscription validation cases.
  --oversub-perf-check    Run CANN oversubscription performance cases.
  --oversub-perf-only     Run only CANN oversubscription performance cases.
  -h, --help              Show this help.

Environment overrides:
  XP_REMOTE_HOST, XP_REMOTE_USER, XP_REMOTE_PORT, XP_REMOTE_DIR
  XP_KUBECONFIG_CUDA, XP_KUBECONFIG_CANN
  XP_DOCKERHUB, XP_IMAGE_NAME, XP_REMOTE_MAKE_TARGET, XP_BASE_IMAGE, XP_BUILD_PLATFORMS, XP_SPLIT_ARCH_BUILD
  XP_GO_BUILDER_IMAGE, XP_GO_BUILDER_IMAGE_ARM64, XP_GO_BUILDER_IMAGE_AMD64
  XP_NVSHARE_VIRTUAL_DEVICES, XP_NVSHARE_ASCEND_EXCLUSIVE_MODE
  XP_SMOKE_POD_TIMEOUT_SEC
  XP_PERF_BENCH, XP_PERF_ROUNDS, XP_PERF_TIMEOUT_SEC, XP_PERF_CONCURRENT
  XP_PERF_DEBUG, XP_PERF_SCHEDULING_MODE
  XP_MEM_WM_HIGH_PERCENT, XP_MEM_WM_LOW_PERCENT
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
  XP_CANN_QUOTA_CONCURRENT_N, XP_CANN_QUOTA_CONCURRENT_DURATION_SEC
  XP_CANN_QUOTA_NPU_API_TRACE (0|1), XP_CANN_QUOTA_LOCK_GATE_MIN_DELTA
  XP_CANN_QUOTA_CASES (all|concurrent-bootstrap|mem-static|mem-dynamic|core-static|core-dynamic; comma-separated)
  XP_OVERSUB_CHECK (0|1), XP_OVERSUB_TIMEOUT_SEC
  XP_OVERSUB_CASES (all|malloc-managed|malloc-native|withcfg-managed|withcfg-cfgptr-strict; comma-separated)
  XP_OVERSUB_CHUNK_MB, XP_OVERSUB_TARGET_FACTOR, XP_OVERSUB_MAX_ALLOC_GB, XP_OVERSUB_HOLD_SEC
  XP_OVERSUB_PERF_CHECK (0|1), XP_OVERSUB_PERF_TIMEOUT_SEC
  XP_OVERSUB_PERF_CASES (all|cold-native|cold-managed|hot-native|hot-managed; comma-separated)
  XP_OVERSUB_PERF_BASE_FACTOR, XP_OVERSUB_PERF_OVERSUB_FACTOR
  XP_OVERSUB_PERF_ACCESS_LOOPS, XP_OVERSUB_PERF_TOUCH_MB, XP_OVERSUB_PERF_HOLD_SEC
  XP_CANN_PERF_MIN_PHYSICAL_NPU_FOR_16 (default: 2)
  XP_CANN_RESET_NPU_MODULE (0|1), XP_CANN_VERIFY_NPU_MODULE (0|1)
  XP_CANN_MODULE_EXPECT_SRCVERSION, XP_CANN_MODULE_REQUIRE_7HOOK (0|1)
  XP_CANN_NODE_SSH_HOST, XP_CANN_NODE_SSH_USER, XP_CANN_NODE_SSH_PORT
  XP_CANN_MODULE_RESET_TIMEOUT_SEC, XP_CANN_MODULE_VERIFY_TIMEOUT_SEC
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
    --perf-concurrent)
      PERF_CONCURRENT="$2"
      PERF_BENCH=1
      shift 2
      ;;
    --perf-debug)
      PERF_DEBUG="$2"
      PERF_BENCH=1
      shift 2
      ;;
    --perf-scheduling-mode)
      PERF_SCHEDULING_MODE="$2"
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
    --oversub-check)
      OVERSUB_CHECK=1
      shift
      ;;
    --oversub-only)
      OVERSUB_ONLY=1
      OVERSUB_CHECK=1
      OVERSUB_PERF_ONLY=0
      OVERSUB_PERF_CHECK=0
      QUOTA_ONLY=0
      QUOTA_CHECK=0
      PERF_ONLY=0
      PERF_BENCH=0
      shift
      ;;
    --oversub-perf-check)
      OVERSUB_PERF_CHECK=1
      shift
      ;;
    --oversub-perf-only)
      OVERSUB_PERF_ONLY=1
      OVERSUB_PERF_CHECK=1
      OVERSUB_ONLY=0
      OVERSUB_CHECK=0
      QUOTA_ONLY=0
      QUOTA_CHECK=0
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

if ! [[ "$PERF_CONCURRENT" =~ ^[0-9]+$ ]] || [[ "$PERF_CONCURRENT" -le 0 ]]; then
  echo "Invalid --perf-concurrent: $PERF_CONCURRENT"
  exit 1
fi

if [[ "$PERF_DEBUG" != "0" && "$PERF_DEBUG" != "1" ]]; then
  echo "Invalid --perf-debug: $PERF_DEBUG (expect 0 or 1)"
  exit 1
fi

if [[ "$PERF_SCHEDULING_MODE" != "auto" && "$PERF_SCHEDULING_MODE" != "serial" && "$PERF_SCHEDULING_MODE" != "concurrent" ]]; then
  echo "Invalid --perf-scheduling-mode: $PERF_SCHEDULING_MODE (expect auto|serial|concurrent)"
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

if [[ "$OVERSUB_CHECK" != "0" && "$OVERSUB_CHECK" != "1" ]]; then
  echo "Invalid XP_OVERSUB_CHECK: $OVERSUB_CHECK (expect 0 or 1)"
  exit 1
fi

if [[ "$OVERSUB_PERF_CHECK" != "0" && "$OVERSUB_PERF_CHECK" != "1" ]]; then
  echo "Invalid XP_OVERSUB_PERF_CHECK: $OVERSUB_PERF_CHECK (expect 0 or 1)"
  exit 1
fi

if ! [[ "$OVERSUB_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$OVERSUB_TIMEOUT_SEC" -le 0 ]]; then
  echo "Invalid XP_OVERSUB_TIMEOUT_SEC: $OVERSUB_TIMEOUT_SEC"
  exit 1
fi

if ! [[ "$OVERSUB_PERF_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$OVERSUB_PERF_TIMEOUT_SEC" -le 0 ]]; then
  echo "Invalid XP_OVERSUB_PERF_TIMEOUT_SEC: $OVERSUB_PERF_TIMEOUT_SEC"
  exit 1
fi

if ! [[ "$OVERSUB_CHUNK_MB" =~ ^[0-9]+$ ]] || [[ "$OVERSUB_CHUNK_MB" -le 0 ]]; then
  echo "Invalid XP_OVERSUB_CHUNK_MB: $OVERSUB_CHUNK_MB"
  exit 1
fi

if ! [[ "$OVERSUB_MAX_ALLOC_GB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Invalid XP_OVERSUB_MAX_ALLOC_GB: $OVERSUB_MAX_ALLOC_GB"
  exit 1
fi

if ! [[ "$OVERSUB_TARGET_FACTOR" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Invalid XP_OVERSUB_TARGET_FACTOR: $OVERSUB_TARGET_FACTOR"
  exit 1
fi

if ! [[ "$OVERSUB_PERF_BASE_FACTOR" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Invalid XP_OVERSUB_PERF_BASE_FACTOR: $OVERSUB_PERF_BASE_FACTOR"
  exit 1
fi

if ! [[ "$OVERSUB_PERF_OVERSUB_FACTOR" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Invalid XP_OVERSUB_PERF_OVERSUB_FACTOR: $OVERSUB_PERF_OVERSUB_FACTOR"
  exit 1
fi

if ! [[ "$OVERSUB_HOLD_SEC" =~ ^[0-9]+$ ]] || [[ "$OVERSUB_HOLD_SEC" -lt 0 ]]; then
  echo "Invalid XP_OVERSUB_HOLD_SEC: $OVERSUB_HOLD_SEC"
  exit 1
fi

if ! [[ "$OVERSUB_PERF_ACCESS_LOOPS" =~ ^[0-9]+$ ]] || [[ "$OVERSUB_PERF_ACCESS_LOOPS" -le 0 ]]; then
  echo "Invalid XP_OVERSUB_PERF_ACCESS_LOOPS: $OVERSUB_PERF_ACCESS_LOOPS"
  exit 1
fi

if ! [[ "$OVERSUB_PERF_TOUCH_MB" =~ ^[0-9]+$ ]] || [[ "$OVERSUB_PERF_TOUCH_MB" -le 0 ]]; then
  echo "Invalid XP_OVERSUB_PERF_TOUCH_MB: $OVERSUB_PERF_TOUCH_MB"
  exit 1
fi

if ! [[ "$OVERSUB_PERF_HOLD_SEC" =~ ^[0-9]+$ ]] || [[ "$OVERSUB_PERF_HOLD_SEC" -lt 0 ]]; then
  echo "Invalid XP_OVERSUB_PERF_HOLD_SEC: $OVERSUB_PERF_HOLD_SEC"
  exit 1
fi

if [[ "$CANN_RESET_NPU_MODULE" != "0" && "$CANN_RESET_NPU_MODULE" != "1" ]]; then
  echo "Invalid XP_CANN_RESET_NPU_MODULE: $CANN_RESET_NPU_MODULE (expect 0 or 1)"
  exit 1
fi

if [[ "$CANN_VERIFY_NPU_MODULE" != "0" && "$CANN_VERIFY_NPU_MODULE" != "1" ]]; then
  echo "Invalid XP_CANN_VERIFY_NPU_MODULE: $CANN_VERIFY_NPU_MODULE (expect 0 or 1)"
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

if ! [[ "$CANN_MODULE_RESET_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$CANN_MODULE_RESET_TIMEOUT_SEC" -le 0 ]]; then
  echo "Invalid XP_CANN_MODULE_RESET_TIMEOUT_SEC: $CANN_MODULE_RESET_TIMEOUT_SEC"
  exit 1
fi

if ! [[ "$CANN_MODULE_VERIFY_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$CANN_MODULE_VERIFY_TIMEOUT_SEC" -le 0 ]]; then
  echo "Invalid XP_CANN_MODULE_VERIFY_TIMEOUT_SEC: $CANN_MODULE_VERIFY_TIMEOUT_SEC"
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

if [[ "$CANN_QUOTA_NPU_API_TRACE" != "0" && "$CANN_QUOTA_NPU_API_TRACE" != "1" ]]; then
  echo "Invalid XP_CANN_QUOTA_NPU_API_TRACE: $CANN_QUOTA_NPU_API_TRACE (expect 0 or 1)"
  exit 1
fi

if ! [[ "$CANN_QUOTA_LOCK_GATE_MIN_DELTA" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_LOCK_GATE_MIN_DELTA" -le 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_LOCK_GATE_MIN_DELTA: $CANN_QUOTA_LOCK_GATE_MIN_DELTA"
  exit 1
fi

if [[ "$CANN_QUOTA_CASES" != "all" ]]; then
  IFS=',' read -r -a __quota_cases_validate <<< "$CANN_QUOTA_CASES"
  for __case in "${__quota_cases_validate[@]}"; do
    case "$__case" in
      concurrent-bootstrap|mem-static|mem-dynamic|core-static|core-dynamic)
        ;;
      *)
        echo "Invalid XP_CANN_QUOTA_CASES item: $__case"
        exit 1
        ;;
    esac
  done
fi

quota_case_enabled() {
  local case_name="$1"
  local c
  if [[ "$CANN_QUOTA_CASES" == "all" ]]; then
    return 0
  fi
  IFS=',' read -r -a __quota_cases_current <<< "$CANN_QUOTA_CASES"
  for c in "${__quota_cases_current[@]}"; do
    if [[ "$c" == "$case_name" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ "$OVERSUB_CASES" != "all" ]]; then
  IFS=',' read -r -a __oversub_cases_validate <<< "$OVERSUB_CASES"
  for __case in "${__oversub_cases_validate[@]}"; do
    case "$__case" in
      malloc-managed|malloc-native|withcfg-managed|withcfg-cfgptr-strict)
        ;;
      *)
        echo "Invalid XP_OVERSUB_CASES item: $__case"
        exit 1
        ;;
    esac
  done
fi

oversub_case_enabled() {
  local case_name="$1"
  local c
  if [[ "$OVERSUB_CASES" == "all" ]]; then
    return 0
  fi
  IFS=',' read -r -a __oversub_cases_current <<< "$OVERSUB_CASES"
  for c in "${__oversub_cases_current[@]}"; do
    if [[ "$c" == "$case_name" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ "$OVERSUB_PERF_CASES" != "all" ]]; then
  IFS=',' read -r -a __oversub_perf_cases_validate <<< "$OVERSUB_PERF_CASES"
  for __case in "${__oversub_perf_cases_validate[@]}"; do
    case "$__case" in
      cold-native|cold-managed|hot-native|hot-managed)
        ;;
      *)
        echo "Invalid XP_OVERSUB_PERF_CASES item: $__case"
        exit 1
        ;;
    esac
  done
fi

oversub_perf_case_enabled() {
  local case_name="$1"
  local c
  if [[ "$OVERSUB_PERF_CASES" == "all" ]]; then
    return 0
  fi
  IFS=',' read -r -a __oversub_perf_cases_current <<< "$OVERSUB_PERF_CASES"
  for c in "${__oversub_perf_cases_current[@]}"; do
    if [[ "$c" == "$case_name" ]]; then
      return 0
    fi
  done
  return 1
}

if ! [[ "$CANN_QUOTA_CORE_STATIC_ITERS" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_CORE_STATIC_ITERS" -le 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_CORE_STATIC_ITERS: $CANN_QUOTA_CORE_STATIC_ITERS"
  exit 1
fi

if ! [[ "$CANN_QUOTA_CORE_STATIC_WARMUP_ITERS" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_CORE_STATIC_WARMUP_ITERS" -lt 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_CORE_STATIC_WARMUP_ITERS: $CANN_QUOTA_CORE_STATIC_WARMUP_ITERS"
  exit 1
fi

if ! [[ "$CANN_QUOTA_CONCURRENT_N" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_CONCURRENT_N" -le 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_CONCURRENT_N: $CANN_QUOTA_CONCURRENT_N"
  exit 1
fi

if ! [[ "$CANN_QUOTA_CONCURRENT_DURATION_SEC" =~ ^[0-9]+$ ]] || [[ "$CANN_QUOTA_CONCURRENT_DURATION_SEC" -le 0 ]]; then
  echo "Invalid XP_CANN_QUOTA_CONCURRENT_DURATION_SEC: $CANN_QUOTA_CONCURRENT_DURATION_SEC"
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

run_with_timeout() {
  local timeout_sec="$1"
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${timeout_sec}" "$@"
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_sec}" "$@"
    return $?
  fi
  "$@"
}

kube_timed() {
  local timeout_sec="$1"
  local cluster="$2"
  shift 2
  local kcfg
  kcfg=$(get_kubeconfig "$cluster")
  run_with_timeout "$timeout_sec" kubectl --kubeconfig "$kcfg" "$@"
}

capture_pod_logs() {
  local cluster="$1"
  local pod_name="$2"
  local outfile="$3"
  local timeout_sec="${4:-$KUBECTL_CAPTURE_TIMEOUT_SEC}"
  if ! kube_timed "$timeout_sec" "$cluster" -n "$WORKLOAD_NAMESPACE" logs "$pod_name" > "$outfile" 2>&1; then
    echo "[capture_pod_logs] timeout_or_failure timeout_sec=${timeout_sec}" >> "$outfile"
    return 1
  fi
  return 0
}

capture_pod_describe() {
  local cluster="$1"
  local pod_name="$2"
  local outfile="$3"
  local timeout_sec="${4:-$KUBECTL_CAPTURE_TIMEOUT_SEC}"
  if ! kube_timed "$timeout_sec" "$cluster" -n "$WORKLOAD_NAMESPACE" describe pod "$pod_name" > "$outfile" 2>&1; then
    echo "[capture_pod_describe] timeout_or_failure timeout_sec=${timeout_sec}" >> "$outfile"
    return 1
  fi
  return 0
}

cann_ssh() {
  ssh -o StrictHostKeyChecking=no -p "$CANN_NODE_SSH_PORT" "${CANN_NODE_SSH_USER}@${CANN_NODE_SSH_HOST}" "$@"
}

verify_cann_npu_module_state() {
  local outfile="$1"
  cann_ssh "set -e;
    end=\$((\$(date +%s) + ${CANN_MODULE_VERIFY_TIMEOUT_SEC}))
    until lsmod | grep -qw npu_bypass; do
      if [ \$(date +%s) -ge \$end ]; then
        echo 'npu_bypass verify timeout'
        exit 1
      fi
      sleep 2
    done
    loaded_src=\$(cat /sys/module/npu_bypass/srcversion 2>/dev/null || true)
    echo \"LOADED_SRCVERSION=\$loaded_src\"
    preferred_ko=/lib/modules/\$(uname -r)/updates/npu_bypass.ko
    preferred_src=''
    if [ -f \"\$preferred_ko\" ]; then
      preferred_src=\$(modinfo \"\$preferred_ko\" 2>/dev/null | awk '/^srcversion:/ {print \$2; exit}')
      echo \"PREFERRED_SRCVERSION=\$preferred_src\"
    fi
    if [ -z \"${CANN_MODULE_EXPECT_SRCVERSION}\" ] && [ -n \"\$preferred_src\" ] && [ \"\$loaded_src\" != \"\$preferred_src\" ]; then
      echo \"loaded srcversion (\$loaded_src) != host preferred (\$preferred_src)\"
      exit 1
    fi
    if [ -n \"${CANN_MODULE_EXPECT_SRCVERSION}\" ] && [ \"\$loaded_src\" != \"${CANN_MODULE_EXPECT_SRCVERSION}\" ]; then
      echo \"unexpected npu_bypass srcversion: \$loaded_src (expect ${CANN_MODULE_EXPECT_SRCVERSION})\"
      exit 1
    fi
    npu_dmesg=\$(dmesg 2>/dev/null | grep 'npu_bypass' | tail -80 || true)
    if [ \"${CANN_MODULE_REQUIRE_7HOOK}\" = \"1\" ]; then
      active_line=\$(echo \"\$npu_dmesg\" | grep 'ACTIVE (' | tail -n1 || true)
      echo \"\$active_line\" | grep -q 'ACTIVE (7 hooks, cgroup-scan)' || { echo 'missing 7-hook signature'; echo \"\$npu_dmesg\"; exit 1; }
      boot_line=\$(echo \"\$npu_dmesg\" | nl -ba | grep 'davinci_major=' | tail -n1 | awk '{print \$1}' || true)
      if [ -n \"\$boot_line\" ]; then
        boot_block=\$(echo \"\$npu_dmesg\" | tail -n +\"\$boot_line\")
      else
        boot_block=\"\$npu_dmesg\"
      fi
      echo \"\$boot_block\" | grep -q 'hooked uda_task_can_access_udevid' || { echo 'missing uda_task_can_access_udevid hook'; echo \"\$npu_dmesg\"; exit 1; }
      echo \"\$boot_block\" | grep -q 'hooked uda_devcgroup_permission_allow' || { echo 'missing uda_devcgroup_permission_allow hook'; echo \"\$npu_dmesg\"; exit 1; }
    fi
    echo \"\$npu_dmesg\"
    echo 'VERIFY_OK'" > "$outfile" 2>&1
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
  sleep 10
  publish_component_multiarch_manifest "$LIB_IMAGE" "$lib_amd64" "$lib_arm64"
  sleep 10
  publish_component_multiarch_manifest "$SCHEDULER_IMAGE" "$scheduler_amd64" "$scheduler_arm64"
  sleep 10
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
  local extra_env_block=""
  local extra_mounts_block=""
  local extra_volumes_block=""
  local toleration_key="nvidia.com/gpu"

  if [[ "$cluster" == "cann" ]]; then
    toleration_key="$CANN_DEVICE_RESOURCE_KEY"
    selector_block=$(cat <<'EOB'
      nodeSelector:
        kubernetes.io/arch: arm64
        accelerator: huawei-Ascend910
EOB
)
    extra_env_block=$(cat <<'EOB'
        - name: LD_LIBRARY_PATH
          value: "/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/lib64"
EOB
)
    extra_mounts_block=$(cat <<'EOB'
        - name: host-ascend
          mountPath: /usr/local/Ascend
          readOnly: true
EOB
)
    extra_volumes_block=$(cat <<'EOB'
      - name: host-ascend
        hostPath:
          path: /usr/local/Ascend
          type: DirectoryOrCreate
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
${extra_mounts_block}
        env:
        - name: NVSHARE_DEBUG
          value: "1"
        - name: NVSHARE_SCHEDULING_MODE
          value: "${PERF_SCHEDULING_MODE}"
        - name: NVSHARE_INIT_PREEMPT_ENABLE
          value: "0"
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
        - name: NVSHARE_MEM_WM_HIGH_PERCENT
          value: "${MEM_WM_HIGH_PERCENT}"
        - name: NVSHARE_MEM_WM_LOW_PERCENT
          value: "${MEM_WM_LOW_PERCENT}"
${extra_env_block}
      volumes:
      - name: nvshare-socket-directory
        hostPath:
          path: /var/run/nvshare
          type: DirectoryOrCreate
${extra_volumes_block}
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
  local ascend_env_block=""
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
    ascend_env_block=$(cat <<EOF
        - name: NVSHARE_ASCEND_EXCLUSIVE_MODE
          value: "${NVSHARE_ASCEND_EXCLUSIVE_MODE}"
EOF
)
  fi

  local npu_init_block=""
  local npu_volumes_block=""
  if [[ "$cluster" == "cann" ]]; then
    npu_init_block=$(cat <<EOI
      initContainers:
      - name: npu-bypass-loader
        image: ${DEVICE_PLUGIN_IMAGE}
        command: ["/bin/sh", "/opt/npupatch/load-npu-bypass.sh"]
        env:
        - name: RUNTIME_BACKEND
          value: "ascend"
        - name: NPU_BYPASS_EXPECT_SRCVERSION
          value: "${CANN_MODULE_EXPECT_SRCVERSION}"
        - name: NPU_BYPASS_REQUIRE_7HOOK
          value: "${CANN_MODULE_REQUIRE_7HOOK}"
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-lib-modules
          mountPath: /lib/modules
          readOnly: true
EOI
)
    npu_volumes_block=$(cat <<'EOV'
      - name: host-lib-modules
        hostPath:
          path: /lib/modules
          type: Directory
EOV
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
${npu_init_block}
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
${ascend_env_block}
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
${npu_volumes_block}
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

sanitize_tsv_field() {
  local val="${1:-}"
  val="${val//$'\t'/ }"
  val="${val//$'\r'/ }"
  val="${val//$'\n'/ }"
  val=$(echo "$val" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  if [[ -z "$val" ]]; then
    echo "NA"
  else
    echo "$val"
  fi
}

capture_perf_runtime_binding() {
  local cluster="$1"
  local pod_name="$2"
  local outfile="$3"
  local timeout_sec="${4:-180}"
  local cmd='echo "NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-} ASCEND_VISIBLE_DEVICES=${ASCEND_VISIBLE_DEVICES:-} ASCEND_RT_VISIBLE_DEVICES=${ASCEND_RT_VISIBLE_DEVICES:-} NPU_VISIBLE_DEVICES=${NPU_VISIBLE_DEVICES:-}"'
  local output=""

  : > "$outfile"
  if ! wait_for_pod_phase "$cluster" "$pod_name" "Running" "$timeout_sec"; then
    echo "capture=wait_running_failed" > "$outfile"
    return 1
  fi

  output=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" exec "$pod_name" -- /bin/sh -c "$cmd" 2>/dev/null || true)
  if [[ -z "$output" ]]; then
    output=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" exec "$pod_name" -- /bin/bash -lc "$cmd" 2>/dev/null || true)
  fi
  if [[ -z "$output" ]]; then
    echo "capture=exec_failed" > "$outfile"
    return 1
  fi

  echo "$output" > "$outfile"
  return 0
}

extract_perf_binding() {
  local infile="$1"
  local raw=""
  if [[ -f "$infile" ]]; then
    raw=$(tr '\n' ' ' < "$infile")
  fi
  sanitize_tsv_field "$raw"
}

extract_node_name_from_describe() {
  local describe_file="$1"
  local node=""
  if [[ -f "$describe_file" ]]; then
    node=$(awk '/^Node:/{print $2; exit}' "$describe_file" | cut -d'/' -f1)
  fi
  if [[ -z "$node" ]]; then
    echo "NA"
  else
    echo "$node"
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
    if [[ "$cluster" == "cann" && "$CANN_VERIFY_NPU_MODULE" -eq 1 ]]; then
      log_info "[${cluster}] verify loaded npu_bypass module state (--skip-setup)"
      verify_cann_npu_module_state "${cluster_log_dir}/npu-bypass.verify.txt"
    fi
    return 0
  fi

  local scheduler_manifest="${cluster_log_dir}/scheduler.yaml"
  local device_manifest="${cluster_log_dir}/device-plugin.yaml"

  if [[ "$cluster" == "cann" && "$CANN_RESET_NPU_MODULE" -eq 1 ]]; then
    log_info "[${cluster}] reset npu_bypass module on node ${CANN_NODE_SSH_USER}@${CANN_NODE_SSH_HOST}:${CANN_NODE_SSH_PORT}"
    cann_ssh "set -e; lsmod | grep -w npu_bypass || true" > "${cluster_log_dir}/npu-bypass.pre-reset.lsmod.txt" 2>&1 || true
    cann_ssh "set -e;
      if lsmod | grep -qw npu_bypass; then
        rmmod npu_bypass;
      fi
      end=\$((\$(date +%s) + ${CANN_MODULE_RESET_TIMEOUT_SEC}))
      while lsmod | grep -qw npu_bypass; do
        if [ \$(date +%s) -ge \$end ]; then
          echo 'npu_bypass unload timeout'
          exit 1
        fi
        sleep 1
      done
      if lsmod | grep -qw npu_bypass; then
        echo 'npu_bypass still loaded after rmmod'
        exit 1
      fi
      lsmod | grep -w npu_bypass || true
      echo 'RESET_OK'" > "${cluster_log_dir}/npu-bypass.reset.txt" 2>&1
  fi

  log_info "[${cluster}] render manifests"
  render_scheduler_manifest "$cluster" "$scheduler_manifest"
  render_device_plugin_manifest "$cluster" "$device_manifest"

  log_info "[${cluster}] deploy scheduler and device-plugin"
  deploy_stack "$cluster" "$scheduler_manifest" "$device_manifest"

  if [[ "$cluster" == "cann" && "$CANN_VERIFY_NPU_MODULE" -eq 1 ]]; then
    log_info "[${cluster}] verify npu_bypass module auto-loaded by device-plugin"
    verify_cann_npu_module_state "${cluster_log_dir}/npu-bypass.verify.txt"
  fi
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
    - name: NVSHARE_NPU_DROP_SYNC_TIMEOUT
      value: "${CANN_NPU_DROP_SYNC_TIMEOUT}"
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
      value: "${PERF_DEBUG}"
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
    capture_pod_logs "$cluster" "$pod_name" "$logfile" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
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

scheduler_message_counter_value() {
  local metric_type="$1"
  local metric_file="$2"
  awk -v t="$metric_type" '
    $0 ~ ("^nvshare_scheduler_messages_total\\{type=\"" t "\"\\}") {v=$NF}
    END {if (v != "") print v}
  ' "$metric_file"
}

counter_delta_int() {
  local after="$1"
  local before="$2"
  awk -v a="${after:-0}" -v b="${before:-0}" 'BEGIN{printf "%.0f", a-b}'
}

fetch_cluster_metrics_snapshot_retry() {
  local cluster="$1"
  local outfile="$2"
  local retries="${3:-3}"
  local i
  for i in $(seq 1 "$retries"); do
    if fetch_cluster_metrics_snapshot "$cluster" "$outfile"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

extract_total_iters() {
  local logfile="$1"
  rg -o 'TOTAL_ITERS=[0-9]+' "$logfile" 2>/dev/null | tail -n1 | cut -d'=' -f2 || true
}

extract_elapsed_sec() {
  local logfile="$1"
  rg -o 'ELAPSED_SEC=[0-9]+(\.[0-9]+)?' "$logfile" 2>/dev/null | tail -n1 | cut -d'=' -f2 || true
}

cluster_max_nvshare_allocatable() {
  local cluster="$1"
  local max_val=0

  while IFS=$'\t' read -r _node _alloc; do
    local alloc
    alloc="$(echo "${_alloc:-}" | tr -cd '0-9')"
    if [[ -n "$alloc" ]] && [[ "$alloc" =~ ^[0-9]+$ ]] && (( alloc > max_val )); then
      max_val="$alloc"
    fi
  done < <(
    kube "$cluster" get nodes -l accelerator=huawei-Ascend910 \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvshare\.com/gpu}{"\n"}{end}' \
      2>/dev/null || true
  )

  echo "$max_val"
}

required_physical_devices_for_concurrency() {
  local concurrent="$1"
  local virtual_per_device="$2"
  local min_required="${3:-1}"

  if ! [[ "$concurrent" =~ ^[0-9]+$ ]] || [[ "$concurrent" -le 0 ]]; then
    echo "1"
    return
  fi
  if ! [[ "$virtual_per_device" =~ ^[0-9]+$ ]] || [[ "$virtual_per_device" -le 0 ]]; then
    echo "1"
    return
  fi

  local required=$(((concurrent + virtual_per_device - 1) / virtual_per_device))
  if [[ "$min_required" =~ ^[0-9]+$ ]] && [[ "$min_required" -gt "$required" ]]; then
    required="$min_required"
  fi

  echo "$required"
}

cann_min_physical_devices_for_perf() {
  local concurrent="$1"
  local min_for_16="$CANN_PERF_MIN_PHYSICAL_NPU_FOR_16"

  if ! [[ "$min_for_16" =~ ^[0-9]+$ ]] || [[ "$min_for_16" -le 0 ]]; then
    min_for_16=2
  fi

  if [[ "$concurrent" =~ ^[0-9]+$ ]] && (( concurrent >= 16 )); then
    echo "$min_for_16"
  else
    echo "1"
  fi
}

cluster_max_cann_physical_allocatable() {
  local cluster="$1"
  local max_val=0

  while IFS=$'\t' read -r _node _alloc; do
    local alloc
    alloc="$(echo "${_alloc:-}" | tr -cd '0-9')"
    if [[ -n "$alloc" ]] && [[ "$alloc" =~ ^[0-9]+$ ]] && (( alloc > max_val )); then
      max_val="$alloc"
    fi
  done < <(
    kube "$cluster" get nodes -l accelerator=huawei-Ascend910 \
      -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{index .status.allocatable "'"${CANN_DEVICE_RESOURCE_KEY}"'"}}{{"\n"}}{{end}}' \
      2>/dev/null || true
  )

  echo "$max_val"
}

capture_scheduler_case_log() {
  local cluster="$1"
  local outfile="$2"
  if ! kube_timed "$KUBECTL_CAPTURE_TIMEOUT_SEC" "$cluster" -n "$SYSTEM_NAMESPACE" logs -l name=nvshare-scheduler --since=40m --timestamps > "$outfile" 2>&1; then
    echo "[capture_scheduler_case_log] timeout_or_failure timeout_sec=${KUBECTL_CAPTURE_TIMEOUT_SEC}" >> "$outfile"
  fi
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
    capture_pod_logs "$cluster" "$pod_name" "$attempt_log" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
    capture_pod_describe "$cluster" "$pod_name" "$attempt_desc" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true

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
    - name: NVSHARE_NPU_API_TRACE
      value: "${CANN_QUOTA_NPU_API_TRACE}"
    - name: NVSHARE_NPU_DROP_SYNC_TIMEOUT
      value: "${CANN_NPU_DROP_SYNC_TIMEOUT}"
    - name: CANN_QUOTA_MEM_N
      value: "${CANN_QUOTA_MEM_N}"
    - name: CANN_QUOTA_MEM_STATIC_SETTLE_SEC
      value: "${CANN_QUOTA_MEM_STATIC_SETTLE_SEC}"
    - name: CANN_QUOTA_CORE_N
      value: "${CANN_QUOTA_CORE_N}"
    - name: CANN_QUOTA_CORE_DURATION_SEC
      value: "${CANN_QUOTA_CORE_DURATION_SEC}"
    - name: CANN_QUOTA_CONCURRENT_N
      value: "${CANN_QUOTA_CONCURRENT_N}"
    - name: CANN_QUOTA_CONCURRENT_DURATION_SEC
      value: "${CANN_QUOTA_CONCURRENT_DURATION_SEC}"
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
  capture_pod_logs "$cluster" "$pod_name" "$pod_log" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
  capture_pod_describe "$cluster" "$pod_name" "$pod_desc" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
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
  capture_pod_logs "$cluster" "$pod_name" "$pod_log" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
  capture_pod_describe "$cluster" "$pod_name" "$pod_desc" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
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
  capture_pod_logs "$cluster" "$pod_name" "$pod_log" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
  capture_pod_describe "$cluster" "$pod_name" "$pod_desc" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
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

run_cann_quota_case_concurrent_bootstrap() {
  local cluster="$1"
  local quota_dir="$2"
  local run_summary_file="$3"
  local case_id="cann-quota-concurrent-bootstrap"
  local case_dir="${quota_dir}/${case_id}"
  local pod_a="nvshare-quota-cann-concurrent-a"
  local pod_b="nvshare-quota-cann-concurrent-b"
  local manifest_a="${case_dir}/${pod_a}.yaml"
  local manifest_b="${case_dir}/${pod_b}.yaml"
  local pod_log_a="${case_dir}/${pod_a}.log"
  local pod_log_b="${case_dir}/${pod_b}.log"
  local pod_desc_a="${case_dir}/${pod_a}.describe.txt"
  local pod_desc_b="${case_dir}/${pod_b}.describe.txt"
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

print("BOOTSTRAP_BEGIN", flush=True)
if not hasattr(torch, "npu") or not torch.npu.is_available():
    print("NPU not available")
    sys.exit(3)
print("BOOTSTRAP_OK", flush=True)

n = int(os.getenv("CANN_QUOTA_CONCURRENT_N", "4096"))
duration = int(os.getenv("CANN_QUOTA_CONCURRENT_DURATION_SEC", "45"))
dev = torch.device("npu:0")
torch.npu.set_device(dev)
x = torch.randn([n, n], dtype=torch.float16, device=dev)
y = torch.randn([n, n], dtype=torch.float16, device=dev)
torch.npu.synchronize()

t0 = time.time()
it = 0
while True:
    z = torch.matmul(x, y)
    it += 1
    if it % 50 == 0:
        torch.npu.synchronize()
    if time.time() - t0 >= duration:
        break

torch.npu.synchronize()
print(f"TOTAL_ITERS={it}", flush=True)
print("PASS", flush=True)
PY
EOC
)

  local max_allocatable
  max_allocatable="$(cluster_max_nvshare_allocatable "$cluster")"
  log_info "[${cluster}] ${case_id}: detected max allocatable nvshare.com/gpu=${max_allocatable}"

  cleanup_quota_pods "$cluster"
  render_cann_quota_pod_manifest "$manifest_a" "$pod_a" "100" "" "$quota_cmd"
  render_cann_quota_pod_manifest "$manifest_b" "$pod_b" "100" "" "$quota_cmd"
  local run_phase_rc_a=0
  local run_phase_rc_b=0
  local wait_rc_a=0
  local wait_rc_b=0
  local phase_a="NotFound"
  local phase_b="NotFound"
  local execution_mode="concurrent"
  local stage_sched="PASS"
  local stage_sched_reason="ok"
  local stage_cann="PASS"
  local stage_cann_reason="ok"
  local req_lock_before="0"
  local req_lock_after="0"
  local req_lock_delta="0"
  local lock_ok_before="0"
  local lock_ok_after="0"
  local lock_ok_delta="0"
  local trace_hits_a="0"
  local trace_hits_b="0"
  local metrics_ok=1

  if ! fetch_cluster_metrics_snapshot_retry "$cluster" "$metrics_before" 3; then
    metrics_ok=0
    : > "$metrics_before"
    log_warn "[${cluster}] ${case_id}: failed to capture metrics-before snapshot"
  fi
  req_lock_before=$(scheduler_message_counter_value "REQ_LOCK" "$metrics_before")
  lock_ok_before=$(scheduler_message_counter_value "LOCK_OK" "$metrics_before")
  req_lock_before=${req_lock_before:-0}
  lock_ok_before=${lock_ok_before:-0}

  if [[ "$max_allocatable" =~ ^[0-9]+$ ]] && [[ "$max_allocatable" -le 1 ]]; then
    execution_mode="sequential"
    log_info "[${cluster}] ${case_id}: allocatable nvshare.com/gpu=${max_allocatable}, run sequential bootstrap check"
    kube "$cluster" apply -f "$manifest_a"
    wait_for_pod_phase "$cluster" "$pod_a" "Running" "$QUOTA_OBSERVE_TIMEOUT_SEC" || run_phase_rc_a=$?
    wait_for_pod_terminal "$cluster" "$pod_a" "$QUOTA_TIMEOUT_SEC" || wait_rc_a=$?
    phase_a=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_a" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    capture_pod_logs "$cluster" "$pod_a" "$pod_log_a" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
    capture_pod_describe "$cluster" "$pod_a" "$pod_desc_a" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
    kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_a" --ignore-not-found=true --wait=true || true

    kube "$cluster" apply -f "$manifest_b"
    wait_for_pod_phase "$cluster" "$pod_b" "Running" "$QUOTA_OBSERVE_TIMEOUT_SEC" || run_phase_rc_b=$?
    wait_for_pod_terminal "$cluster" "$pod_b" "$QUOTA_TIMEOUT_SEC" || wait_rc_b=$?
    phase_b=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_b" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    capture_pod_logs "$cluster" "$pod_b" "$pod_log_b" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
    capture_pod_describe "$cluster" "$pod_b" "$pod_desc_b" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
  else
    log_info "[${cluster}] ${case_id}: allocatable nvshare.com/gpu=${max_allocatable}, run concurrent bootstrap check"
    kube "$cluster" apply -f "$manifest_a"
    kube "$cluster" apply -f "$manifest_b"

    wait_for_pod_phase "$cluster" "$pod_a" "Running" "$QUOTA_OBSERVE_TIMEOUT_SEC" || run_phase_rc_a=$?
    wait_for_pod_phase "$cluster" "$pod_b" "Running" "$QUOTA_OBSERVE_TIMEOUT_SEC" || run_phase_rc_b=$?

    wait_for_pod_terminal "$cluster" "$pod_a" "$QUOTA_TIMEOUT_SEC" || wait_rc_a=$?
    wait_for_pod_terminal "$cluster" "$pod_b" "$QUOTA_TIMEOUT_SEC" || wait_rc_b=$?

    phase_a=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_a" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    phase_b=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_b" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    capture_pod_logs "$cluster" "$pod_a" "$pod_log_a" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
    capture_pod_logs "$cluster" "$pod_b" "$pod_log_b" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
    capture_pod_describe "$cluster" "$pod_a" "$pod_desc_a" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
    capture_pod_describe "$cluster" "$pod_b" "$pod_desc_b" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
  fi
  capture_scheduler_case_log "$cluster" "$sched_log"
  if ! fetch_cluster_metrics_snapshot_retry "$cluster" "$metrics_after" 3; then
    metrics_ok=0
    : > "$metrics_after"
    log_warn "[${cluster}] ${case_id}: failed to capture metrics-after snapshot"
  fi
  req_lock_after=$(scheduler_message_counter_value "REQ_LOCK" "$metrics_after")
  lock_ok_after=$(scheduler_message_counter_value "LOCK_OK" "$metrics_after")
  req_lock_after=${req_lock_after:-0}
  lock_ok_after=${lock_ok_after:-0}
  req_lock_delta=$(counter_delta_int "$req_lock_after" "$req_lock_before")
  lock_ok_delta=$(counter_delta_int "$lock_ok_after" "$lock_ok_before")

  local regress_pattern
  regress_pattern='NPU not available|rtGetDeviceCount: Error code=507000|drvRet=87|Runtime boot failed|507000'

  local iters_a iters_b
  iters_a=$(extract_total_iters "$pod_log_a")
  iters_b=$(extract_total_iters "$pod_log_b")
  trace_hits_a=$(rg -c "NPU API trace:" "$pod_log_a" 2>/dev/null || true)
  trace_hits_b=$(rg -c "NPU API trace:" "$pod_log_b" 2>/dev/null || true)
  trace_hits_a=${trace_hits_a:-0}
  trace_hits_b=${trace_hits_b:-0}

  if [[ "$execution_mode" == "sequential" ]]; then
    stage_sched="SKIP"
    stage_sched_reason="allocatable=${max_allocatable},sequential_only"

    if [[ "$run_phase_rc_a" -ne 0 || "$run_phase_rc_b" -ne 0 ]]; then
      stage_cann="FAIL"
      stage_cann_reason="pods_not_running rc_a=${run_phase_rc_a},rc_b=${run_phase_rc_b}"
    elif [[ "$wait_rc_a" -ne 0 || "$wait_rc_b" -ne 0 || "$phase_a" != "Succeeded" || "$phase_b" != "Succeeded" ]]; then
      stage_cann="FAIL"
      stage_cann_reason="terminal phase_a=${phase_a},phase_b=${phase_b},wait_a=${wait_rc_a},wait_b=${wait_rc_b}"
    elif ! grep -q "PASS" "$pod_log_a" || ! grep -q "PASS" "$pod_log_b"; then
      stage_cann="FAIL"
      stage_cann_reason="missing_pass_marker"
    elif ! grep -q "BOOTSTRAP_OK" "$pod_log_a" || ! grep -q "BOOTSTRAP_OK" "$pod_log_b"; then
      stage_cann="FAIL"
      stage_cann_reason="bootstrap_failed"
    elif grep -Eq "$regress_pattern" "$pod_log_a" || grep -Eq "$regress_pattern" "$pod_log_b"; then
      stage_cann="FAIL"
      stage_cann_reason="early_init_regression_pattern"
    elif [[ "$CANN_QUOTA_NPU_API_TRACE" == "1" ]] && { [[ "$trace_hits_a" -le 0 ]] || [[ "$trace_hits_b" -le 0 ]]; }; then
      stage_cann="FAIL"
      stage_cann_reason="npu_api_trace_missing trace_a=${trace_hits_a},trace_b=${trace_hits_b}"
    else
      stage_cann="PASS"
      stage_cann_reason="sequential_bootstrap_ok"
    fi
  else
    if [[ "$run_phase_rc_a" -ne 0 || "$run_phase_rc_b" -ne 0 ]]; then
      stage_sched="FAIL"
      stage_sched_reason="pods_not_running rc_a=${run_phase_rc_a},rc_b=${run_phase_rc_b}"
      stage_cann="SKIP"
      stage_cann_reason="sched_stage_failed"
    else
      stage_sched="PASS"
      stage_sched_reason="both_pods_running"

      if [[ "$wait_rc_a" -ne 0 || "$wait_rc_b" -ne 0 || "$phase_a" != "Succeeded" || "$phase_b" != "Succeeded" ]]; then
        stage_cann="FAIL"
        stage_cann_reason="terminal phase_a=${phase_a},phase_b=${phase_b},wait_a=${wait_rc_a},wait_b=${wait_rc_b}"
      elif ! grep -q "PASS" "$pod_log_a" || ! grep -q "PASS" "$pod_log_b"; then
        stage_cann="FAIL"
        stage_cann_reason="missing_pass_marker"
      elif ! grep -q "BOOTSTRAP_OK" "$pod_log_a" || ! grep -q "BOOTSTRAP_OK" "$pod_log_b"; then
        stage_cann="FAIL"
        stage_cann_reason="bootstrap_failed"
      elif grep -Eq "$regress_pattern" "$pod_log_a" || grep -Eq "$regress_pattern" "$pod_log_b"; then
        stage_cann="FAIL"
        stage_cann_reason="early_init_regression_pattern"
      elif [[ "$CANN_QUOTA_NPU_API_TRACE" == "1" ]] && { [[ "$trace_hits_a" -le 0 ]] || [[ "$trace_hits_b" -le 0 ]]; }; then
        stage_cann="FAIL"
        stage_cann_reason="npu_api_trace_missing trace_a=${trace_hits_a},trace_b=${trace_hits_b}"
      elif [[ "$metrics_ok" -ne 1 ]]; then
        stage_sched="FAIL"
        stage_sched_reason="metrics_snapshot_unavailable"
      elif [[ "$req_lock_delta" -lt "$CANN_QUOTA_LOCK_GATE_MIN_DELTA" || "$lock_ok_delta" -lt "$CANN_QUOTA_LOCK_GATE_MIN_DELTA" ]]; then
        stage_sched="FAIL"
        stage_sched_reason="lock_gate_delta_insufficient req_lock_delta=${req_lock_delta},lock_ok_delta=${lock_ok_delta},min=${CANN_QUOTA_LOCK_GATE_MIN_DELTA}"
      else
        stage_cann="PASS"
        stage_cann_reason="concurrent_bootstrap_ok"
        stage_sched_reason="both_pods_running,req_lock_delta=${req_lock_delta},lock_ok_delta=${lock_ok_delta}"
      fi
    fi
  fi

  if [[ "$stage_sched" == "FAIL" || "$stage_cann" == "FAIL" ]]; then
    status="FAIL"
  else
    status="PASS"
  fi
  summary="mode=${execution_mode},sched=${stage_sched}(${stage_sched_reason}),cann=${stage_cann}(${stage_cann_reason}),iters_a=${iters_a:-NA},iters_b=${iters_b:-NA},req_lock_before=${req_lock_before},req_lock_after=${req_lock_after},req_lock_delta=${req_lock_delta},lock_ok_before=${lock_ok_before},lock_ok_after=${lock_ok_after},lock_ok_delta=${lock_ok_delta},trace_a=${trace_hits_a},trace_b=${trace_hits_b}"

  printf "%s\t%s\t%s\n" "$case_id" "$status" "$summary" >> "$run_summary_file"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_a" "$pod_b" --ignore-not-found=true --wait=true || true
  [[ "$status" == "PASS" ]]
}

run_cluster_cann_quota() {
  local cluster="$1"
  local need_prepare="${2:-0}"
  local run_summary_file="${3:-$RUN_SUMMARY}"
  local cluster_log_dir="${LOG_ROOT}/${cluster}"
  local quota_dir="${cluster_log_dir}/quota"
  local rc=0
  local ran_cases=0
  mkdir -p "$quota_dir"

  if [[ "$cluster" != "cann" ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-quota" "SKIP" "quota suite is only implemented for cann cluster" >> "$run_summary_file"
    return 0
  fi

  if [[ "$need_prepare" -eq 1 ]]; then
    prepare_cluster_stack "$cluster" "$cluster_log_dir"
  fi

  cleanup_quota_pods "$cluster"

  if quota_case_enabled "concurrent-bootstrap"; then
    ran_cases=1
    log_info "[${cluster}][quota] case: concurrent-bootstrap"
    if ! run_cann_quota_case_concurrent_bootstrap "$cluster" "$quota_dir" "$run_summary_file"; then
      rc=1
    fi
  fi

  if quota_case_enabled "mem-static"; then
    ran_cases=1
    log_info "[${cluster}][quota] case: mem-static"
    if ! run_cann_quota_case_mem_static "$cluster" "$quota_dir" "$run_summary_file"; then
      rc=1
    fi
  fi

  if quota_case_enabled "mem-dynamic"; then
    ran_cases=1
    log_info "[${cluster}][quota] case: mem-dynamic"
    if ! run_cann_quota_case_mem_dynamic "$cluster" "$quota_dir" "$run_summary_file"; then
      rc=1
    fi
  fi

  if quota_case_enabled "core-static"; then
    ran_cases=1
    log_info "[${cluster}][quota] case: core-static"
    if ! run_cann_quota_case_core_static "$cluster" "$quota_dir" "$run_summary_file"; then
      rc=1
    fi
  fi

  if quota_case_enabled "core-dynamic"; then
    ran_cases=1
    log_info "[${cluster}][quota] case: core-dynamic"
    if ! run_cann_quota_case_core_dynamic "$cluster" "$quota_dir" "$run_summary_file"; then
      rc=1
    fi
  fi

  if [[ "$ran_cases" -eq 0 ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-quota" "SKIP" "no cann quota cases selected (XP_CANN_QUOTA_CASES=${CANN_QUOTA_CASES})" >> "$run_summary_file"
    log_warn "[${cluster}][quota] SKIP - no cases selected"
    return 0
  fi

  cleanup_quota_pods "$cluster"

  if [[ "$rc" -eq 0 ]]; then
    if [[ "$CANN_QUOTA_CASES" == "all" ]]; then
      printf "%s\t%s\t%s\n" "${cluster}-quota" "PASS" "all cann quota cases passed" >> "$run_summary_file"
    else
      printf "%s\t%s\t%s\n" "${cluster}-quota" "PASS" "selected cann quota cases passed (${CANN_QUOTA_CASES})" >> "$run_summary_file"
    fi
    log_info "[${cluster}][quota] PASS"
  else
    if [[ "$CANN_QUOTA_CASES" == "all" ]]; then
      printf "%s\t%s\t%s\n" "${cluster}-quota" "FAIL" "one or more cann quota cases failed" >> "$run_summary_file"
    else
      printf "%s\t%s\t%s\n" "${cluster}-quota" "FAIL" "one or more selected cann quota cases failed (${CANN_QUOTA_CASES})" >> "$run_summary_file"
    fi
    log_error "[${cluster}][quota] FAIL"
  fi

  return "$rc"
}

cleanup_oversub_pods() {
  local cluster="$1"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod -l app=nvshare-remote-oversub --ignore-not-found=true --wait=true || true
}

render_cann_oversub_pod_manifest() {
  local outfile="$1"
  local pod_name="$2"
  local api_name="$3"
  local alloc_mode="$4"
  local withcfg_enable="$5"
  local fallback_enable="$6"
  local single_oversub="$7"
  local cfg_mode="$8"
  local single_oversub_env_block=""

  if [[ "$single_oversub" == "1" ]]; then
    single_oversub_env_block=$(cat <<'EOB'
    - name: NVSHARE_ENABLE_SINGLE_OVERSUB
      value: "1"
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
    app: nvshare-remote-oversub
    oversub-cluster: cann
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
  - name: oversub
    image: ${CANN_BENCH_IMAGE}
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - |
      python3 - <<'PY'
      import ctypes
      import os
      import sys
      import time

      ACL_HBM_MEM = 1
      GI_B = 1024 * 1024 * 1024

      api_name = os.getenv("OV_API", "malloc")
      cfg_mode = os.getenv("OV_CFG_MODE", "null")
      chunk_mb = int(os.getenv("OV_CHUNK_MB", "512"))
      target_factor = float(os.getenv("OV_TARGET_FACTOR", "1.20"))
      max_alloc_gb = float(os.getenv("OV_MAX_ALLOC_GB", "96"))
      hold_sec = int(os.getenv("OV_HOLD_SEC", "15"))

      lib = ctypes.CDLL("libascendcl.so")

      lib.aclrtGetDeviceCount.argtypes = [ctypes.POINTER(ctypes.c_uint32)]
      lib.aclrtGetDeviceCount.restype = ctypes.c_int
      lib.aclInit.argtypes = [ctypes.c_char_p]
      lib.aclInit.restype = ctypes.c_int
      lib.aclrtSetDevice.argtypes = [ctypes.c_int]
      lib.aclrtSetDevice.restype = ctypes.c_int
      lib.aclrtGetMemInfo.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)]
      lib.aclrtGetMemInfo.restype = ctypes.c_int
      lib.aclrtMalloc.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t, ctypes.c_int]
      lib.aclrtMalloc.restype = ctypes.c_int
      lib.aclrtMallocWithCfg.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t, ctypes.c_int, ctypes.c_void_p]
      lib.aclrtMallocWithCfg.restype = ctypes.c_int
      lib.aclrtFree.argtypes = [ctypes.c_void_p]
      lib.aclrtFree.restype = ctypes.c_int

      cnt = ctypes.c_uint32(0)
      ret = lib.aclrtGetDeviceCount(ctypes.byref(cnt))
      print(f"STEP aclrtGetDeviceCount ret={ret} count={cnt.value}")
      if ret != 0 or cnt.value == 0:
          sys.exit(10)

      ret = lib.aclInit(None)
      print(f"STEP aclInit ret={ret}")
      if ret != 0:
          sys.exit(11)

      ret = lib.aclrtSetDevice(0)
      print(f"STEP aclrtSetDevice ret={ret}")
      if ret != 0:
          sys.exit(12)

      free_mem = ctypes.c_size_t(0)
      total_mem = ctypes.c_size_t(0)
      ret_mem = lib.aclrtGetMemInfo(ACL_HBM_MEM, ctypes.byref(free_mem), ctypes.byref(total_mem))
      if ret_mem != 0 or total_mem.value == 0:
          total_mem.value = int(max_alloc_gb * GI_B)
      target_bytes = int(total_mem.value * target_factor)
      cap_bytes = int(max_alloc_gb * GI_B)
      if target_bytes > cap_bytes:
          target_bytes = cap_bytes

      chunk_bytes = chunk_mb * 1024 * 1024
      if chunk_bytes <= 0:
          chunk_bytes = 512 * 1024 * 1024
      if target_bytes < chunk_bytes:
          target_bytes = chunk_bytes

      ptrs = []
      allocated = 0
      fail_ret = 0
      idx = 0

      print(f"OVSET api={api_name} cfg_mode={cfg_mode} total_mem_bytes={total_mem.value} target_bytes={target_bytes} chunk_bytes={chunk_bytes}")
      while allocated < target_bytes:
          ptr = ctypes.c_void_p()
          if api_name == "mallocWithCfg":
              cfg = None if cfg_mode == "null" else ctypes.c_void_p(1)
              ret = lib.aclrtMallocWithCfg(ctypes.byref(ptr), chunk_bytes, 0, cfg)
          else:
              ret = lib.aclrtMalloc(ctypes.byref(ptr), chunk_bytes, 0)
          if ret != 0 or not ptr.value:
              fail_ret = ret if ret != 0 else -1
              print(f"ALLOC_FAIL idx={idx} ret={ret} ptr={ptr.value}")
              break
          ptrs.append(ptr)
          allocated += chunk_bytes
          idx += 1
          if idx % 8 == 0:
              print(f"ALLOC_PROGRESS chunks={idx} allocated_bytes={allocated}")

      print(f"OVSUM api={api_name} total_mem_bytes={total_mem.value} target_bytes={target_bytes} allocated_bytes={allocated} alloc_count={len(ptrs)} fail_ret={fail_ret}")

      if fail_ret == 0 and hold_sec > 0:
          time.sleep(hold_sec)

      free_fail = 0
      for p in reversed(ptrs):
          fr = lib.aclrtFree(p)
          if fr != 0:
              free_fail = fr
              print(f"FREE_FAIL ret={fr}")
              break

      if fail_ret != 0:
          print("OVERSUB_FAIL")
          sys.exit(3)
      if free_fail != 0:
          print("OVERSUB_FREE_FAIL")
          sys.exit(4)
      print("OVERSUB_PASS")
      sys.exit(0)
      PY
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    - name: NVSHARE_NPU_DROP_SYNC_TIMEOUT
      value: "${CANN_NPU_DROP_SYNC_TIMEOUT}"
    - name: NVSHARE_NPU_OVERSUB_ALLOC_MODE
      value: "${alloc_mode}"
    - name: NVSHARE_NPU_MANAGED_WITHCFG
      value: "${withcfg_enable}"
    - name: NVSHARE_NPU_MANAGED_FALLBACK
      value: "${fallback_enable}"
${single_oversub_env_block}
    - name: OV_API
      value: "${api_name}"
    - name: OV_CFG_MODE
      value: "${cfg_mode}"
    - name: OV_CHUNK_MB
      value: "${OVERSUB_CHUNK_MB}"
    - name: OV_TARGET_FACTOR
      value: "${OVERSUB_TARGET_FACTOR}"
    - name: OV_MAX_ALLOC_GB
      value: "${OVERSUB_MAX_ALLOC_GB}"
    - name: OV_HOLD_SEC
      value: "${OVERSUB_HOLD_SEC}"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF
}

extract_oversub_log_value() {
  local logfile="$1"
  local key="$2"
  awk -v k="$key" '
    /^OVSUM / {
      for (i = 1; i <= NF; i++) {
        if ($i ~ ("^" k "=")) {
          split($i, a, "=");
          v = a[2];
        }
      }
    }
    END { if (v != "") print v; }
  ' "$logfile"
}

render_cann_oversub_perf_pod_manifest() {
  local outfile="$1"
  local pod_name="$2"
  local case_id="$3"
  local access_mode="$4"
  local alloc_mode="$5"
  local single_oversub="$6"
  local target_factor="$7"
  local single_oversub_env_block=""

  if [[ "$single_oversub" == "1" ]]; then
    single_oversub_env_block=$(cat <<'EOB'
    - name: NVSHARE_ENABLE_SINGLE_OVERSUB
      value: "1"
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
    app: nvshare-remote-oversub
    oversub-cluster: cann
    oversub-perf-case: ${case_id}
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
  - name: oversub-perf
    image: ${CANN_BENCH_IMAGE}
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - |
      python3 - <<'PY'
      import ctypes
      import os
      import sys
      import time

      ACL_HBM_MEM = 1

      case_id = os.getenv("OV_PERF_CASE_ID", "unknown")
      access_mode = os.getenv("OV_PERF_ACCESS_MODE", "cold")
      chunk_mb = int(os.getenv("OV_CHUNK_MB", "512"))
      target_factor = float(os.getenv("OV_PERF_TARGET_FACTOR", "1.20"))
      max_alloc_gb = float(os.getenv("OV_MAX_ALLOC_GB", "96"))
      access_loops = int(os.getenv("OV_PERF_ACCESS_LOOPS", "4"))
      touch_mb = int(os.getenv("OV_PERF_TOUCH_MB", "64"))
      hold_sec = int(os.getenv("OV_PERF_HOLD_SEC", "5"))
      alloc_mode = os.getenv("OV_PERF_ALLOC_MODE", "acl")

      lib = ctypes.CDLL("libascendcl.so")
      lib.aclrtGetDeviceCount.argtypes = [ctypes.POINTER(ctypes.c_uint32)]
      lib.aclrtGetDeviceCount.restype = ctypes.c_int
      lib.aclInit.argtypes = [ctypes.c_char_p]
      lib.aclInit.restype = ctypes.c_int
      lib.aclrtSetDevice.argtypes = [ctypes.c_int]
      lib.aclrtSetDevice.restype = ctypes.c_int
      lib.aclrtGetMemInfo.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)]
      lib.aclrtGetMemInfo.restype = ctypes.c_int
      lib.aclrtMalloc.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t, ctypes.c_int]
      lib.aclrtMalloc.restype = ctypes.c_int
      lib.aclrtFree.argtypes = [ctypes.c_void_p]
      lib.aclrtFree.restype = ctypes.c_int

      has_memset = hasattr(lib, "aclrtMemset")
      has_sync = hasattr(lib, "aclrtSynchronizeDevice")
      if has_memset:
        lib.aclrtMemset.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_size_t]
        lib.aclrtMemset.restype = ctypes.c_int
      if has_sync:
        lib.aclrtSynchronizeDevice.argtypes = []
        lib.aclrtSynchronizeDevice.restype = ctypes.c_int

      def sync_device():
        if not has_sync:
          return 0
        return lib.aclrtSynchronizeDevice()

      cnt = ctypes.c_uint32(0)
      ret = lib.aclrtGetDeviceCount(ctypes.byref(cnt))
      print(f"STEP aclrtGetDeviceCount ret={ret} count={cnt.value}")
      if ret != 0 or cnt.value == 0:
          sys.exit(10)

      ret = lib.aclInit(None)
      print(f"STEP aclInit ret={ret}")
      if ret != 0:
          sys.exit(11)

      ret = lib.aclrtSetDevice(0)
      print(f"STEP aclrtSetDevice ret={ret}")
      if ret != 0:
          sys.exit(12)

      free_mem = ctypes.c_size_t(0)
      total_mem = ctypes.c_size_t(0)
      ret_mem = lib.aclrtGetMemInfo(ACL_HBM_MEM, ctypes.byref(free_mem), ctypes.byref(total_mem))
      if ret_mem != 0 or total_mem.value == 0:
          total_mem.value = int(max_alloc_gb * 1024 * 1024 * 1024)

      chunk_bytes = max(1, chunk_mb) * 1024 * 1024
      cap_bytes = int(max_alloc_gb * 1024 * 1024 * 1024)
      target_bytes = int(total_mem.value * target_factor)
      if target_bytes > cap_bytes:
          target_bytes = cap_bytes
      if target_bytes < chunk_bytes:
          target_bytes = chunk_bytes

      ptrs = []
      allocated = 0
      fail_ret = 0
      alloc_count = 0

      t0 = time.time()
      print(f"OVPERF_SETUP case={case_id} access_mode={access_mode} alloc_mode={alloc_mode} total_mem_bytes={total_mem.value} target_bytes={target_bytes} chunk_bytes={chunk_bytes} loops={access_loops} touch_mb={touch_mb}")
      alloc_start = time.time()
      while allocated < target_bytes:
          ptr = ctypes.c_void_p()
          ret = lib.aclrtMalloc(ctypes.byref(ptr), chunk_bytes, 0)
          if ret != 0 or not ptr.value:
              fail_ret = ret if ret != 0 else -1
              print(f"OVPERF_ALLOC_FAIL idx={alloc_count} ret={ret} ptr={ptr.value}")
              break
          ptrs.append(ptr)
          allocated += chunk_bytes
          alloc_count += 1
      alloc_ms = int((time.time() - alloc_start) * 1000)

      access_ms = 0
      if fail_ret == 0:
          if access_mode == "hot":
              if not has_memset:
                  fail_ret = -2
                  print("OVPERF_ERR aclrtMemset symbol unavailable")
              else:
                  touch_bytes = min(chunk_bytes, max(1, touch_mb) * 1024 * 1024)
                  access_start = time.time()
                  for loop_idx in range(max(1, access_loops)):
                      value = loop_idx % 127
                      for p in ptrs:
                          ret = lib.aclrtMemset(p, chunk_bytes, value, touch_bytes)
                          if ret != 0:
                              fail_ret = ret
                              print(f"OVPERF_TOUCH_FAIL loop={loop_idx} ret={ret}")
                              break
                      if fail_ret != 0:
                          break
                      sret = sync_device()
                      if sret != 0:
                          fail_ret = sret
                          print(f"OVPERF_SYNC_FAIL loop={loop_idx} ret={sret}")
                          break
                  access_ms = int((time.time() - access_start) * 1000)
          elif hold_sec > 0:
              access_start = time.time()
              time.sleep(hold_sec)
              access_ms = int((time.time() - access_start) * 1000)

      free_fail = 0
      for p in reversed(ptrs):
          fr = lib.aclrtFree(p)
          if fr != 0:
              free_fail = fr
              print(f"OVPERF_FREE_FAIL ret={fr}")
              break

      total_ms = int((time.time() - t0) * 1000)
      print(f"OVPERF_SUMMARY case={case_id} access_mode={access_mode} alloc_mode={alloc_mode} total_mem_bytes={total_mem.value} target_bytes={target_bytes} allocated_bytes={allocated} alloc_count={alloc_count} alloc_ms={alloc_ms} access_ms={access_ms} total_ms={total_ms} fail_ret={fail_ret} free_fail={free_fail}")

      if fail_ret != 0 or free_fail != 0:
          print("OVPERF_FAIL")
          sys.exit(3)

      print("OVPERF_PASS")
      sys.exit(0)
      PY
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    - name: NVSHARE_NPU_DROP_SYNC_TIMEOUT
      value: "${CANN_NPU_DROP_SYNC_TIMEOUT}"
    - name: NVSHARE_NPU_OVERSUB_ALLOC_MODE
      value: "${alloc_mode}"
    - name: NVSHARE_NPU_MANAGED_FALLBACK
      value: "1"
${single_oversub_env_block}
    - name: OV_PERF_CASE_ID
      value: "${case_id}"
    - name: OV_PERF_ACCESS_MODE
      value: "${access_mode}"
    - name: OV_PERF_ALLOC_MODE
      value: "${alloc_mode}"
    - name: OV_PERF_TARGET_FACTOR
      value: "${target_factor}"
    - name: OV_PERF_ACCESS_LOOPS
      value: "${OVERSUB_PERF_ACCESS_LOOPS}"
    - name: OV_PERF_TOUCH_MB
      value: "${OVERSUB_PERF_TOUCH_MB}"
    - name: OV_PERF_HOLD_SEC
      value: "${OVERSUB_PERF_HOLD_SEC}"
    - name: OV_CHUNK_MB
      value: "${OVERSUB_CHUNK_MB}"
    - name: OV_MAX_ALLOC_GB
      value: "${OVERSUB_MAX_ALLOC_GB}"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF
}

extract_oversub_perf_log_value() {
  local logfile="$1"
  local key="$2"
  awk -v k="$key" '
    /^OVPERF_SUMMARY / {
      for (i = 1; i <= NF; i++) {
        if ($i ~ ("^" k "=")) {
          split($i, a, "=");
          v = a[2];
        }
      }
    }
    END { if (v != "") print v; }
  ' "$logfile"
}

run_cann_oversub_perf_case() {
  local cluster="$1"
  local perf_dir="$2"
  local case_results_tsv="$3"
  local case_id="$4"
  local access_mode="$5"
  local alloc_mode="$6"
  local single_oversub="$7"
  local target_factor="$8"
  local require_oversub="$9"

  local case_dir="${perf_dir}/${case_id}"
  local pod_name="nvshare-ovperf-${case_id}"
  local manifest="${case_dir}/${pod_name}.yaml"
  local pod_log="${case_dir}/${pod_name}.log"
  local pod_desc="${case_dir}/${pod_name}.describe.txt"
  local metrics_running="${case_dir}/metrics-running.txt"
  local metrics_after="${case_dir}/metrics-after.txt"
  local status="PASS"
  local summary="ok"
  local wait_rc=0
  local run_rc=0
  local total_bytes="NA"
  local target_bytes="NA"
  local allocated_bytes="NA"
  local alloc_ms="NA"
  local access_ms="NA"
  local total_ms="NA"
  local fail_ret="NA"
  local running_metric="NA"
  local peak_metric="NA"

  mkdir -p "$case_dir"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=true || true
  render_cann_oversub_perf_pod_manifest "$manifest" "$pod_name" "$case_id" "$access_mode" "$alloc_mode" "$single_oversub" "$target_factor"
  kube "$cluster" apply -f "$manifest" >/dev/null

  if wait_for_pod_phase "$cluster" "$pod_name" "Running" "$QUOTA_OBSERVE_TIMEOUT_SEC"; then
    if fetch_cluster_metrics_snapshot_retry "$cluster" "$metrics_running" 3; then
      running_metric=$(metric_value_for_pod "nvshare_client_managed_allocated_bytes" "$pod_name" "$metrics_running")
    fi
  fi

  wait_for_pod_terminal "$cluster" "$pod_name" "$OVERSUB_PERF_TIMEOUT_SEC" || wait_rc=$?
  capture_pod_logs "$cluster" "$pod_name" "$pod_log" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || run_rc=1
  capture_pod_describe "$cluster" "$pod_name" "$pod_desc" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
  fetch_cluster_metrics_snapshot_retry "$cluster" "$metrics_after" 3 || true
  peak_metric=$(metric_value_for_pod "nvshare_client_managed_allocated_peak_bytes" "$pod_name" "$metrics_after")
  [[ -n "${running_metric:-}" ]] || running_metric="NA"
  [[ -n "${peak_metric:-}" ]] || peak_metric="NA"

  total_bytes=$(extract_oversub_perf_log_value "$pod_log" "total_mem_bytes")
  target_bytes=$(extract_oversub_perf_log_value "$pod_log" "target_bytes")
  allocated_bytes=$(extract_oversub_perf_log_value "$pod_log" "allocated_bytes")
  alloc_ms=$(extract_oversub_perf_log_value "$pod_log" "alloc_ms")
  access_ms=$(extract_oversub_perf_log_value "$pod_log" "access_ms")
  total_ms=$(extract_oversub_perf_log_value "$pod_log" "total_ms")
  fail_ret=$(extract_oversub_perf_log_value "$pod_log" "fail_ret")
  [[ -n "${total_bytes:-}" ]] || total_bytes="NA"
  [[ -n "${target_bytes:-}" ]] || target_bytes="NA"
  [[ -n "${allocated_bytes:-}" ]] || allocated_bytes="NA"
  [[ -n "${alloc_ms:-}" ]] || alloc_ms="NA"
  [[ -n "${access_ms:-}" ]] || access_ms="NA"
  [[ -n "${total_ms:-}" ]] || total_ms="NA"
  [[ -n "${fail_ret:-}" ]] || fail_ret="NA"

  if [[ "$run_rc" -ne 0 || "$wait_rc" -ne 0 ]]; then
    status="FAIL"
    summary="pod did not succeed (run_rc=${run_rc}, wait_rc=${wait_rc})"
  elif ! grep -q "OVPERF_PASS" "$pod_log"; then
    status="FAIL"
    summary="missing OVPERF_PASS marker"
  elif [[ "$fail_ret" != "0" ]]; then
    status="FAIL"
    summary="fail_ret=${fail_ret}"
  elif [[ "$total_ms" == "NA" ]]; then
    status="FAIL"
    summary="missing total_ms"
  elif [[ "$require_oversub" == "1" ]]; then
    if ! awk -v a="${allocated_bytes:-0}" -v t="${total_bytes:-0}" 'BEGIN{exit !(a>t && t>0)}'; then
      status="FAIL"
      summary="allocated_bytes(${allocated_bytes}) did not exceed total_mem_bytes(${total_bytes})"
    fi
  fi

  if [[ "$status" == "PASS" ]]; then
    summary="ok"
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$case_id" "$status" "$access_mode" "$alloc_mode" "$target_factor" "$total_bytes" "$target_bytes" "$allocated_bytes" \
    "$alloc_ms" "$access_ms" "$total_ms" "$fail_ret" "$running_metric" "$peak_metric" "$summary" >> "$case_results_tsv"

  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=true || true
  [[ "$status" == "PASS" ]]
}

run_cann_oversub_case() {
  local cluster="$1"
  local oversub_dir="$2"
  local run_summary_file="$3"
  local case_id="$4"
  local api_name="$5"
  local alloc_mode="$6"
  local withcfg_enable="$7"
  local fallback_enable="$8"
  local single_oversub="$9"
  local cfg_mode="${10}"
  local expect_success="${11}"
  local require_oversub="${12}"
  local expect_log_pattern="${13:-}"

  local case_dir="${oversub_dir}/${case_id}"
  local pod_name="nvshare-oversub-${case_id}"
  local manifest="${case_dir}/${pod_name}.yaml"
  local pod_log="${case_dir}/${pod_name}.log"
  local pod_desc="${case_dir}/${pod_name}.describe.txt"
  local metrics_running="${case_dir}/metrics-running.txt"
  local metrics_after="${case_dir}/metrics-after.txt"
  local status="PASS"
  local summary="ok"
  local wait_rc=0
  local run_rc=0
  local total_bytes="NA"
  local target_bytes="NA"
  local allocated_bytes="NA"
  local fail_ret="NA"
  local peak_metric="NA"
  local running_metric="NA"
  local saw_running=0

  mkdir -p "$case_dir"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=true || true
  render_cann_oversub_pod_manifest "$manifest" "$pod_name" "$api_name" "$alloc_mode" "$withcfg_enable" "$fallback_enable" "$single_oversub" "$cfg_mode"
  kube "$cluster" apply -f "$manifest" >/dev/null

  if wait_for_pod_phase "$cluster" "$pod_name" "Running" "$QUOTA_OBSERVE_TIMEOUT_SEC"; then
    saw_running=1
    if fetch_cluster_metrics_snapshot_retry "$cluster" "$metrics_running" 3; then
      running_metric=$(metric_value_for_pod "nvshare_client_managed_allocated_bytes" "$pod_name" "$metrics_running")
    else
      : > "$metrics_running"
    fi
  else
    : > "$metrics_running"
  fi

  wait_for_pod_terminal "$cluster" "$pod_name" "$OVERSUB_TIMEOUT_SEC" || wait_rc=$?

  if ! capture_pod_logs "$cluster" "$pod_name" "$pod_log" "$KUBECTL_CAPTURE_TIMEOUT_SEC"; then
    run_rc=1
  fi
  capture_pod_describe "$cluster" "$pod_name" "$pod_desc" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
  if ! fetch_cluster_metrics_snapshot_retry "$cluster" "$metrics_after" 3; then
    : > "$metrics_after"
  fi
  peak_metric=$(metric_value_for_pod "nvshare_client_managed_allocated_peak_bytes" "$pod_name" "$metrics_after")
  if [[ -z "${peak_metric:-}" ]]; then
    peak_metric="NA"
  fi

  total_bytes=$(extract_oversub_log_value "$pod_log" "total_mem_bytes")
  target_bytes=$(extract_oversub_log_value "$pod_log" "target_bytes")
  allocated_bytes=$(extract_oversub_log_value "$pod_log" "allocated_bytes")
  fail_ret=$(extract_oversub_log_value "$pod_log" "fail_ret")
  [[ -n "${total_bytes:-}" ]] || total_bytes="NA"
  [[ -n "${target_bytes:-}" ]] || target_bytes="NA"
  [[ -n "${allocated_bytes:-}" ]] || allocated_bytes="NA"
  [[ -n "${fail_ret:-}" ]] || fail_ret="NA"
  [[ -n "${running_metric:-}" ]] || running_metric="NA"

  if [[ "$expect_success" == "1" ]]; then
    if [[ "$run_rc" -ne 0 || "$wait_rc" -ne 0 ]]; then
      status="FAIL"
      summary="pod did not succeed (run_rc=${run_rc}, wait_rc=${wait_rc})"
    elif ! grep -q "OVERSUB_PASS" "$pod_log"; then
      status="FAIL"
      summary="missing OVERSUB_PASS marker"
    elif [[ "$require_oversub" == "1" ]]; then
      local metric_oversub=0
      if ! awk -v a="${allocated_bytes:-0}" -v t="${total_bytes:-0}" 'BEGIN{exit !(a>t && t>0)}'; then
        status="FAIL"
        summary="allocated_bytes(${allocated_bytes}) did not exceed total_mem_bytes(${total_bytes})"
      fi
      if [[ "$status" == "PASS" && "$running_metric" != "NA" ]] && awk -v p="$running_metric" -v t="${total_bytes:-0}" 'BEGIN{exit !(p>t && t>0)}'; then
        metric_oversub=1
      fi
      if [[ "$status" == "PASS" && "$peak_metric" != "NA" ]] && awk -v p="$peak_metric" -v t="${total_bytes:-0}" 'BEGIN{exit !(p>t && t>0)}'; then
        metric_oversub=1
      fi
      if [[ "$status" == "PASS" && "$metric_oversub" -ne 1 ]]; then
        status="FAIL"
        summary="oversub metric missing or not exceeded (running=${running_metric}, peak=${peak_metric}, total=${total_bytes})"
      fi
    fi
    if [[ "$status" == "PASS" && -n "$expect_log_pattern" ]]; then
      if ! grep -q "$expect_log_pattern" "$pod_log"; then
        status="FAIL"
        summary="expected log pattern not found: ${expect_log_pattern}"
      fi
    fi
  else
    if [[ "$run_rc" -ne 0 ]]; then
      status="FAIL"
      summary="failed to capture pod log"
    else
      local failed_expected=0
      if [[ "$wait_rc" -ne 0 ]]; then
        failed_expected=1
      elif grep -q "OVERSUB_FAIL" "$pod_log"; then
        failed_expected=1
      elif [[ "$fail_ret" != "0" && "$fail_ret" != "NA" ]]; then
        failed_expected=1
      fi
      if [[ "$failed_expected" -ne 1 ]]; then
        status="FAIL"
        summary="expected failure but case succeeded"
      fi
      if [[ "$status" == "PASS" && -n "$expect_log_pattern" ]]; then
        if ! grep -q "$expect_log_pattern" "$pod_log"; then
          status="FAIL"
          summary="expected failure log pattern not found: ${expect_log_pattern}"
        fi
      fi
    fi
  fi

  summary="api=${api_name},mode=${alloc_mode},withcfg=${withcfg_enable},fallback=${fallback_enable},single_oversub=${single_oversub},cfg_mode=${cfg_mode},expect_success=${expect_success},wait_rc=${wait_rc},saw_running=${saw_running},total=${total_bytes},target=${target_bytes},allocated=${allocated_bytes},fail_ret=${fail_ret},running_metric=${running_metric},peak_metric=${peak_metric},status_reason=${summary}"
  printf "%s\t%s\t%s\n" "$case_id" "$status" "$summary" >> "$run_summary_file"
  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=true || true
  [[ "$status" == "PASS" ]]
}

run_cluster_cann_oversub() {
  local cluster="$1"
  local need_prepare="${2:-0}"
  local run_summary_file="${3:-$RUN_SUMMARY}"
  local cluster_log_dir="${LOG_ROOT}/${cluster}"
  local oversub_dir="${cluster_log_dir}/oversub"
  local rc=0
  local ran_cases=0
  mkdir -p "$oversub_dir"

  if [[ "$cluster" != "cann" ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-oversub" "SKIP" "oversub suite is only implemented for cann cluster" >> "$run_summary_file"
    return 0
  fi

  if [[ "$need_prepare" -eq 1 ]]; then
    prepare_cluster_stack "$cluster" "$cluster_log_dir"
  fi

  cleanup_oversub_pods "$cluster"

  if oversub_case_enabled "malloc-managed"; then
    ran_cases=1
    log_info "[${cluster}][oversub] case: malloc-managed"
    if ! run_cann_oversub_case "$cluster" "$oversub_dir" "$run_summary_file" \
      "cann-oversub-malloc-managed" "malloc" "managed" "0" "1" "1" "null" "1" "1" ""; then
      rc=1
    fi
  fi

  if oversub_case_enabled "malloc-native"; then
    ran_cases=1
    log_info "[${cluster}][oversub] case: malloc-native"
    if ! run_cann_oversub_case "$cluster" "$oversub_dir" "$run_summary_file" \
      "cann-oversub-malloc-native" "malloc" "acl" "0" "1" "0" "null" "0" "0" ""; then
      rc=1
    fi
  fi

  if oversub_case_enabled "withcfg-managed"; then
    ran_cases=1
    log_info "[${cluster}][oversub] case: withcfg-managed"
    if ! run_cann_oversub_case "$cluster" "$oversub_dir" "$run_summary_file" \
      "cann-oversub-withcfg-managed" "mallocWithCfg" "managed" "1" "0" "1" "null" "1" "1" "NPU managed path enabled for aclrtMallocWithCfg"; then
      rc=1
    fi
  fi

  if oversub_case_enabled "withcfg-cfgptr-strict"; then
    ran_cases=1
    log_info "[${cluster}][oversub] case: withcfg-cfgptr-strict"
    if ! run_cann_oversub_case "$cluster" "$oversub_dir" "$run_summary_file" \
      "cann-oversub-withcfg-cfgptr-strict" "mallocWithCfg" "managed" "1" "0" "1" "ptr" "0" "0" "cfg is not NULL"; then
      rc=1
    fi
  fi

  if [[ "$ran_cases" -eq 0 ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-oversub" "SKIP" "no oversub cases selected (XP_OVERSUB_CASES=${OVERSUB_CASES})" >> "$run_summary_file"
    log_warn "[${cluster}][oversub] SKIP - no cases selected"
    return 0
  fi

  cleanup_oversub_pods "$cluster"

  if [[ "$rc" -eq 0 ]]; then
    if [[ "$OVERSUB_CASES" == "all" ]]; then
      printf "%s\t%s\t%s\n" "${cluster}-oversub" "PASS" "all cann oversub cases passed" >> "$run_summary_file"
    else
      printf "%s\t%s\t%s\n" "${cluster}-oversub" "PASS" "selected cann oversub cases passed (${OVERSUB_CASES})" >> "$run_summary_file"
    fi
    log_info "[${cluster}][oversub] PASS"
  else
    if [[ "$OVERSUB_CASES" == "all" ]]; then
      printf "%s\t%s\t%s\n" "${cluster}-oversub" "FAIL" "one or more cann oversub cases failed" >> "$run_summary_file"
    else
      printf "%s\t%s\t%s\n" "${cluster}-oversub" "FAIL" "one or more selected cann oversub cases failed (${OVERSUB_CASES})" >> "$run_summary_file"
    fi
    log_error "[${cluster}][oversub] FAIL"
  fi

  return "$rc"
}

run_cluster_cann_oversub_perf() {
  local cluster="$1"
  local need_prepare="${2:-0}"
  local run_summary_file="${3:-$RUN_SUMMARY}"
  local cluster_log_dir="${LOG_ROOT}/${cluster}"
  local perf_dir="${cluster_log_dir}/oversub-perf"
  local case_results_tsv="${perf_dir}/results.tsv"
  local compare_tsv="${perf_dir}/compare.tsv"
  local rc=0
  local ran_cases=0
  mkdir -p "$perf_dir"

  if [[ "$cluster" != "cann" ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-oversub-perf" "SKIP" "oversub perf suite is only implemented for cann cluster" >> "$run_summary_file"
    return 0
  fi

  if [[ "$need_prepare" -eq 1 ]]; then
    prepare_cluster_stack "$cluster" "$cluster_log_dir"
  fi

  cleanup_oversub_pods "$cluster"
  printf "case_id\tstatus\taccess_mode\talloc_mode\ttarget_factor\ttotal_mem_bytes\ttarget_bytes\tallocated_bytes\talloc_ms\taccess_ms\ttotal_ms\tfail_ret\trunning_metric\tpeak_metric\tsummary\n" > "$case_results_tsv"

  if oversub_perf_case_enabled "cold-native"; then
    ran_cases=1
    log_info "[${cluster}][oversub-perf] case: cold-native"
    if ! run_cann_oversub_perf_case "$cluster" "$perf_dir" "$case_results_tsv" \
      "cann-oversub-perf-cold-native" "cold" "acl" "0" "${OVERSUB_PERF_BASE_FACTOR}" "0"; then
      rc=1
    fi
  fi

  if oversub_perf_case_enabled "cold-managed"; then
    ran_cases=1
    log_info "[${cluster}][oversub-perf] case: cold-managed"
    if ! run_cann_oversub_perf_case "$cluster" "$perf_dir" "$case_results_tsv" \
      "cann-oversub-perf-cold-managed" "cold" "managed" "1" "${OVERSUB_PERF_OVERSUB_FACTOR}" "1"; then
      rc=1
    fi
  fi

  if oversub_perf_case_enabled "hot-native"; then
    ran_cases=1
    log_info "[${cluster}][oversub-perf] case: hot-native"
    if ! run_cann_oversub_perf_case "$cluster" "$perf_dir" "$case_results_tsv" \
      "cann-oversub-perf-hot-native" "hot" "acl" "0" "${OVERSUB_PERF_BASE_FACTOR}" "0"; then
      rc=1
    fi
  fi

  if oversub_perf_case_enabled "hot-managed"; then
    ran_cases=1
    log_info "[${cluster}][oversub-perf] case: hot-managed"
    if ! run_cann_oversub_perf_case "$cluster" "$perf_dir" "$case_results_tsv" \
      "cann-oversub-perf-hot-managed" "hot" "managed" "1" "${OVERSUB_PERF_OVERSUB_FACTOR}" "1"; then
      rc=1
    fi
  fi

  if [[ "$ran_cases" -eq 0 ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-oversub-perf" "SKIP" "no oversub perf cases selected (XP_OVERSUB_PERF_CASES=${OVERSUB_PERF_CASES})" >> "$run_summary_file"
    log_warn "[${cluster}][oversub-perf] SKIP - no cases selected"
    return 0
  fi

  local cold_native_ms cold_managed_ms hot_native_ms hot_managed_ms
  cold_native_ms=$(awk -F'\t' '$1=="cann-oversub-perf-cold-native" && $2=="PASS"{print $11}' "$case_results_tsv" | tail -n1)
  cold_managed_ms=$(awk -F'\t' '$1=="cann-oversub-perf-cold-managed" && $2=="PASS"{print $11}' "$case_results_tsv" | tail -n1)
  hot_native_ms=$(awk -F'\t' '$1=="cann-oversub-perf-hot-native" && $2=="PASS"{print $11}' "$case_results_tsv" | tail -n1)
  hot_managed_ms=$(awk -F'\t' '$1=="cann-oversub-perf-hot-managed" && $2=="PASS"{print $11}' "$case_results_tsv" | tail -n1)

  local cold_ratio="NA"
  local hot_ratio="NA"
  if [[ "$cold_native_ms" =~ ^[0-9]+$ ]] && [[ "$cold_managed_ms" =~ ^[0-9]+$ ]]; then
    cold_ratio=$(awk -v b="$cold_native_ms" -v o="$cold_managed_ms" 'BEGIN { if (b > 0) printf "%.4f", o / b; else print "NA"; }')
  fi
  if [[ "$hot_native_ms" =~ ^[0-9]+$ ]] && [[ "$hot_managed_ms" =~ ^[0-9]+$ ]]; then
    hot_ratio=$(awk -v b="$hot_native_ms" -v o="$hot_managed_ms" 'BEGIN { if (b > 0) printf "%.4f", o / b; else print "NA"; }')
  fi

  {
    echo -e "cluster\tcold_native_ms\tcold_oversub_ms\tcold_ratio_oversub_vs_non\thot_native_ms\thot_oversub_ms\thot_ratio_oversub_vs_non"
    echo -e "${cluster}\t${cold_native_ms:-NA}\t${cold_managed_ms:-NA}\t${cold_ratio}\t${hot_native_ms:-NA}\t${hot_managed_ms:-NA}\t${hot_ratio}"
  } > "$compare_tsv"

  cleanup_oversub_pods "$cluster"

  local summary="cold_ratio=${cold_ratio},hot_ratio=${hot_ratio},base_factor=${OVERSUB_PERF_BASE_FACTOR},oversub_factor=${OVERSUB_PERF_OVERSUB_FACTOR},cases=${OVERSUB_PERF_CASES}"
  if [[ "$rc" -eq 0 ]]; then
    printf "%s\t%s\t%s\n" "${cluster}-oversub-perf" "PASS" "$summary" >> "$run_summary_file"
    log_info "[${cluster}][oversub-perf] PASS - ${summary}"
  else
    printf "%s\t%s\t%s\n" "${cluster}-oversub-perf" "FAIL" "$summary" >> "$run_summary_file"
    log_error "[${cluster}][oversub-perf] FAIL - ${summary}"
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

  if [[ "$cluster" == "cann" ]]; then
    local max_allocatable max_physical_allocatable required_devices min_required_devices
    max_allocatable="$(cluster_max_nvshare_allocatable "$cluster")"
    max_physical_allocatable="$(cluster_max_cann_physical_allocatable "$cluster")"
    min_required_devices="$(cann_min_physical_devices_for_perf "$PERF_CONCURRENT")"
    required_devices="$(required_physical_devices_for_concurrency "$PERF_CONCURRENT" "$NVSHARE_VIRTUAL_DEVICES" "$min_required_devices")"
    log_info "[${cluster}][perf] allocatable nvshare.com/gpu=${max_allocatable}, allocatable ${CANN_DEVICE_RESOURCE_KEY}=${max_physical_allocatable}, perf_concurrent=${PERF_CONCURRENT}, required_physical_npu=${required_devices}, min_policy_npu=${min_required_devices}"

    if [[ "$max_allocatable" =~ ^[0-9]+$ ]] && (( max_allocatable < PERF_CONCURRENT )); then
      local summary="insufficient allocatable nvshare.com/gpu=${max_allocatable}, need=${PERF_CONCURRENT}, required_physical_npu=${required_devices}"
      printf "%s\t%s\t%s\n" "${cluster}-perf" "FAIL" "$summary" >> "$run_summary_file"
      log_error "[${cluster}][perf] FAIL - ${summary}"
      log_error "[${cluster}][perf] hint: set XP_CANN_DEVICE_RESOURCE_COUNT>=${required_devices} and redeploy device-plugin"
      return 1
    fi
    if [[ "$max_physical_allocatable" =~ ^[0-9]+$ ]] && (( max_physical_allocatable < required_devices )); then
      local summary2="insufficient allocatable ${CANN_DEVICE_RESOURCE_KEY}=${max_physical_allocatable}, need_physical_npu=${required_devices} for perf_concurrent=${PERF_CONCURRENT}"
      printf "%s\t%s\t%s\n" "${cluster}-perf" "FAIL" "$summary2" >> "$run_summary_file"
      log_error "[${cluster}][perf] FAIL - ${summary2}"
      log_error "[${cluster}][perf] hint: set XP_CANN_DEVICE_RESOURCE_COUNT>=${required_devices} and redeploy device-plugin"
      return 1
    fi
  fi

  local results_tsv="${perf_dir}/results.tsv"
  local summary_tsv="${perf_dir}/summary.tsv"
  local compare_tsv="${perf_dir}/compare.tsv"
  printf "cluster\tmode\tround\tpod\tphase\twall_ms\tbench_ms\tstatus\treason\tnode_name\tgpu_binding\n" > "$results_tsv"

  kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod -l app=nvshare-remote-perf --ignore-not-found=true --wait=true || true

  local mode round
  local rc=0
  for mode in native nvshare; do
    for round in $(seq 1 "$PERF_ROUNDS"); do
      local pids=()
      local pod_names=()
      local pod_binding_files=()
      local t0=$(now_ms)
      
      local concurrent_count="$PERF_CONCURRENT"
      if [[ "$mode" == "native" ]]; then
        concurrent_count=1
      fi

      for i in $(seq 1 "$concurrent_count"); do
        local pod_name="nvshare-perf-${cluster}-${mode}-${round}-${i}"
        local pod_manifest="${perf_dir}/${pod_name}.yaml"
        local pod_binding_file="${perf_dir}/${pod_name}.binding.txt"
        render_perf_pod_manifest "$cluster" "$mode" "$pod_manifest" "$pod_name" "$round"
        kube "$cluster" apply -f "$pod_manifest"
        pod_names+=("$pod_name")
        pod_binding_files+=("$pod_binding_file")
      done

      local idx
      for idx in "${!pod_names[@]}"; do
        local pod_name_for_binding="${pod_names[$idx]}"
        local binding_file_for_pod="${pod_binding_files[$idx]}"
        if ! capture_perf_runtime_binding "$cluster" "$pod_name_for_binding" "$binding_file_for_pod" 180; then
          log_warn "[${cluster}][perf] failed to capture runtime binding for ${pod_name_for_binding}"
        fi
      done

      local wait_rc_all=0
      for pod_name in "${pod_names[@]}"; do
        wait_for_pod_terminal "$cluster" "$pod_name" "$PERF_TIMEOUT_SEC" &
        pids+=($!)
      done
      
      for pid in "${pids[@]}"; do
        wait "$pid" || wait_rc_all=$?
      done
      local t1=$(now_ms)

      for idx in "${!pod_names[@]}"; do
        local pod_name="${pod_names[$idx]}"
        local pod_binding_file="${pod_binding_files[$idx]}"
        local pod_log="${perf_dir}/${pod_name}.log"
        local pod_desc="${perf_dir}/${pod_name}.describe.txt"
        local wait_rc=0
        local phase wall_ms bench_ms status reason node_name gpu_binding

        phase=$(kube "$cluster" -n "$WORKLOAD_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [[ "$wait_rc_all" -ne 0 ]]; then wait_rc="$wait_rc_all"; fi
        wall_ms=$((t1 - t0))
        capture_pod_logs "$cluster" "$pod_name" "$pod_log" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
        capture_pod_describe "$cluster" "$pod_name" "$pod_desc" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
        bench_ms=$(extract_bench_ms "$pod_log")
        if [[ "$phase" == "Succeeded" ]] && [[ "$bench_ms" == "NA" ]] && rg -q "timeout_or_failure|Unable to connect to the server" "$pod_log"; then
          local retry_timeout=$((KUBECTL_CAPTURE_TIMEOUT_SEC * 3))
          log_warn "[${cluster}][perf] retry log capture for ${pod_name} (timeout=${retry_timeout}s)"
          capture_pod_logs "$cluster" "$pod_name" "$pod_log" "$retry_timeout" || true
          bench_ms=$(extract_bench_ms "$pod_log")
        fi
        node_name=$(extract_node_name_from_describe "$pod_desc")
        gpu_binding=$(extract_perf_binding "$pod_binding_file")

        local has_pass=0
        if grep -q "PASS" "$pod_log"; then
          has_pass=1
        fi

        status="PASS"
        reason="ok"
        if [[ "$wait_rc" -ne 0 ]]; then
          status="FAIL"
          reason="phase=${phase},wait_rc=${wait_rc}"
        elif [[ "$phase" != "Succeeded" ]] && [[ "$phase" != "NotFound" ]]; then
          status="FAIL"
          reason="phase=${phase},wait_rc=${wait_rc}"
        elif [[ "$has_pass" -ne 1 ]]; then
          status="FAIL"
          reason="PASS missing"
        elif [[ "$bench_ms" == "NA" ]]; then
          status="FAIL"
          reason="bench time missing"
        elif [[ "$phase" == "NotFound" ]]; then
          reason="phase=NotFound after terminal; accepted by PASS+bench"
        fi

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
          "$cluster" "$mode" "$round" "$pod_name" "$phase" "$wall_ms" "$bench_ms" "$status" "$reason" "$node_name" "$gpu_binding" >> "$results_tsv"

        kube "$cluster" -n "$WORKLOAD_NAMESPACE" delete pod "$pod_name" --ignore-not-found=true --wait=false || true

        if [[ "$status" != "PASS" ]]; then
          rc=1
        fi
      done
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
  kube_timed "$KUBECTL_CAPTURE_TIMEOUT_SEC" "$cluster" -n "$SYSTEM_NAMESPACE" logs -l name=nvshare-scheduler --timestamps > "${cluster_log_dir}/scheduler.log" 2>&1 || true
  kube_timed "$KUBECTL_CAPTURE_TIMEOUT_SEC" "$cluster" -n "$SYSTEM_NAMESPACE" logs -l name=nvshare-device-plugin --timestamps > "${cluster_log_dir}/device-plugin.log" 2>&1 || true
  capture_pod_logs "$cluster" "$pod_name" "${cluster_log_dir}/workload.log" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
  capture_pod_describe "$cluster" "$pod_name" "${cluster_log_dir}/workload.describe.txt" "$KUBECTL_CAPTURE_TIMEOUT_SEC" || true
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
      local proxy_health_norm=""
      proxy_health=$(kube "$cluster" get --raw "/api/v1/namespaces/${SYSTEM_NAMESPACE}/pods/${sched_pod}:9402/proxy/healthz" 2>>"$pf_log" || true)
      kube "$cluster" get --raw "/api/v1/namespaces/${SYSTEM_NAMESPACE}/pods/${sched_pod}:9402/proxy/metrics" > "${cluster_log_dir}/metrics.txt" 2>>"$pf_log" || true
      proxy_health_norm=$(printf '%s' "$proxy_health" | tr -d '\r[:space:]' | tr '[:upper:]' '[:lower:]')
      if [[ "$proxy_health_norm" == ok* ]]; then
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
  if [[ "$OVERSUB_PERF_ONLY" -eq 1 ]]; then
    if ! run_cluster_cann_oversub_perf "$cluster" 1 "$run_summary_file"; then
      cluster_rc=1
    fi
    return "$cluster_rc"
  fi

  if [[ "$OVERSUB_ONLY" -eq 1 ]]; then
    if ! run_cluster_cann_oversub "$cluster" 1 "$run_summary_file"; then
      cluster_rc=1
    fi
    return "$cluster_rc"
  fi

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

  if [[ "$OVERSUB_CHECK" -eq 1 ]]; then
    if [[ "$cluster" == "cann" ]]; then
      if [[ "$smoke_rc" -eq 0 || "$PERF_ONLY" -eq 1 ]]; then
        if ! run_cluster_cann_oversub "$cluster" 0 "$run_summary_file"; then
          cluster_rc=1
        fi
      else
        printf "%s\t%s\t%s\n" "${cluster}-oversub" "SKIP" "smoke failed, cann oversub suite skipped" >> "$run_summary_file"
        log_warn "[${cluster}][oversub] SKIP - smoke failed"
      fi
    else
      printf "%s\t%s\t%s\n" "${cluster}-oversub" "SKIP" "oversub suite is only implemented for cann cluster" >> "$run_summary_file"
    fi
  fi

  if [[ "$OVERSUB_PERF_CHECK" -eq 1 ]]; then
    if [[ "$cluster" == "cann" ]]; then
      if [[ "$smoke_rc" -eq 0 || "$PERF_ONLY" -eq 1 ]]; then
        if ! run_cluster_cann_oversub_perf "$cluster" 0 "$run_summary_file"; then
          cluster_rc=1
        fi
      else
        printf "%s\t%s\t%s\n" "${cluster}-oversub-perf" "SKIP" "smoke failed, cann oversub perf suite skipped" >> "$run_summary_file"
        log_warn "[${cluster}][oversub-perf] SKIP - smoke failed"
      fi
    else
      printf "%s\t%s\t%s\n" "${cluster}-oversub-perf" "SKIP" "oversub perf suite is only implemented for cann cluster" >> "$run_summary_file"
    fi
  fi

  return "$cluster_rc"
}

main() {
  local required_cann_devices
  local cann_min_devices
  cann_min_devices="$(cann_min_physical_devices_for_perf "$PERF_CONCURRENT")"
  required_cann_devices="$(required_physical_devices_for_concurrency "$PERF_CONCURRENT" "$NVSHARE_VIRTUAL_DEVICES" "$cann_min_devices")"
  if [[ "$PERF_BENCH" -eq 1 ]] && [[ "$required_cann_devices" =~ ^[0-9]+$ ]] && [[ "$required_cann_devices" -gt "$CANN_DEVICE_RESOURCE_COUNT" ]]; then
    log_warn "[cann] bump XP_CANN_DEVICE_RESOURCE_COUNT ${CANN_DEVICE_RESOURCE_COUNT} -> ${required_cann_devices} for perf_concurrent=${PERF_CONCURRENT} (virtual_devices_per_card=${NVSHARE_VIRTUAL_DEVICES}, min_policy_npu=${cann_min_devices})"
    CANN_DEVICE_RESOURCE_COUNT="${required_cann_devices}"
  fi

  log_info "run_id=${RUN_ID}"
  log_info "log_root=${LOG_ROOT}"
  log_info "clusters=${CLUSTERS[*]}"
  log_info "perf_bench=${PERF_BENCH} perf_only=${PERF_ONLY} perf_rounds=${PERF_ROUNDS}"
  log_info "perf_concurrent=${PERF_CONCURRENT} perf_debug=${PERF_DEBUG} perf_scheduling_mode=${PERF_SCHEDULING_MODE}"
  log_info "cann_perf_min_physical_npu_for_16=${CANN_PERF_MIN_PHYSICAL_NPU_FOR_16}"
  log_info "quota_check=${QUOTA_CHECK} quota_only=${QUOTA_ONLY}"
  log_info "oversub_check=${OVERSUB_CHECK} oversub_only=${OVERSUB_ONLY} oversub_cases=${OVERSUB_CASES}"
  log_info "oversub_chunk_mb=${OVERSUB_CHUNK_MB} oversub_target_factor=${OVERSUB_TARGET_FACTOR} oversub_max_alloc_gb=${OVERSUB_MAX_ALLOC_GB} oversub_hold_sec=${OVERSUB_HOLD_SEC}"
  log_info "oversub_perf_check=${OVERSUB_PERF_CHECK} oversub_perf_only=${OVERSUB_PERF_ONLY} oversub_perf_cases=${OVERSUB_PERF_CASES}"
  log_info "oversub_perf_base_factor=${OVERSUB_PERF_BASE_FACTOR} oversub_perf_oversub_factor=${OVERSUB_PERF_OVERSUB_FACTOR} oversub_perf_access_loops=${OVERSUB_PERF_ACCESS_LOOPS} oversub_perf_touch_mb=${OVERSUB_PERF_TOUCH_MB} oversub_perf_hold_sec=${OVERSUB_PERF_HOLD_SEC}"
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
