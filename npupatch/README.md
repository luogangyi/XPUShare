# NPU Bypass Patch Bundle

This directory contains the nvshare NPU bypass source bundle, patch, prebuilt
kernel module, and usage instructions.

## Files

- `0001-npu-bypass-v7-cgroup-scan-and-hook-fixes.patch`
  - Patch exported from:
    - `/Users/luogangyi/Code/cann/driver/src/npu_bypass/npu_bypass.c`
- `npu_bypass/`
  - Full source directory, directly buildable on Linux target nodes.
  - Contains:
    - `npu_bypass/Makefile`
    - `npu_bypass/npu_bypass.c`
- `npu_bypass.ko`
  - Prebuilt module copy (same content as the versioned file below).
- `npu_bypass-kcs-4.19.90-2107.6.0.0251.43.oe1.bclinux.aarch64.ko`
  - Prebuilt module for a specific kernel/arch.
- `PREBUILT_MODULE_INFO.txt`
  - Hash and module metadata for verification.

## Build From Source

Yes, `npu_bypass/` is directly buildable, but only on a Linux host with the
matching kernel headers.

Build on the target Linux node (recommended):

```bash
cd /Users/luogangyi/Code/nvshare/npupatch/npu_bypass
make clean
make
```

Expected output file:

```bash
/Users/luogangyi/Code/nvshare/npupatch/npu_bypass/npu_bypass.ko
```

Build prerequisites:

- Linux kernel headers for current running kernel are installed.
- `/lib/modules/$(uname -r)/build` exists.
- Kernel has `kprobes` support enabled.
- Root privileges for loading kernel modules.

## Source Portability (Across Kernel Versions)

`npu_bypass.c` itself is not tied to one fixed kernel version.
In most cases, you can compile it on other kernel versions as long as these
conditions are met:

1. Target architecture is `aarch64` (current code reads function args/ret via
   `pt_regs.regs[]`).
2. Kernel module build environment is available (`/lib/modules/$(uname -r)/build`).
3. Kernel supports kprobes/kretprobes.
4. Runtime symbol lookup is available for:
   - `kallsyms_lookup_name`
   - `__devcgroup_check_permission`
5. Driver symbols to be hooked exist in the running driver (for runtime):
   - `uda_can_access_udevid`
   - `uda_task_can_access_udevid`
   - `uda_proc_can_access_udevid`
   - `uda_occupy_dev_by_ns`
   - `uda_devcgroup_permission_allow`
   - `uda_ns_node_devid_to_udevid`
   - `devdrv_manager_container_logical_id_to_physical_id`

Important:

- Source compilation is generally portable.
- Prebuilt `.ko` is NOT portable across kernel versions.
- If a new kernel/driver changes internal symbol names or calling conventions,
  code updates may be required even though the module still compiles.

## Install And Use

On target node:

```bash
# 1) unload old module if already loaded
rmmod npu_bypass 2>/dev/null || true

# 2) load module (use compiled or prebuilt module)
insmod /Users/luogangyi/Code/nvshare/npupatch/npu_bypass/npu_bypass.ko davinci_major=235
# or
insmod /Users/luogangyi/Code/nvshare/npupatch/npu_bypass.ko davinci_major=235

# 3) verify
lsmod | grep npu_bypass
modinfo /Users/luogangyi/Code/nvshare/npupatch/npu_bypass.ko | egrep 'vermagic|srcversion|description'
```

Check hook registration in kernel log:

```bash
dmesg | tail -n 80 | grep 'npu_bypass'
```

Expected log lines include:

- `hooked uda_can_access_udevid`
- `hooked uda_task_can_access_udevid`
- `hooked uda_proc_can_access_udevid`
- `hooked uda_occupy_dev_by_ns`
- `hooked uda_devcgroup_permission_allow`
- `hooked uda_ns_node_devid_to_udevid`
- `hooked devdrv_manager_container_logical_id_to_physical_id`

## Conditions For Using The Prebuilt Module Directly

You can use the prebuilt `.ko` directly only if all checks pass:

1. Exact kernel compatibility (`vermagic` match).
2. Same architecture (`aarch64`).
3. Required target symbols exist in running driver/kernel.
4. Security policy allows module loading (root + module loading not blocked).

Quick checks:

```bash
uname -r
modinfo /Users/luogangyi/Code/nvshare/npupatch/npu_bypass.ko | grep vermagic

# required symbols (examples)
grep -w 'uda_can_access_udevid' /proc/kallsyms
grep -w 'uda_proc_can_access_udevid' /proc/kallsyms
grep -w 'uda_ns_node_devid_to_udevid' /proc/kallsyms
grep -w 'devdrv_manager_container_logical_id_to_physical_id' /proc/kallsyms
```

If any check fails, do not force-load the prebuilt module. Rebuild on the target node.

## Scope And Risk Notes

- This bypass affects node-wide NPU isolation behavior, not just one pod.
- Use only on nvshare-designated nodes.
- Keep a rollback path:

```bash
rmmod npu_bypass
```

- If driver/kernel is upgraded, re-run compatibility checks and usually rebuild.

## Compatibility Status (Static Code Inspection)

Required hook target functions are present in these branches:

- `8.5.0`
- `master`
- `9.0.0-beta.1`

This indicates high portability, but runtime validation is still mandatory.
