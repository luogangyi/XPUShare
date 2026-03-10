#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash tests/xpushare/verify-cann-device-share.sh [options]

Options:
  --node-ssh <cmd>       SSH command to target NPU node,
                         default from XP_DEVICE_SHARE_NODE_SSH or XPUSHARE_C2_NODE1_SSH,
                         fallback: "ssh root@139.196.28.96 -p 32036"
  --image <name>         Docker image on target node (default: vllm-ascend:kvstore)
  --device-id <id>       Physical NPU ID used in npu-smi/device env (default: 0)
  --duration-sec <sec>   Per-container stress duration (default: 25)
  --workdir <dir>        Remote output directory (default: /tmp/device-share-verify)
  -h, --help             Show this help

Notes:
  1) This script validates "same NPU shared by two containers" on one node.
  2) It runs two phases:
     - off: npu-smi set ... -d 0
     - on:  npu-smi set ... -d 1
  3) In each phase it launches two Docker containers concurrently with
     ASCEND_VISIBLE_DEVICES=<device-id> and checks whether both PASS.
USAGE
}

NODE_SSH="${XP_DEVICE_SHARE_NODE_SSH:-${XPUSHARE_C2_NODE1_SSH:-ssh root@139.196.28.96 -p 32036}}"
IMAGE="vllm-ascend:kvstore"
DEVICE_ID="0"
DURATION_SEC="25"
WORKDIR="/tmp/device-share-verify"

while [ $# -gt 0 ]; do
  case "$1" in
    --node-ssh)
      NODE_SSH="${2:-}"
      shift 2
      ;;
    --image)
      IMAGE="${2:-}"
      shift 2
      ;;
    --device-id)
      DEVICE_ID="${2:-}"
      shift 2
      ;;
    --duration-sec)
      DURATION_SEC="${2:-}"
      shift 2
      ;;
    --workdir)
      WORKDIR="${2:-}"
      shift 2
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

if ! [[ "$DEVICE_ID" =~ ^[0-9]+$ ]]; then
  echo "--device-id must be an integer" >&2
  exit 1
fi

if ! [[ "$DURATION_SEC" =~ ^[0-9]+$ ]] || [ "$DURATION_SEC" -le 0 ]; then
  echo "--duration-sec must be a positive integer" >&2
  exit 1
fi

# shellcheck disable=SC2029
eval "$NODE_SSH \"IMAGE='$IMAGE' DEVICE_ID='$DEVICE_ID' DURATION_SEC='$DURATION_SEC' WORKDIR='$WORKDIR' bash -s\"" <<'REMOTE'
set -euo pipefail

IMAGE="${IMAGE:-vllm-ascend:kvstore}"
DEVICE_ID="${DEVICE_ID:-0}"
DURATION_SEC="${DURATION_SEC:-25}"
WORKDIR="${WORKDIR:-/tmp/device-share-verify}"

mkdir -p "$WORKDIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERR] docker not found on target node" >&2
  exit 2
fi

if ! command -v npu-smi >/dev/null 2>&1; then
  echo "[ERR] npu-smi not found on target node" >&2
  exit 2
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[ERR] image not found on target node: $IMAGE" >&2
  exit 2
fi

cat > "$WORKDIR/workload.py" <<PY
import os
import time
import torch
import torch_npu

print("ASCEND_VISIBLE_DEVICES", os.getenv("ASCEND_VISIBLE_DEVICES"), flush=True)
print("torch", torch.__version__, "torch_npu", torch_npu.__version__, flush=True)
print("is_available", torch.npu.is_available(), "device_count", torch.npu.device_count(), flush=True)
if not torch.npu.is_available() or torch.npu.device_count() < 1:
    raise SystemExit(3)

torch.npu.set_device(0)
n = 1024
x = torch.ones([n, n], dtype=torch.float32, device="npu:0")
y = torch.ones([n, n], dtype=torch.float32, device="npu:0")
t0 = time.time()
it = 0
while time.time() - t0 < ${DURATION_SEC}:
    z = torch.add(x, y)
    it += 1
    if it % 20 == 0:
        torch.npu.synchronize()
print("PASS", "iters", it, "elapsed", time.time() - t0, "sum", float(z[0][0].item()), flush=True)
PY

run_pair() {
  local phase="$1"
  local loga="$WORKDIR/${phase}-a.log"
  local logb="$WORKDIR/${phase}-b.log"
  local rca rcb
  rm -f "$loga" "$logb"
  docker rm -f "${phase}-a" "${phase}-b" >/dev/null 2>&1 || true

  docker run --rm --name "${phase}-a" -e "ASCEND_VISIBLE_DEVICES=${DEVICE_ID}" \
    -v "$WORKDIR/workload.py:/tmp/workload.py:ro" "$IMAGE" \
    /bin/bash -lc "python3 /tmp/workload.py" >"$loga" 2>&1 &
  local pida=$!

  sleep 2

  docker run --rm --name "${phase}-b" -e "ASCEND_VISIBLE_DEVICES=${DEVICE_ID}" \
    -v "$WORKDIR/workload.py:/tmp/workload.py:ro" "$IMAGE" \
    /bin/bash -lc "python3 /tmp/workload.py" >"$logb" 2>&1 &
  local pidb=$!

  set +e
  wait "$pida"; rca=$?
  wait "$pidb"; rcb=$?
  set -e

  echo "phase=$phase rc_a=$rca rc_b=$rcb"
  echo "--- ${phase}-a tail ---"
  tail -n 40 "$loga" || true
  echo "--- ${phase}-b tail ---"
  tail -n 40 "$logb" || true

  if grep -q "PASS" "$loga" && grep -q "PASS" "$logb"; then
    echo "phase=$phase result=PASS"
    return 0
  fi

  echo "phase=$phase result=FAIL"
  return 1
}

echo "=== precheck: npu_bypass ==="
(lsmod | grep -w npu_bypass && echo "npu_bypass_present=1") || echo "npu_bypass_present=0"

echo "=== set device-share d=0 ==="
set +e
npu-smi set -t device-share -i "$DEVICE_ID" -c 0 -d 0 >"$WORKDIR/set_d0.out" 2>&1
rc_d0=$?
set -e
echo "set_d0_rc=$rc_d0"
cat "$WORKDIR/set_d0.out"

if run_pair off; then
  off_ok=0
else
  off_ok=1
fi

echo "=== set device-share d=1 ==="
set +e
npu-smi set -t device-share -i "$DEVICE_ID" -c 0 -d 1 >"$WORKDIR/set_d1.out" 2>&1
rc_d1=$?
set -e
echo "set_d1_rc=$rc_d1"
cat "$WORKDIR/set_d1.out"

if run_pair on; then
  on_ok=0
else
  on_ok=1
fi

echo "=== classification ==="
if [ "$off_ok" -ne 0 ] && [ "$on_ok" -eq 0 ]; then
  echo "RESULT=device-share-effective"
elif [ "$off_ok" -ne 0 ] && [ "$on_ok" -ne 0 ]; then
  if grep -q "does not support setting device-share" "$WORKDIR/set_d1.out"; then
    echo "RESULT=device-share-unsupported"
  else
    echo "RESULT=still-blocked-after-enable"
  fi
elif [ "$off_ok" -eq 0 ] && [ "$on_ok" -eq 0 ]; then
  echo "RESULT=already-shareable-without-toggle"
else
  echo "RESULT=inconclusive"
fi

echo "=== output-dir ==="
echo "$WORKDIR"
ls -l "$WORKDIR"
REMOTE
