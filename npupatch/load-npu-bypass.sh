#!/bin/sh
# load-npu-bypass.sh — Init script for the nvshare device-plugin DaemonSet.
#
# Checks kernel prerequisites, builds/loads npu_bypass.ko, then exits.
# Exit 0 → device-plugin containers proceed.
# Exit 1 → pod stays in Init:Error with a clear message.
#
# Environment:
#   RUNTIME_BACKEND  — "ascend" or "cuda" (default: auto-detect)
#   DAVINCI_MAJOR    — major device number for /dev/davinci* (default: 235)
#   NPU_BYPASS_SRC   — path to npu_bypass source dir (default: /opt/npupatch/npu_bypass)
#   NPU_BYPASS_PREBUILT — path to prebuilt .ko (default: /opt/npupatch/npu_bypass.ko)

set -e

DAVINCI_MAJOR="${DAVINCI_MAJOR:-235}"
NPU_BYPASS_SRC="${NPU_BYPASS_SRC:-/opt/npupatch/npu_bypass}"
NPU_BYPASS_PREBUILT="${NPU_BYPASS_PREBUILT:-/opt/npupatch/npu_bypass.ko}"

log()  { echo "[npu-bypass-init] $*"; }
die()  { echo "[npu-bypass-init] ERROR: $*" >&2; exit 1; }

# ── 1. Detect runtime backend ──────────────────────────────────────
detect_backend() {
  if [ -n "$RUNTIME_BACKEND" ]; then
    echo "$RUNTIME_BACKEND"
    return
  fi
  # Auto-detect: if any Ascend visible-device env is set, it's ascend
  for var in ASCEND_VISIBLE_DEVICES NPU_VISIBLE_DEVICES ASCEND_RT_VISIBLE_DEVICES; do
    eval val="\${$var:-}"
    if [ -n "$val" ]; then
      echo "ascend"
      return
    fi
  done
  echo "cuda"
}

BACKEND=$(detect_backend)
log "runtime backend=$BACKEND"

if [ "$BACKEND" != "ascend" ]; then
  log "not an Ascend node, skipping npu_bypass module loading"
  exit 0
fi

# ── 2. Check if module is already loaded ───────────────────────────
if lsmod | grep -qw npu_bypass; then
  log "npu_bypass module already loaded, nothing to do"
  exit 0
fi

# ── 3. Check kernel headers ────────────────────────────────────────
KVER=$(uname -r)
KBUILD="/lib/modules/${KVER}/build"
log "kernel version: $KVER"

HAS_HEADERS=0
if [ -d "$KBUILD" ]; then
  HAS_HEADERS=1
  log "kernel headers found at $KBUILD"
else
  log "WARNING: kernel headers not found at $KBUILD — will try prebuilt module only"
fi

# ── 4. Check required symbols in /proc/kallsyms ───────────────────
REQUIRED_SYMBOLS="
  uda_can_access_udevid
  uda_proc_can_access_udevid
  uda_occupy_dev_by_ns
  uda_ns_node_devid_to_udevid
  devdrv_manager_container_logical_id_to_physical_id
"

MISSING=""
for sym in $REQUIRED_SYMBOLS; do
  if ! grep -qw "$sym" /proc/kallsyms 2>/dev/null; then
    MISSING="$MISSING $sym"
  fi
done

if [ -n "$MISSING" ]; then
  die "required Ascend driver symbols not found in /proc/kallsyms:$MISSING — is the CANN driver loaded? Cannot enable NPU virtualization."
fi
log "all required driver symbols present in kernel"

# ── 5. Check kprobes support ──────────────────────────────────────
if [ ! -d /sys/kernel/debug/kprobes ] && [ ! -f /proc/sys/debug/kprobes-optimization ]; then
  # Additional check: try the config
  if [ -f "/boot/config-${KVER}" ]; then
    if ! grep -q "CONFIG_KPROBES=y" "/boot/config-${KVER}"; then
      die "kernel does not have kprobes support (CONFIG_KPROBES=y not set). Cannot load npu_bypass module."
    fi
  fi
  # If we can't determine, warn but continue — insmod will fail if truly unsupported
  log "WARNING: could not confirm kprobes support; will attempt module load anyway"
fi

# ── 6. Try prebuilt module first ──────────────────────────────────
try_prebuilt() {
  if [ ! -f "$NPU_BYPASS_PREBUILT" ]; then
    log "no prebuilt module at $NPU_BYPASS_PREBUILT"
    return 1
  fi

  # Check vermagic match
  PREBUILT_VERMAGIC=$(modinfo "$NPU_BYPASS_PREBUILT" 2>/dev/null | grep -i vermagic | awk '{print $2}')
  if [ "$PREBUILT_VERMAGIC" = "$KVER" ]; then
    log "prebuilt module vermagic ($PREBUILT_VERMAGIC) matches running kernel"
    if insmod "$NPU_BYPASS_PREBUILT" davinci_major="$DAVINCI_MAJOR" 2>&1; then
      log "prebuilt module loaded successfully"
      return 0
    else
      log "WARNING: prebuilt insmod failed, will try build from source"
      return 1
    fi
  else
    log "prebuilt vermagic ($PREBUILT_VERMAGIC) does not match kernel ($KVER), skipping"
    return 1
  fi
}

# ── 7. Build from source ─────────────────────────────────────────
build_and_load() {
  if [ "$HAS_HEADERS" -ne 1 ]; then
    die "kernel headers not available at $KBUILD — cannot build npu_bypass.ko. Install kernel-devel for $KVER or provide a prebuilt module matching this kernel."
  fi

  if [ ! -f "${NPU_BYPASS_SRC}/Makefile" ]; then
    die "npu_bypass source not found at ${NPU_BYPASS_SRC}/Makefile"
  fi

  if ! command -v make >/dev/null 2>&1; then
    die "'make' is not installed in this image. Cannot build npu_bypass.ko from source."
  fi

  log "building npu_bypass.ko from source for kernel $KVER ..."
  cd "$NPU_BYPASS_SRC"
  make clean 2>/dev/null || true
  if ! make KDIR="$KBUILD" 2>&1; then
    die "npu_bypass.ko build failed. Check kernel headers and compiler availability."
  fi

  if [ ! -f "${NPU_BYPASS_SRC}/npu_bypass.ko" ]; then
    die "build completed but npu_bypass.ko not found"
  fi

  log "loading freshly built npu_bypass.ko ..."
  if ! insmod "${NPU_BYPASS_SRC}/npu_bypass.ko" davinci_major="$DAVINCI_MAJOR" 2>&1; then
    die "insmod npu_bypass.ko failed after successful build"
  fi

  log "npu_bypass.ko built and loaded successfully"
}

# ── 8. Main flow: try prebuilt, fallback to build ─────────────────
if try_prebuilt; then
  :
else
  build_and_load
fi

# ── 9. Verify ────────────────────────────────────────────────────
if lsmod | grep -qw npu_bypass; then
  log "VERIFIED: npu_bypass module loaded — NPU container isolation bypass ACTIVE"
  # Show dmesg hook info (best-effort, may need permissions)
  dmesg 2>/dev/null | grep 'npu_bypass' | tail -20 || true
  exit 0
else
  die "npu_bypass module not found in lsmod after load attempt"
fi
