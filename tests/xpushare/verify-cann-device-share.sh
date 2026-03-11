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
  --image <name>         Container image on target node
                         (default: swr.cn-south-1.myhuaweicloud.com/ascendhub/cann:8.5.1-910b-ubuntu22.04-py3.11)
  --runtime <ctr|docker> Container runtime used for validation (default: ctr)
  --ctr-namespace <ns>   containerd namespace when runtime=ctr (default: k8s.io)
  --device-id <id>       Physical NPU ID used in npu-smi/device env (default: 0)
  --duration-sec <sec>   Per-container stress duration (default: 25)
  --buffer-mb <mb>       Device buffer size used by ACL memset workload (default: 256)
  --inner-ops <count>    Number of memset_async ops per loop (default: 200)
  --workdir <dir>        Remote output directory (default: /tmp/device-share-verify)
  -h, --help             Show this help

Notes:
  1) This script validates "same NPU shared by two containers" on one node.
  2) It runs two phases:
     - off: npu-smi set ... -d 0
     - on:  npu-smi set ... -d 1
  3) In each phase it launches two containers concurrently with
     ASCEND_VISIBLE_DEVICES=<device-id>, runs ACL memset_async load,
     and checks whether both PASS.
  4) For d=1, npu-smi requires confirmation; this script auto-confirms with "Y".
USAGE
}

NODE_SSH="${XP_DEVICE_SHARE_NODE_SSH:-${XPUSHARE_C2_NODE1_SSH:-ssh root@139.196.28.96 -p 32036}}"
IMAGE="${XP_DEVICE_SHARE_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/cann:8.5.1-910b-ubuntu22.04-py3.11}"
RUNTIME="${XP_DEVICE_SHARE_RUNTIME:-ctr}"
CTR_NAMESPACE="${XP_DEVICE_SHARE_CTR_NAMESPACE:-k8s.io}"
DEVICE_ID="0"
DURATION_SEC="25"
BUFFER_MB="256"
INNER_OPS="200"
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
    --runtime)
      RUNTIME="${2:-}"
      shift 2
      ;;
    --ctr-namespace)
      CTR_NAMESPACE="${2:-}"
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
    --buffer-mb)
      BUFFER_MB="${2:-}"
      shift 2
      ;;
    --inner-ops)
      INNER_OPS="${2:-}"
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

if ! [[ "$BUFFER_MB" =~ ^[0-9]+$ ]] || [ "$BUFFER_MB" -le 0 ]; then
  echo "--buffer-mb must be a positive integer" >&2
  exit 1
fi

if ! [[ "$INNER_OPS" =~ ^[0-9]+$ ]] || [ "$INNER_OPS" -le 0 ]; then
  echo "--inner-ops must be a positive integer" >&2
  exit 1
fi

if [ "$RUNTIME" != "ctr" ] && [ "$RUNTIME" != "docker" ]; then
  echo "--runtime must be one of: ctr, docker" >&2
  exit 1
fi

# shellcheck disable=SC2029
eval "$NODE_SSH \"IMAGE='$IMAGE' RUNTIME='$RUNTIME' CTR_NAMESPACE='$CTR_NAMESPACE' DEVICE_ID='$DEVICE_ID' DURATION_SEC='$DURATION_SEC' BUFFER_MB='$BUFFER_MB' INNER_OPS='$INNER_OPS' WORKDIR='$WORKDIR' bash -s\"" <<'REMOTE'
set -euo pipefail

IMAGE="${IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/cann:8.5.1-910b-ubuntu22.04-py3.11}"
RUNTIME="${RUNTIME:-ctr}"
CTR_NAMESPACE="${CTR_NAMESPACE:-k8s.io}"
DEVICE_ID="${DEVICE_ID:-0}"
DURATION_SEC="${DURATION_SEC:-25}"
BUFFER_MB="${BUFFER_MB:-256}"
INNER_OPS="${INNER_OPS:-200}"
WORKDIR="${WORKDIR:-/tmp/device-share-verify}"

mkdir -p "$WORKDIR"

if ! command -v npu-smi >/dev/null 2>&1; then
  echo "[ERR] npu-smi not found on target node" >&2
  exit 2
fi

if [ ! -e "/dev/davinci${DEVICE_ID}" ]; then
  echo "[ERR] /dev/davinci${DEVICE_ID} not found on target node" >&2
  exit 2
fi

if [ ! -d "/usr/local/Ascend/driver" ] || [ ! -d "/usr/local/dcmi" ]; then
  echo "[ERR] required host paths are missing: /usr/local/Ascend/driver or /usr/local/dcmi" >&2
  exit 2
fi

if [ "$RUNTIME" = "docker" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "[ERR] docker not found on target node" >&2
    exit 2
  fi
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[ERR] docker image not found on target node: $IMAGE" >&2
    exit 2
  fi
elif [ "$RUNTIME" = "ctr" ]; then
  if ! command -v ctr >/dev/null 2>&1; then
    echo "[ERR] ctr not found on target node" >&2
    exit 2
  fi
  if ! ctr -n "$CTR_NAMESPACE" images ls | awk '{print $1}' | grep -Fx "$IMAGE" >/dev/null 2>&1; then
    echo "[ERR] image not found in containerd namespace '$CTR_NAMESPACE': $IMAGE" >&2
    exit 2
  fi
else
  echo "[ERR] unsupported runtime: $RUNTIME" >&2
  exit 2
fi

cat > "$WORKDIR/workload.py" <<PY
import acl
import os
import sys
import time

size = int(os.getenv("BUF_MB", "${BUFFER_MB}")) * 1024 * 1024
duration = int(os.getenv("DURATION_SEC", "${DURATION_SEC}"))
inner = int(os.getenv("INNER_OPS", "${INNER_OPS}"))

print("ASCEND_VISIBLE_DEVICES", os.getenv("ASCEND_VISIBLE_DEVICES"), flush=True)
print("workload", "buf_mb", size // (1024 * 1024), "duration", duration, "inner_ops", inner, flush=True)

ret = acl.init()
print("init", ret, flush=True)
if ret != 0:
    raise SystemExit(10)

ret = acl.rt.set_device(0)
print("set_device", ret, flush=True)
if ret != 0:
    raise SystemExit(11)

ctx, ret = acl.rt.create_context(0)
print("create_context", ret, flush=True)
if ret != 0:
    raise SystemExit(12)

stream, ret = acl.rt.create_stream()
print("create_stream", ret, flush=True)
if ret != 0:
    raise SystemExit(13)

ptr, ret = acl.rt.malloc(size, 0)
print("malloc", ret, flush=True)
if ret != 0:
    raise SystemExit(14)

start = time.time()
loops = 0
while time.time() - start < duration:
    for _ in range(inner):
        ret = acl.rt.memset_async(ptr, size, loops % 256, size, stream)
        if ret != 0:
            print("memset_async_failed", ret, flush=True)
            raise SystemExit(15)
    ret = acl.rt.synchronize_stream(stream)
    if ret != 0:
        print("sync_failed", ret, flush=True)
        raise SystemExit(16)
    loops += 1
    if loops % 3 == 0:
        print("tick", loops, "elapsed", round(time.time() - start, 2), flush=True)

print("free", acl.rt.free(ptr), flush=True)
print("destroy_stream", acl.rt.destroy_stream(stream), flush=True)
print("destroy_context", acl.rt.destroy_context(ctx), flush=True)
print("reset_device", acl.rt.reset_device(0), flush=True)
print("finalize", acl.finalize(), flush=True)
print("PASS", "loops", loops, flush=True)
PY

cleanup_one() {
  local name="$1"
  if [ "$RUNTIME" = "docker" ]; then
    docker rm -f "$name" >/dev/null 2>&1 || true
  else
    ctr -n "$CTR_NAMESPACE" tasks rm -f "$name" >/dev/null 2>&1 || true
    ctr -n "$CTR_NAMESPACE" containers rm "$name" >/dev/null 2>&1 || true
  fi
}

run_one() {
  local name="$1"
  local logfile="$2"
  local timeout_sec=180
  local ld_lib="/usr/local/dcmi:/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver"

  if [ "$RUNTIME" = "docker" ]; then
    timeout "${timeout_sec}s" docker run --rm --name "$name" --privileged \
      --device "/dev/davinci${DEVICE_ID}" \
      --device /dev/davinci_manager \
      --device /dev/devmm_svm \
      --device /dev/hisi_hdc \
      -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
      -v /usr/local/dcmi:/usr/local/dcmi:ro \
      -v "$WORKDIR/workload.py:/tmp/workload.py:ro" \
      -e PYTHONUNBUFFERED=1 \
      -e "ASCEND_VISIBLE_DEVICES=${DEVICE_ID}" \
      -e "DURATION_SEC=${DURATION_SEC}" \
      -e "BUF_MB=${BUFFER_MB}" \
      -e "INNER_OPS=${INNER_OPS}" \
      -e "LD_LIBRARY_PATH=${ld_lib}" \
      "$IMAGE" /bin/bash -lc "python3 -u /tmp/workload.py" >"$logfile" 2>&1
  else
    timeout "${timeout_sec}s" ctr -n "$CTR_NAMESPACE" run --rm --privileged \
      --device "/dev/davinci${DEVICE_ID}" \
      --device /dev/davinci_manager \
      --device /dev/devmm_svm \
      --device /dev/hisi_hdc \
      --mount type=bind,src=/usr/local/Ascend/driver,dst=/usr/local/Ascend/driver,options=rbind:ro \
      --mount type=bind,src=/usr/local/dcmi,dst=/usr/local/dcmi,options=rbind:ro \
      --mount type=bind,src="$WORKDIR/workload.py",dst=/tmp/workload.py,options=rbind:ro \
      --env PYTHONUNBUFFERED=1 \
      --env "ASCEND_VISIBLE_DEVICES=${DEVICE_ID}" \
      --env "DURATION_SEC=${DURATION_SEC}" \
      --env "BUF_MB=${BUFFER_MB}" \
      --env "INNER_OPS=${INNER_OPS}" \
      --env "LD_LIBRARY_PATH=${ld_lib}" \
      "$IMAGE" "$name" /bin/bash -lc "python3 -u /tmp/workload.py" >"$logfile" 2>&1
  fi
}

run_pair() {
  local phase="$1"
  local name_a="ds-${phase}-a"
  local name_b="ds-${phase}-b"
  local loga="$WORKDIR/${phase}-a.log"
  local logb="$WORKDIR/${phase}-b.log"
  local rca rcb

  cleanup_one "$name_a"
  cleanup_one "$name_b"
  rm -f "$loga" "$logb"

  run_one "$name_a" "$loga" &
  local pida=$!

  sleep 2

  run_one "$name_b" "$logb" &
  local pidb=$!

  set +e
  wait "$pida"; rca=$?
  wait "$pidb"; rcb=$?
  set -e

  echo "phase=$phase rc_a=$rca rc_b=$rcb"
  echo "--- ${phase}-a tail ---"
  tail -n 120 "$loga" || true
  echo "--- ${phase}-b tail ---"
  tail -n 120 "$logb" || true

  if grep -q "PASS" "$loga" && grep -q "PASS" "$logb"; then
    echo "phase=$phase result=PASS"
    return 0
  fi

  echo "phase=$phase result=FAIL"
  return 1
}

echo "=== precheck: npu_bypass ==="
(lsmod | grep -w npu_bypass && echo "npu_bypass_present=1") || echo "npu_bypass_present=0"
echo "runtime=$RUNTIME image=$IMAGE device_id=$DEVICE_ID ctr_namespace=$CTR_NAMESPACE"

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
echo Y | npu-smi set -t device-share -i "$DEVICE_ID" -c 0 -d 1 >"$WORKDIR/set_d1.out" 2>&1
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
