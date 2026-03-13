#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash tests/xpushare/verify-aclrt-timeout-ab.sh [options]

Options:
  --kubeconfig <path>   kubeconfig path (default: $KUBECONFIG)
  --namespace <ns>      namespace (default: default)
  --node <name>         target node (default: kcs-lihao-serving-test01-s-wz97b)
  --image <name>        test image (default: XP_IMAGE_PYTORCH_ADD_NPU or local cann image)
  --n <size>            matrix size n (default: 76000)
  --timeout <sec>       per-case timeout seconds (default: 900)
  --keep-pods           keep pods after run
  -h, --help            show help

This script runs 3 A/B cases with the same torch_npu workload:
  1) xpushare + hook=1 + oversub
  2) xpushare + hook=0 (passthrough) + oversub
  3) native huawei.com/Ascend910

It prints a concise verdict of whether 507015/AclrtSynchronizeDeviceWithTimeout
only appears when xpushare managed oversub is active.
USAGE
}

NAMESPACE="default"
TARGET_NODE="kcs-lihao-serving-test01-s-wz97b"
IMAGE="${XP_IMAGE_PYTORCH_ADD_NPU:-docker.io/local/ascendhub-cann:8.5.1-pt2.9.0-npu2.9.0}"
N_SIZE="76000"
TIMEOUT_SEC="900"
KEEP_PODS="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig)
      export KUBECONFIG="${2:-}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --node)
      TARGET_NODE="${2:-}"
      shift 2
      ;;
    --image)
      IMAGE="${2:-}"
      shift 2
      ;;
    --n)
      N_SIZE="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SEC="${2:-}"
      shift 2
      ;;
    --keep-pods)
      KEEP_PODS="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "${KUBECONFIG:-}" ]; then
  echo "KUBECONFIG is empty. Use --kubeconfig or export KUBECONFIG." >&2
  exit 1
fi

if ! [[ "$N_SIZE" =~ ^[0-9]+$ ]]; then
  echo "--n must be an integer" >&2
  exit 1
fi

if ! [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [ "$TIMEOUT_SEC" -le 0 ]; then
  echo "--timeout must be a positive integer" >&2
  exit 1
fi

pod_phase() {
  local pod="$1"
  kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

wait_terminal() {
  local pod="$1"
  local deadline
  local now
  local phase
  deadline=$(( $(date +%s) + TIMEOUT_SEC ))
  while true; do
    phase="$(pod_phase "$pod")"
    case "$phase" in
      Succeeded|Failed)
        echo "$phase"
        return 0
        ;;
    esac
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "Timeout"
      return 0
    fi
    sleep 5
  done
}

render_pod_yaml() {
  local pod="$1"
  local resource_key="$2"
  local hook_flag="$3"
  local client_flag="$4"
  local oversub_flag="$5"

  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
spec:
  restartPolicy: Never
  nodeName: ${TARGET_NODE}
  containers:
  - name: test
    image: ${IMAGE}
    env:
YAML

  if [ -n "$hook_flag" ]; then
    cat <<YAML
    - name: XPUSHARE_NPU_ENABLE_HOOK
      value: "${hook_flag}"
YAML
  fi

  if [ -n "$client_flag" ]; then
    cat <<YAML
    - name: XPUSHARE_NPU_ENABLE_CLIENT
      value: "${client_flag}"
YAML
  fi

  if [ "$oversub_flag" = "1" ]; then
    cat <<YAML
    - name: XPUSHARE_ENABLE_SINGLE_OVERSUB
      value: "1"
YAML
  fi

  cat <<YAML
    command:
    - python3
    - -u
    - -c
    - |
      import time
      import traceback
      import torch
      import torch_npu

      n = ${N_SIZE}
      print("N=", n, flush=True)
      torch.npu.set_device("npu:0")
      t0 = time.time()
      try:
          x = torch.ones([n, n], dtype=torch.float32).npu()
          y = torch.ones([n, n], dtype=torch.float32).npu()
          z = x + y
          torch.npu.synchronize()
          print("PASS", flush=True)
      except Exception as e:
          print("EXCEPTION", repr(e), flush=True)
          traceback.print_exc()
          raise
      finally:
          print("ELAPSED_SEC", time.time() - t0, flush=True)
    resources:
      limits:
        ${resource_key}: 1
YAML
}

run_case() {
  local case_id="$1"
  local pod="$2"
  local resource_key="$3"
  local hook_flag="$4"
  local client_flag="$5"
  local oversub_flag="$6"

  kubectl -n "$NAMESPACE" delete pod "$pod" --ignore-not-found=true >/dev/null 2>&1 || true
  render_pod_yaml "$pod" "$resource_key" "$hook_flag" "$client_flag" "$oversub_flag" | \
    kubectl -n "$NAMESPACE" apply -f - >/dev/null

  local phase
  phase="$(wait_terminal "$pod")"
  local log_path="/tmp/${pod}.log"
  kubectl -n "$NAMESPACE" logs "$pod" >"$log_path" 2>&1 || true

  local has_507015="0"
  local has_oom="0"
  local has_pass="0"
  if grep -Eq "AclrtSynchronizeDeviceWithTimeout|error code is 507015|aicore execution is abnormal" "$log_path"; then
    has_507015="1"
  fi
  if grep -Eq "NPU out of memory|OutOfMemory|CUDA_ERROR_OUT_OF_MEMORY|Memory allocation rejected" "$log_path"; then
    has_oom="1"
  fi
  if grep -Eq "^PASS$" "$log_path"; then
    has_pass="1"
  fi

  printf "%s\t%s\t%s\t%s\t%s\n" "$case_id" "$phase" "$has_pass" "$has_507015" "$has_oom"
}

pods=("xp-ab-hook1" "xp-ab-hook0" "xp-ab-native")

echo "Running on node=${TARGET_NODE} image=${IMAGE} n=${N_SIZE}"
echo "case_id phase pass has_507015 has_oom"
run_case "xpushare-hook1" "xp-ab-hook1" "xpushare.com/gpu" "1" "1" "1"
run_case "xpushare-hook0" "xp-ab-hook0" "xpushare.com/gpu" "0" "0" "1"
run_case "native" "xp-ab-native" "huawei.com/Ascend910" "" "" "0"

if [ "$KEEP_PODS" != "1" ]; then
  for p in "${pods[@]}"; do
    kubectl -n "$NAMESPACE" delete pod "$p" --ignore-not-found=true >/dev/null 2>&1 || true
  done
fi
