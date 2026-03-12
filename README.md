## `XPUShare`: Practical GPU Sharing Without Memory Size Constraints

`XPUShare` (formerly `nvshare`) is a GPU sharing mechanism that allows multiple processes (or containers running on Kubernetes) to securely run on the same physical GPU concurrently, each having the whole GPU memory available.

To achieve this, it transparently enables GPU page faults using the system RAM as swap space. To avoid thrashing, it uses `nvshare-scheduler`, which manages the GPU and gives exclusive GPU access to a single process for a given time quantum (TQ), which has a default duration of 30 seconds.

This functionality solely depends on the Unified Memory API provided by the NVIDIA kernel driver. It is highly unlikely that an update to NVIDIA's kernel drivers would interfere with the viability of this project as it would require disabling Unified Memory.

The de-facto way (Nvidia's device plugin) of handling GPUs on Kubernetes is to assign them to containers in a 1-1 manner. This is especially inefficient for applications that only use a GPU in bursts throughout their execution, such as long-running interactive development jobs like Jupyter notebooks.

### Indicative Use Cases

- Run 2+ processes/containers with infrequent GPU bursts on the same GPU (e.g., interactive apps, ML inference)
- Run 2+ non-interactive workloads (e.g., ML training) on the same GPU to minimize their total completion time and reduce queueing

## Table of Contents
- [Features](#features)
- [Current Capability Snapshot](#capability_snapshot)
- [Key Idea](#key_idea)
- [Supported GPUs](#supported_gpus)
- [Overview](#overview)
  - [`nvshare` components](#components)
  - [Some Details on `nvshare-scheduler`](#details_scheduler)
  - [Memory Oversubscription For a Single Process](#single_oversub)
  - [The Scheduler's Time Quantum (TQ)](#scheduler_tq)
- [Comparison with HAMi-core](#comparison_hami)
- [Further Reading](#further_reading)
- [Deploy on a Local System](#deploy_local)
  - [Installation (Local)](#installation_local)
  - [Usage (Local)](#usage_local)
  - [Test (Local)](#test_local)
- [Deploy on Kubernetes](#deploy_k8s)
  - [Installation (Kubernetes)](#installation_k8s)
  - [Usage (Kubernetes)](#usage_k8s)
    - [Use an `nvshare.com/gpu` Device](#usage_k8s_device)
    - [(Optional) Configure scheduler using `nvsharectl`](#usage_k8s_conf)
  - [Test (Kubernetes)](#test_k8s)
  - [Uninstall (Kubernetes)](#uninstall_k8s)
- [Build For Local Use](#build_local)
- [Build Docker Images](#build_docker)
- [Future Improvements](#future_improves)
- [Feedback](#feedbk)

<a name="features"/>

## Features

- Single GPU sharing among multiple processes/containers
- Multi-GPU support: Automatically detects and manages all available GPUs on a node
- Memory and fault isolation is guaranteed because co-located processes use different CUDA contexts
- Completely transparent to applications, no code changes needed
- Each process/container has whole GPU memory available
   - Uses Unified Memory to swap GPU memory to system RAM
   - Smart Scheduler:
     - Automatically allows parallel execution when tasks fit in GPU memory
     - Serializes overlapping GPU work to avoid thrashing when memory is oversubscribed
     - Implements Adaptive Kernel Window flow control for fairness
     - Dynamic Time Quantum based on memory usage
   - Apps release GPU if done with work before TQ elapses
- Device plugin for Kubernetes allowing `nvshare.com/gpu` resource requests
- **Prometheus Metrics Support**: Built-in exporter for GPU utilization, memory usage, and scheduler state monitoring

<a name="capability_snapshot"/>

## Current Capability Snapshot (xpushare-validated)

The following summary is based on the current `tests/xpushare` validation matrix and recent quantified runs.

### 1) Multi-container sharing on one physical GPU/NPU

- **CUDA (T4)**
  - Multiple containers/tasks can share one physical GPU concurrently.
  - Verified scale points include `2` and `4` concurrent tasks per test wave.
  - Example measured wave times: `2 tasks -> 707s`, `4 tasks -> 881s` under the same `w2@50%` stress profile.
- **CANN / Ascend (910B path)**
  - Multiple tasks can run under `nvshare.com/gpu` on NPU nodes.
  - Current xpushare validation confirms oversub on/off path stability (both phases succeed).

### 2) Compute share vs native single-task baseline

- **CUDA long-baseline reference (`w6`)**
  - Baseline (single task): `246.27s`.
  - Single-task quota ratios vs baseline:
    - `25% quota -> 3.700x`
    - `50% quota -> 1.787x`
    - `75% quota -> 1.293x`
  - Two-task same-GPU quota mix ratios vs baseline:
    - `25/75 mix -> 3.961x / 1.851x`
    - `30/60 mix -> 3.243x / 1.956x` (`30/60 runtime ratio = 1.658`)
- **Quota update reaction**
  - Dynamic compute quota propagation to metrics: `~5s` observed.
- **Metrics collection overhead**
  - Measured near-zero impact in current run: `-0.004%` (off/on comparison noise-level).
- **NPU (910B)**
  - Current xpushare run shows off/on oversub runtimes `6.774s / 6.895s` (both succeeded).
  - Full NPU quota linearity vs long baseline is not yet fully covered by this matrix.

### 3) Quota effectiveness and baseline-ratio behavior

- CUDA quota control is **effective** and repeatedly tracks expected baseline ratios in long-baseline runs.
- Multi-task same-GPU comparisons show stable ordering (`lower quota -> longer runtime`) and practical ratio separation.
- In recent medium-baseline reruns, multi-GPU parallel ratio also stayed inside configured tolerance windows (`~2.10x`, `~2.08x` in a 4-task wave).

### 4) Known remaining issues (product-level)

- **NPU quota-accuracy coverage is still incomplete in xpushare matrix**: oversub path is stable, but comprehensive long-baseline quota-ratio conformance on NPU still needs broader regression coverage.

<a name="key_idea"/>

## Key Idea

1. With `cudaMalloc()`, the sum of memory allocations from CUDA apps must be smaller than physical GPU memory size (`Σ(mem_allocs) <= GPU_mem_size`).
2. Hooking and replacing all `cudaMalloc()` calls in an application with `cudaMallocManaged()`, i.e., transparently forcing the use of CUDA's Unified Memory API does not affect correctness and only leads to a ~1% slowdown.
3. If we apply (2), constraint (1) no longer holds for an application written using `cudaMalloc()`.
4. When we oversubscribe GPU memory (`Σ(mem_allocs) > GPU_mem_size`), we must take care to avoid thrashing when the working sets of co-located apps (i.e., the data they are *actively* using) don't fit in GPU mem (`Σ(wss) > GPU_mem_size`). `nvshare-scheduler` effectively manages this:
    - **Parallel Mode**: If `Σ(wss) <= GPU_mem_size`, tasks run in parallel for maximum utilization.
    - **Serialized Mode**: If `Σ(wss) > GPU_mem_size`, the scheduler serializes execution to prevent thrashing, assigning exclusive access for a dynamic time quantum.
5. The scheduler uses advanced techniques like **Adaptive Kernel Window** to control submission rates and prevent driver-level contention.

<a name="comparison_hami"/>

## Comparison with HAMi-core

Both XPUShare and [HAMi-core](https://github.com/Project-HAMi/HAMi-core) achieve GPU sharing via `LD_PRELOAD` CUDA Driver API interposition, but take fundamentally different architectural approaches:

| | HAMi-core | XPUShare |
|:---|:---|:---|
| **Hooked APIs** | ~150+ | ~16 |
| **Memory Strategy** | Software-virtualized: intercepts all alloc/free/query APIs to enforce limits on native `cudaMalloc` | Hardware-assisted: replaces `cudaMalloc` → `cudaMallocManaged` (Unified Memory), letting the driver handle page faults and swap |
| **Compute Quota** | NVML polling + sleep-based throttling | Centralized scheduler with Adaptive Kernel Window (AIMD) flow control |
| **Device Virtualization** | Supports exposing a GPU subset to containers | No device virtualization; scheduler manages per-GPU queues |
| **Coordination** | File locks (`/tmp/vgpulock/`) | Unix socket to dedicated scheduler daemon |
| **Memory Oversubscription** | Not supported (hard limit on physical VRAM) | Natively supported via Unified Memory |
| **CUDA Compatibility** | Must track every new CUDA API (Graph, MemPool, Virtual Memory, IPC, etc.) | Stable — new APIs don't bypass the core mechanism |

**Why the difference?** HAMi-core keeps `cudaMalloc` semantics unchanged, so it must intercept *every* path that could allocate, free, or query GPU memory — including Arrays, Mipmaps, Memory Pools (CUDA 11.2+), Virtual Memory Management, IPC handles, External Resources, and CUDA Graphs. Missing any single path would break memory accounting. XPUShare instead leverages NVIDIA's Unified Memory hardware to offload memory management to the GPU/driver, requiring hooks only at critical control points (kernel launch, alloc/free, memcpy).

For a detailed analysis, see [HAMi-core vs XPUShare Comparison](docs/design/hami_core_vs_xpushare_comparison.md).

<a name="supported_gpus"/>

## Supported GPUs

`XPUShare` relies on Unified Memory's dynamic page fault handling mechanism introduced in the Pascal microarchitecture.

It supports **any Pascal (2016) or newer Nvidia GPU**.

It supports **Ascend 910B NPU**.

It has only been tested on Linux systems.

<a name="overview"/>

## Overview

<a name="components"/>

### `nvshare` components
- `nvshare-scheduler`: A daemon that manages all GPUs on the node. It maintains independent scheduling queues for each GPU, handling locking and resource arbitration.
- `libnvshare.so`: The interposer library injected into CUDA applications. It intercepts CUDA calls, communicates with the scheduler to request GPU access, and handles `request_lock`/`drop_lock` protocols.
- `nvsharectl`: A CLI tool to inspect and configure the scheduler in real-time.

<a name="details_scheduler"/>

### Some Details on `nvshare-scheduler`

The scheduler has been significantly enhanced to support:
1.  **Multi-GPU Management**: Automatically detects all GPUs and creates independent, lock-free contexts for each.
2.  **Smart Scheduling**: Dynamically switches between parallel and serial execution based on real-time memory pressure.
3.  **Adaptive Flow Control**: Uses an Additive Increase Multiplicative Decrease (AIMD) algorithm (similar to TCP) to dynamically adjust the number of pending kernels allowed, ensuring system stability under heavy load.

<a name="single_oversub"/>

### Memory Oversubscription For a Single Process

`XPUShare` allows each co-located process to use the whole physical GPU memory. By default, it doesn't allow a single process to allocate more memory than the GPU can hold, as this can lead to internal thrashing for the process, regardless of the existence of other processes on the same GPU.

If you get a `CUDA_ERROR_OUT_OF_MEMORY` it means that your application tried to allocate more memory than the total capacity of the GPU.

You can set the `NVSHARE_ENABLE_SINGLE_OVERSUB=1` environment variable to enable a single process to use more memory than is physically available on the GPU. This can lead to degraded performance.

<a name="acknowledgements"/>

## Ascend NPU (CANN) Support Status (Experimental)

This repository now includes an **experimental CANN/Ascend NPU backend**. The current status is:

- Implemented (validated in this fork, see `docs/design/cann_npu_virtualization_analysis.md` and related smoke/quota tests):
  - `LD_PRELOAD`-based NPU backend selection and ACL runtime hook path (`libascendcl.so` / `aclrt*`)
  - Kubernetes integration for Ascend via `nvshare-device-plugin` + `nvshare-scheduler` (exposes `nvshare.com/gpu` on NPU nodes)
  - NPU memory quota and compute quota control
  - Dynamic quota updates (memory/core) via scheduler + annotations
  - Prometheus metrics for scheduler/client quota state and NPU-related utilization/accounting paths
  - CUDA + CANN smoke/perf/quota test scripts (`tests/remote-test-smoke.sh`)

- Implemented with current boundaries:
  - NPU memory oversubscription path via managed allocation mode (`NVSHARE_ENABLE_SINGLE_OVERSUB=1`, `NVSHARE_NPU_OVERSUB_ALLOC_MODE=managed`)
  - `aclrtMallocWithCfg(..., cfg=NULL)` managed mode support (`NVSHARE_NPU_MANAGED_WITHCFG=1`)
  - Oversub observability metrics for managed/native split, fallback reasons, and prefetch results

- Not fully validated yet:
  - Reliable "true resident HBM memory" per-process metric (current metrics are allocation/quota-oriented, not exact residency)
  - Broad multi-framework compatibility validation (beyond current tested `torch_npu` paths)

- **Critical Requirement for Cross-Pod Concurrency**:
  - By default, **Multiple Pods sharing the same physical Ascend NPU concurrently** is blocked by Ascend driver/runtime isolation checks (`drvRet=87`).
  - To enable NPU virtualization across different Pods, you **must** patch the CANN driver using the `npu_bypass.ko` kretprobe module.
  - This fork packages `npupatch/` into the `nvshare-device-plugin` image and loads the module via `npu-bypass-loader` initContainer (`/opt/npupatch/load-npu-bypass.sh`) on CANN nodes.
  - Please carefully read the design and deployment instructions in [docs/design/design-npu-container-isolation-bypass.md](docs/design/design-npu-container-isolation-bypass.md) and deploy the patch before using `nvshare` for NPU.
  - Patch bundle, source build steps, prebuilt module conditions, and install guide:
    [npupatch/README.md](npupatch/README.md)
  - Validation path:
    - Run `tests/remote-test-smoke.sh --clusters cann` to build/deploy and verify end-to-end.
    - By default, the script now removes `npu_bypass` on target NPU node before deploy and verifies it is auto-loaded again by device-plugin.
    - Useful switches: `XP_CANN_RESET_NPU_MODULE`, `XP_CANN_VERIFY_NPU_MODULE`, `XP_CANN_NODE_SSH_HOST`, `XP_CANN_NODE_SSH_USER`, `XP_CANN_NODE_SSH_PORT`.

- **Workaround Branch Positioning (`npu-workaround`)**:
  - If your NPU driver/runtime version is **below 8.5.0** and cannot be upgraded, you can use this branch as a compatibility workaround.
  - This branch keeps the `npu_bypass.ko` installation path to bypass the driver-level device-sharing restriction.
  - Known trade-offs (from current repo test records):
    - Extra operational complexity:
      - Requires privileged initContainer + kernel module lifecycle management on NPU nodes.
      - Requires host/kernel compatibility handling for `npu_bypass.ko`.
    - Quota accuracy is not ideal in several CANN runs:
      - Historical single-task ratios vs baseline: `25%=1.967x`, `50%=1.485x`, `75%=1.192x` (expected trend near `4.0x/2.0x/1.333x`).
      - Historical 30/60 mix runtime ratio: `1.158` (target separation was significantly larger).
    - Overhead can be large in memory-intensive hot-access oversub workloads:
      - `hot-managed / hot-native = 3.2930x` in `docs/performance/performance_test_for_gpu_share.md` (Section 8).
  - Recommendation:
    - Use this branch only when driver upgrade is blocked.
    - Prefer the latest `main` line on new driver/runtime stacks.


## Acknowledgements

This project is a fork and continuation of the original [nvshare](https://github.com/grgalex/nvshare) by **Georgios Alexopoulos**. We are deeply grateful for his pioneering work in bringing practical GPU sharing to life without memory constraints. His original thesis and implementation provided the solid foundation upon which these multi-GPU and smart scheduling features were built.

Please verify the Original Project here: https://github.com/grgalex/nvshare

<a name="deployment_guide"/>

## Deployment Guide

For detailed deployment instructions, including advanced configuration and troubleshooting, please refer to the [Deployment Guide](docs/user-guide/deployment.md).

<a name="future_improves"/>

## Future Improvements
- Intra-node GPU migration.
- Inter-node GPU migration.
- **Support for other GPU/NPU (e.g.,PPU, Cambricon).**
- **Priority-based scheduling.**

<a name="feedbk"/>

## Feedback
- Open a Github issue on this repository for any questions/bugs/suggestions.
- If your organization is using `XPUShare` (nvshare), you can drop me a message/mail and I can add you to `USERS.md`.
