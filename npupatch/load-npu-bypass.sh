#!/bin/sh
# load-npu-bypass.sh — Init script for the nvshare device-plugin DaemonSet.
#
# Checks kernel prerequisites, then loads npu_bypass.ko with strict validation.
# Exit 0 → device-plugin containers proceed.
# Exit 1 → pod stays in Init:Error with a clear reason.
#
# Environment:
#   RUNTIME_BACKEND               — "ascend" or "cuda" (default: auto-detect)
#   DAVINCI_MAJOR                 — major number for /dev/davinci* (default: 235)
#   NPU_BYPASS_SRC                — source dir (default: /opt/npupatch/npu_bypass)
#   NPU_BYPASS_PREBUILT           — image prebuilt .ko (default: /opt/npupatch/npu_bypass.ko)
#   NPU_BYPASS_HOST_MODULE        — host preferred .ko (default: /lib/modules/$(uname -r)/updates/npu_bypass.ko)
#   NPU_BYPASS_EXPECT_SRCVERSION  — optional hard expected loaded srcversion
#   NPU_BYPASS_REQUIRE_7HOOK      — 1 to require 7-hook dmesg signature (default: 1)
#   NPU_BYPASS_RMMOD_RETRIES      — retries when unloading stale module (default: 5)

set -e

DAVINCI_MAJOR="${DAVINCI_MAJOR:-235}"
NPU_BYPASS_SRC="${NPU_BYPASS_SRC:-/opt/npupatch/npu_bypass}"
NPU_BYPASS_PREBUILT="${NPU_BYPASS_PREBUILT:-/opt/npupatch/npu_bypass.ko}"
NPU_BYPASS_EXPECT_SRCVERSION="${NPU_BYPASS_EXPECT_SRCVERSION:-}"
NPU_BYPASS_REQUIRE_7HOOK="${NPU_BYPASS_REQUIRE_7HOOK:-1}"
NPU_BYPASS_RMMOD_RETRIES="${NPU_BYPASS_RMMOD_RETRIES:-5}"

SELECTED_MODULE=""
SELECTED_SRCVERSION=""
PREFERRED_SRCVERSION=""

log() { echo "[npu-bypass-init] $*"; }
die() { echo "[npu-bypass-init] ERROR: $*" >&2; exit 1; }

detect_backend() {
  if [ -n "${RUNTIME_BACKEND:-}" ]; then
    echo "$RUNTIME_BACKEND"
    return
  fi
  for var in ASCEND_VISIBLE_DEVICES NPU_VISIBLE_DEVICES ASCEND_RT_VISIBLE_DEVICES; do
    eval val="\${$var:-}"
    if [ -n "$val" ]; then
      echo "ascend"
      return
    fi
  done
  echo "cuda"
}

module_srcversion() {
  modinfo "$1" 2>/dev/null | awk '/^srcversion:/ {print $2; exit}'
}

module_vermagic() {
  modinfo "$1" 2>/dev/null | awk '/^vermagic:/ {print $2; exit}'
}

module_has_required_symbols() {
  module_file="$1"
  strings "$module_file" 2>/dev/null | grep -q "uda_task_can_access_udevid" || return 1
  strings "$module_file" 2>/dev/null | grep -q "uda_devcgroup_permission_allow" || return 1
  strings "$module_file" 2>/dev/null | grep -q "NPU container isolation bypass ACTIVE (%d hooks" || return 1
  return 0
}

capture_npu_dmesg() {
  dmesg 2>/dev/null | grep "npu_bypass" | tail -80 || true
}

verify_hook_signature() {
  if [ "$NPU_BYPASS_REQUIRE_7HOOK" != "1" ]; then
    return 0
  fi
  npu_dmesg="$(capture_npu_dmesg)"
  last_active="$(echo "$npu_dmesg" | grep "ACTIVE (" | tail -n1 || true)"
  echo "$last_active" | grep -q "ACTIVE (7 hooks, cgroup-scan)" || return 1

  last_boot_line="$(echo "$npu_dmesg" | nl -ba | grep "davinci_major=" | tail -n1 | awk '{print $1}' || true)"
  if [ -n "$last_boot_line" ]; then
    boot_block="$(echo "$npu_dmesg" | tail -n +"$last_boot_line")"
  else
    boot_block="$npu_dmesg"
  fi
  echo "$boot_block" | grep -q "hooked uda_task_can_access_udevid" || return 1
  echo "$boot_block" | grep -q "hooked uda_devcgroup_permission_allow" || return 1
  return 0
}

loaded_module_srcversion() {
  cat /sys/module/npu_bypass/srcversion 2>/dev/null || true
}

ensure_unloaded() {
  if ! lsmod | grep -qw npu_bypass; then
    return 0
  fi
  retry=0
  while lsmod | grep -qw npu_bypass; do
    rmmod npu_bypass 2>/dev/null || true
    retry=$((retry + 1))
    if [ "$retry" -ge "$NPU_BYPASS_RMMOD_RETRIES" ]; then
      break
    fi
    sleep 1
  done
  lsmod | grep -qw npu_bypass && die "failed to unload stale npu_bypass module"
}

is_loaded_module_acceptable() {
  if ! lsmod | grep -qw npu_bypass; then
    return 1
  fi

  loaded_src="$(loaded_module_srcversion)"
  if [ -z "$loaded_src" ]; then
    log "loaded module has empty srcversion, will reload"
    return 1
  fi
  log "loaded npu_bypass srcversion=$loaded_src"

  if [ -n "$NPU_BYPASS_EXPECT_SRCVERSION" ] && [ "$loaded_src" != "$NPU_BYPASS_EXPECT_SRCVERSION" ]; then
    log "loaded srcversion($loaded_src) != expected($NPU_BYPASS_EXPECT_SRCVERSION), will reload"
    return 1
  fi

  if [ -n "$PREFERRED_SRCVERSION" ] && [ "$loaded_src" != "$PREFERRED_SRCVERSION" ]; then
    log "loaded srcversion($loaded_src) != preferred($PREFERRED_SRCVERSION), will reload"
    return 1
  fi

  if ! verify_hook_signature; then
    log "loaded module missing required 7-hook signature in dmesg, will reload"
    return 1
  fi

  return 0
}

verify_loaded_module() {
  lsmod | grep -qw npu_bypass || die "npu_bypass module not found after load attempt"

  loaded_src="$(loaded_module_srcversion)"
  log "active npu_bypass srcversion=$loaded_src"

  if [ -n "$SELECTED_SRCVERSION" ] && [ "$loaded_src" != "$SELECTED_SRCVERSION" ]; then
    die "loaded srcversion($loaded_src) != selected module srcversion($SELECTED_SRCVERSION)"
  fi
  if [ -n "$NPU_BYPASS_EXPECT_SRCVERSION" ] && [ "$loaded_src" != "$NPU_BYPASS_EXPECT_SRCVERSION" ]; then
    die "loaded srcversion($loaded_src) != expected($NPU_BYPASS_EXPECT_SRCVERSION)"
  fi

  if ! verify_hook_signature; then
    log "recent npu_bypass dmesg:"
    capture_npu_dmesg
    die "npu_bypass 7-hook signature check failed"
  fi

  log "VERIFIED: npu_bypass module loaded and validated"
  capture_npu_dmesg
}

try_load_module() {
  module_file="$1"
  module_label="$2"
  if [ ! -f "$module_file" ]; then
    log "no ${module_label} module at ${module_file}"
    return 1
  fi

  vermagic="$(module_vermagic "$module_file")"
  if [ "$vermagic" != "$KVER" ]; then
    log "${module_label} vermagic(${vermagic:-unknown}) != running kernel(${KVER}), skip"
    return 1
  fi

  if ! module_has_required_symbols "$module_file"; then
    log "${module_label} module missing required symbols for 7-hook mode, skip"
    return 1
  fi

  module_src="$(module_srcversion "$module_file")"
  log "loading ${module_label} module: ${module_file} (srcversion=${module_src:-unknown})"
  if ! insmod "$module_file" davinci_major="$DAVINCI_MAJOR" 2>&1; then
    log "WARNING: ${module_label} insmod failed"
    return 1
  fi

  SELECTED_MODULE="$module_file"
  SELECTED_SRCVERSION="$module_src"
  return 0
}

build_and_load() {
  if [ "$HAS_HEADERS" -ne 1 ]; then
    die "kernel headers not available at $KBUILD — cannot build npu_bypass.ko"
  fi
  [ -f "${NPU_BYPASS_SRC}/Makefile" ] || die "npu_bypass source not found at ${NPU_BYPASS_SRC}/Makefile"
  command -v make >/dev/null 2>&1 || die "'make' is not installed in image"

  log "building npu_bypass.ko from source for kernel $KVER ..."
  cd "$NPU_BYPASS_SRC"
  make clean 2>/dev/null || true
  make KDIR="$KBUILD" >/tmp/npu-bypass-build.log 2>&1 || {
    cat /tmp/npu-bypass-build.log >&2
    die "npu_bypass.ko build failed"
  }
  [ -f "${NPU_BYPASS_SRC}/npu_bypass.ko" ] || die "build completed but npu_bypass.ko not found"

  if ! module_has_required_symbols "${NPU_BYPASS_SRC}/npu_bypass.ko"; then
    die "built npu_bypass.ko missing required symbols for 7-hook mode"
  fi

  module_src="$(module_srcversion "${NPU_BYPASS_SRC}/npu_bypass.ko")"
  log "loading built module from source (srcversion=${module_src:-unknown})"
  insmod "${NPU_BYPASS_SRC}/npu_bypass.ko" davinci_major="$DAVINCI_MAJOR" 2>&1 || {
    die "insmod built npu_bypass.ko failed"
  }
  SELECTED_MODULE="${NPU_BYPASS_SRC}/npu_bypass.ko"
  SELECTED_SRCVERSION="$module_src"
}

BACKEND="$(detect_backend)"
log "runtime backend=$BACKEND"
if [ "$BACKEND" != "ascend" ]; then
  log "not an Ascend node, skipping npu_bypass module loading"
  exit 0
fi

KVER="$(uname -r)"
KBUILD="/lib/modules/${KVER}/build"
HOST_MODULE_DEFAULT="/lib/modules/${KVER}/updates/npu_bypass.ko"
NPU_BYPASS_HOST_MODULE="${NPU_BYPASS_HOST_MODULE:-$HOST_MODULE_DEFAULT}"
log "kernel version: $KVER"
log "preferred host module path: $NPU_BYPASS_HOST_MODULE"

HAS_HEADERS=0
if [ -d "$KBUILD" ]; then
  HAS_HEADERS=1
  log "kernel headers found at $KBUILD"
else
  log "WARNING: kernel headers not found at $KBUILD — build fallback disabled"
fi

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
[ -z "$MISSING" ] || die "required Ascend symbols missing in /proc/kallsyms:$MISSING"
log "all required driver symbols present in kernel"

if [ ! -d /sys/kernel/debug/kprobes ] && [ ! -f /proc/sys/debug/kprobes-optimization ]; then
  if [ -f "/boot/config-${KVER}" ] && ! grep -q "CONFIG_KPROBES=y" "/boot/config-${KVER}"; then
    die "kernel missing CONFIG_KPROBES=y, cannot enable npu_bypass"
  fi
  log "WARNING: could not confirm kprobes support; attempting load anyway"
fi

if [ -f "$NPU_BYPASS_HOST_MODULE" ]; then
  PREFERRED_SRCVERSION="$(module_srcversion "$NPU_BYPASS_HOST_MODULE")"
elif [ -f "$NPU_BYPASS_PREBUILT" ]; then
  PREFERRED_SRCVERSION="$(module_srcversion "$NPU_BYPASS_PREBUILT")"
fi

if lsmod | grep -qw npu_bypass; then
  if is_loaded_module_acceptable; then
    log "npu_bypass already loaded and validated, nothing to do"
    exit 0
  fi
  log "reloading stale/incompatible npu_bypass module"
  ensure_unloaded
fi

if try_load_module "$NPU_BYPASS_HOST_MODULE" "host-updates"; then
  :
elif try_load_module "$NPU_BYPASS_PREBUILT" "image-prebuilt"; then
  :
else
  build_and_load
fi

verify_loaded_module
exit 0
