# Libnvshare 架构与实现分析

## 1. 概述

`libnvshare` 是一个用于 Kubernetes 环境下 GPU 时间片共享的轻量级解决方案。它通过劫持 (Hook) CUDA API 调用，实现多租户对 GPU 的细粒度时间片共享，从而提高 GPU 利用率。不同于 NVIDIA MPS，`libnvshare` 是一个完全用户态的、无侵入的解决方案，不依赖特殊的硬件特性或内核模块。

核心目标：
*   **多应用共享 (Over-subscription)**: 允许多个 CUDA 应用同时驻留在 GPU 显存中，但通过时间片调度来串行执行计算任务。
*   **公平调度**: 通过中心化的调度器 (Scheduler) 保证每个应用获得公平的 GPU 时间片 (Time Quantum, TQ)。
*   **透明性**: 对上层应用透明，无需修改应用源码。

## 2. 核心架构

系统由三个主要组件构成：

1.  **`libnvshare.so` (Client)**: 动态链接库，通过 `LD_PRELOAD` 注入到目标 CUDA 应用中。它拦截关键 CUDA 函数，与调度器交互以获取 GPU 锁。
2.  **`nvshare-scheduler` (Scheduler)**: 系统级守护进程，负责管理 GPU 锁（Token）。它接收客户端的请求，维护请求队列，并根据 FIFO 策略和时间片机制分发锁。
3.  **`nvshare-device-plugin`**: Kubernetes 设备插件，用于在 K8s 集群中发现 GPU 并将其“虚拟化”为多个 `nvshare.com/gpu` 资源，同时负责注入必要的环境变量和挂载。

---

## 3. 实现原理分析

### 3.1 拦截机制 (Interposition)

`libnvshare.so` 利用 Linux 动态链接器的 `LD_PRELOAD` 机制进行函数拦截。

*   **Hook 实现 (`src/hook.c`)**:
    *   定义了与 CUDA Driver API (如 `cuLaunchKernel`, `cuMemcpy`) 签名一致的函数。
    *   在加载时 (`bootstrap_cuda`)，通过 `dlopen` 和 `dlsym` 加载真实的 `libcuda.so` 和 `libnvidia-ml.so` 中的符号。
    *   在 Hook 函数中，先执行 `libnvshare` 的逻辑（如申请锁），再调用真实的 CUDA 函数。

*   **关键拦截点**:
    *   `cuLaunchKernel`: 核心计算函数，必须持有锁才能执行。
    *   `cuMemcpy*`: 涉及数据传输，通常也视为占用 GPU 的操作。
    *   `cuCtxSynchronize`: 需要确保上下文同步完成。

### 3.2 通信协议 (`src/comm.h`)

Client 与 Scheduler 之间通过 Unix Domain Socket 进行通信。协议定义了简单的消息结构：

```c
struct message {
  message_type_t type;
  uint64_t id;          // Client ID
  char data[256];
  char pod_name[64];
  char pod_namespace[64];
  char gpu_uuid[NVSHARE_GPU_UUID_LEN]; // 新增：用于多 GPU 区分
};
```

消息类型 (`message_type_t`):
*   `REGISTER`: 客户端启动时注册。
*   `REQ_LOCK`: 客户端请求 GPU 锁。
*   `LOCK_OK`: 调度器授予锁。
*   `DROP_LOCK`: 调度器通知时间片耗尽，强制剥夺锁。
*   `LOCK_RELEASED`: 客户端主动释放锁。

### 3.3 调度逻辑 (`src/scheduler.c`)

调度器是系统的核心，最新的重构支持了**多 GPU 上下文 (Multi-Context)**。

*   **Per-GPU Context**:
    *   系统引入 `struct gpu_context`，为每个物理 GPU (通过 UUID 区分) 维护独立的状态。
    *   状态包括：`requests` (请求队列), `lock_held` (当前是否被占用), `scheduling_round` (调度轮次), `timer` (时间片计时器)。

*   **调度算法**:
    *   **FCFS (First-Come, First-Served)**: 默认采用简单的先进先出队列。
    *   **时间片轮转 (Time Quantum, TQ)**:
        *   每个 GPU 上下文有一个独立的计时线程 (`timer_thr_fn`)。
        *   当锁被授予 (`LOCK_OK`)，计时器启动。
        *   若 Client 在 TQ 时间内未释放锁，计时器线程发送 `DROP_LOCK`。

*   **多 GPU 支持**:
    *   客户端注册时发送 `gpu_uuid`。
    *   调度器根据 UUID 将 Client 映射到对应的 `gpu_context`。
    *   所有调度决策（加锁、解锁、超时）都在各自的 GPU 上下文中独立进行，实现了多 GPU 间的无锁并行调度。

### 3.4 客户端生命周期 (`src/client.c`)

1.  **初始化 (`initialize_client`)**:
    *   创建 `client_thread` 处理与调度器的通信。
    *   创建 `release_early_thread` 用于监控由于 GPU 空闲导致的提前释放。
    *   获取 `NVIDIA_VISIBLE_DEVICES` 确定绑定的 GPU UUID。

2.  **注册 (Register)**:
    *   向 Scheduler 发送 `REGISTER` 消息（含 UUID）。
    *   等待 Scheduler 确认并分配 Client ID。

3.  **获取锁 (Acquire Lock)**:
    *   当应用调用 `cuLaunchKernel` 等被 Hook 的函数时，调用 `continue_with_lock()`。
    *   如果当前未持有锁 (`own_lock == 0`)，向 Scheduler 发送 `REQ_LOCK` 并阻塞等待。
    *   收到 `LOCK_OK` 后，`own_lock` 置 1，解除阻塞，执行真实 CUDA 调用。

4.  **释放锁 (Release)**:
    *   **主动释放**: 当前实现并不在每次 Kernel 结束后立即释放，而是依赖 **Early Release** 机制。
    *   **Early Release (`release_early_fn`)**:
        *   后台线程定期（默认 5s）检查 GPU 利用率 (via `nvmlDeviceGetUtilizationRates`)。
        *   如果利用率为 0，或者连续一段时间无 Kernel 提交，则判定为空闲。
        *   发送 `LOCK_RELEASED` 给 Scheduler，并置 `own_lock = 0`。
    *   **被动释放 (Preemption)**:
        *   收到 `DROP_LOCK` 消息。
        *   调用 `cuCtxSynchronize()` 确保已提交任务完成（防止上下文切换导致的数据错误）。
        *   发送 `LOCK_RELEASED`，置 `own_lock = 0`。

## 4. Kubernetes 集成

*   **Device Plugin**:
    *   通过 `NVIDIA_VISIBLE_DEVICES` 读取物理 GPU UUID。
    *   生成虚拟设备 ID (如 `GPU-xxx__1`, `GPU-xxx__2`...)。
    *   `Allocate` 阶段：将虚拟设备映射回物理 UUID，并设置容器环境变量 `NVIDIA_VISIBLE_DEVICES` 为物理 UUID，同时挂载 `libnvshare.so` 和 socket。

## 5. 优缺点分析

### 优点
*   **无侵入**: 不需要修改应用代码，甚至不需要重新编译（针对动态链接）。
*   **灵活性**: 基于 Unix Socket 的调度器可以轻松扩展调度策略。
*   **显存隔离**: 依赖 CUDA 原生机制（虽然不如 MPS 强隔离，但多进程上下文是分离的）。
*   **多 GPU 支持**: 完善的 UUID 映射机制，适应复杂的多卡节点环境。

### 缺点与限制
*   **上下文切换开销**: `DROP_LOCK` 发生时需要 `cuCtxSynchronize`，这会强制 CPU 等待 GPU 完成，虽然保证了安全，但可能增加延迟。
*   **显存限制**: 所有共享 GPU 的进程显存之和不能超过物理显存（除非开启 Unified Memory 且接受性能下降）。没有实现显存虚拟化或 Swap。
*   **静态库链接**: 对于静态链接 CUDA Runtime 的应用（如某些 Go程序），`LD_PRELOAD` 可能无法拦截所有符号，或者需要重新编译。
*   **NVML 依赖**: Early Release 机制依赖 NVML 获取利用率，如果 NVML 调用失败，回退机制依赖简单的 Kernel 计时，可能不够准确。

## 6. 总结

`libnvshare` 通过精巧的用户态拦截和中心化调度设计，低成本地实现了 GPU 时间切片共享。最新的重构使其具备了生产级的多 GPU 节点支持能力。其核心架构清晰，关键在于 `Hook -> Sync -> Execute -> Monitor -> Release` 的闭环流程。
