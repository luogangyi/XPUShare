## `XPUShare`: Practical GPU Sharing Without Memory Size Constraints

`XPUShare` (formerly `nvshare`) is a GPU sharing mechanism that allows multiple processes (or containers running on Kubernetes) to securely run on the same physical GPU concurrently, each having the whole GPU memory available.

You can watch a quick explanation plus a **demonstration** at https://www.youtube.com/watch?v=9n-5sc5AICY.

To achieve this, it transparently enables GPU page faults using the system RAM as swap space. To avoid thrashing, it uses `nvshare-scheduler`, which manages the GPU and gives exclusive GPU access to a single process for a given time quantum (TQ), which has a default duration of 30 seconds.

This functionality solely depends on the Unified Memory API provided by the NVIDIA kernel driver. It is highly unlikely that an update to NVIDIA's kernel drivers would interfere with the viability of this project as it would require disabling Unified Memory.

The de-facto way (Nvidia's device plugin) of handling GPUs on Kubernetes is to assign them to containers in a 1-1 manner. This is especially inefficient for applications that only use a GPU in bursts throughout their execution, such as long-running interactive development jobs like Jupyter notebooks.

I've written a [Medium article](https://grgalex.medium.com/gpu-virtualization-in-k8s-challenges-and-state-of-the-art-a1cafbcdd12b) on the challenges of GPU sharing on Kubernetes, it's worth a read.

### Indicative Use Cases

- Run 2+ processes/containers with infrequent GPU bursts on the same GPU (e.g., interactive apps, ML inference)
- Run 2+ non-interactive workloads (e.g., ML training) on the same GPU to minimize their total completion time and reduce queueing

## Table of Contents
- [Features](#features)
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
- **Support for NPUs (e.g., Ascend, Cambricon) and non-Nvidia GPUs.**
- **Priority-based scheduling.**

<a name="feedbk"/>

## Feedback
- Open a Github issue on this repository for any questions/bugs/suggestions.
- If your organization is using `XPUShare` (nvshare), you can drop me a message/mail and I can add you to `USERS.md`.
