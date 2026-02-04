# 单容器多 vGPU 请求支持分析与设计

## 1. 现状分析

### 1.1 问题场景
假设用户申请 `nvshare.com/gpu: 2`，且集群有 2 个物理 GPU (UUID1, UUID2)。
Device Plugin 分配后，容器内环境变量 `NVIDIA_VISIBLE_DEVICES` 设置为 `UUID1,UUID2`。

### 1.2 代码行为追踪

1.  **Client 端 (`client.c`)**:
    *   读取 `NVIDIA_VISIBLE_DEVICES` 获得字符串 `"UUID1,UUID2"`。
    *   将该字符串直接复制到 `nvshare_gpu_uuid`。
    *   发送 `REGISTER` 消息，Payload 中的 `gpu_uuid` 字段为 `"UUID1,UUID2"`。
    *   建立**单条** Socket 连接。

2.  **Scheduler 端 (`scheduler.c`)**:
    *   接收 `REGISTER` 消息。
    *   调用 `get_or_create_gpu_context("UUID1,UUID2")`。
    *   因为 `"UUID1,UUID2"` 与 `"UUID1"` 或 `"UUID2"` 字符串不匹配，Scheduler 会创建一个**全新的、独立的 GPU 上下文**。

### 1.3 结论：不支持且隔离失效
*   **隔离失效**: 如果 Pod A 申请了 `UUID1`，Pod B 申请了 `UUID1,UUID2`。
    *   Pod A 在 Context `UUID1` 中调度。
    *   Pod B 在 Context `UUID1,UUID2` 中调度。
    *   这两个 Context 互相独立，互不知道对方的存在。
    *   **结果**: Pod A 和 Pod B 会并行运行在 `UUID1` 上，导致显存竞争和时间片调度完全失效。
*   **锁粒度错误**: Pod B 获得锁时，意味着它同时“占用”了 UUID1 和 UUID2。但实际上它可能只在 UUID1 上发射 Kernel。

## 2. 设计方案 (Redesign)

为了支持单容器多 GPU 且保持正确的调度隔离，必须对架构进行重大升级。

### 2.1 方案 A: Client 端设备感知的细粒度锁 (推荐)

此方案修改量适中，且符合 CUDA 编程习惯。

#### Client 端修改
1.  **多 UUID 解析**: `client.c` 启动时解析 `UUID1,UUID2`，识别出自己拥有多个物理设备。
2.  **多重注册**: 向 Scheduler 发送多次 `REGISTER`，或者在协议中支持注册多个设备。建议建立 **多条 Socket 连接** (或在一条连接上复用)，每条连接对应一个物理 GPU。
3.  **CUDA Interposition 增强**:
    *   维护 Thread-Local 的 `current_device` 状态 (Hook `cudaSetDevice`)。
    *   当调用 `cuLaunchKernel` 时，检查当前线程对应的是哪个物理设备。
    *   **只向对应物理设备的 Socket/Channel 申请锁**。

#### Scheduler 端修改
1.  无需为了“多 GPU 组合”修改核心逻辑。
2.  Scheduler 继续维护以 **单个 UUID** 为 Key 的 Context。
3.  当 Client 为 UUID1 申请锁时，只影响 UUID1 的调度队列；UUID2 互不影响。

### 2.2 方案 B: 粗粒度 Gang Scheduling (暂不推荐)

若用户总是同时使用所有卡（如 DistributedDataParallel），可以考虑 Gang Scheduling。
*   Scheduler 识别到请求涉及 {UUID1, UUID2}。
*   它必须**同时**获得 UUID1 和 UUID2 的锁才下发 `LOCK_OK`。
*   缺点：死锁风险增加，资源利用率低，且对于只用单卡的代码不友好。

### 2.3 临时解决方案 (当前代码)

如果不想立即进行大规模重构，应在 Device Plugin 或文档中明确限制：
**`nvshare` 目前仅支持每个容器申请 1 个 vGPU (`nvshare.com/gpu: 1`)。**
若申请多个，行为是未定义且不安全的。

## 3. 调度策略 (基于方案 A)

一旦实现了细粒度锁，调度策略就变得简单明确：

*   **优先调度到不同物理 GPU**:
    *   这是 **Device Plugin** 的职责。
    *   如前篇文档所述，实现 `GetPreferredAllocation`，优先返回属于不同物理 GPU 的 vGPU ID。
    *   Kubelet 采纳后，容器拿到 `UUID1,UUID2`。
*   **负载均衡**:
    *   Client 内部代码决定跑在哪个卡上 ( `cudaSetDevice(0)` vs `1`)。
    *   Scheduler 负责确保 UUID1 上的负载（来自所有 Pod）公平轮转，UUID2 同理。

## 4. 总结

当前代码**不支持**多 vGPU 请求的正确隔离。
建议路线图：
1.  短期：限制 `limit: 1`。
2.  长期：实施 **方案 A**，让 Client 具备设备感知能力，实现 per-device locking。
