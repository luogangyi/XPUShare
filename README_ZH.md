## `XPUShare`:以此打破显存限制实现在单一GPU上运行多个任务

`XPUShare` (原名 `nvshare`) 是一种 GPU 共享机制，允许多个进程（或运行在 Kubernetes 上的容器）安全地并发运行在同一物理 GPU 上，且每个进程都能使用完整的 GPU 显存。

你可以观看快速讲解及**演示视频**：https://www.youtube.com/watch?v=9n-5sc5AICY。

为了实现这一点，它利用系统内存作为交换空间，透明地启用了 GPU 缺页异常（Page Fault）处理。为了避免颠簸（Thrashing），它使用 `nvshare-scheduler` 来管理 GPU，并根据给定的时间片（Time Quantum, TQ，默认 30 秒）将 GPU 独占访问权授予单个进程。

此功能完全依赖于 NVIDIA 内核驱动程序提供的统一内存（Unified Memory）API。只要 NVIDIA 不禁用统一内存，内核驱动程序的更新不太可能影响本项目。

在 Kubernetes 上处理 GPU 的事实标准方式（Nvidia 的 Device Plugin）是将 GPU 1:1 分配给容器。对于仅在执行过程中突发性使用 GPU 的应用程序（例如 Jupyter Notebook 等长时间运行的交互式开发作业），这种方式尤其低效。

我写了一篇 [Medium 文章](https://grgalex.medium.com/gpu-virtualization-in-k8s-challenges-and-state-of-the-art-a1cafbcdd12b) 讨论 Kubernetes 上 GPU 共享的挑战，值得一读。

### 典型用例

- 在同一 GPU 上运行 2 个以上具有不频繁 GPU 突发请求的进程/容器（例如：交互式应用、机器学习推理）
- 在同一 GPU 上运行 2 个以上非交互式工作负载（例如：机器学习训练），以最小化总完成时间并减少排队

## 目录
- [特性](#features)
- [核心理念](#key_idea)
- [支持的 GPU](#supported_gpus)
- [概览](#overview)
  - [`nvshare` 组件](#components)
  - [`nvshare-scheduler` 详情](#details_scheduler)
  - [单个进程的显存超卖](#single_oversub)
  - [调度器的时间片 (TQ)](#scheduler_tq)
- [延伸阅读](#further_reading)
- [本地部署](#deploy_local)
  - [安装 (本地)](#installation_local)
  - [使用 (本地)](#usage_local)
  - [测试 (本地)](#test_local)
- [Kubernetes 部署](#deploy_k8s)
  - [安装 (Kubernetes)](#installation_k8s)
  - [使用 (Kubernetes)](#usage_k8s)
    - [使用 `nvshare.com/gpu` 设备](#usage_k8s_device)
    - [(可选) 使用 `nvsharectl` 配置调度器](#usage_k8s_conf)
  - [测试 (Kubernetes)](#test_k8s)
  - [卸载 (Kubernetes)](#uninstall_k8s)
- [本地构建](#build_local)
- [构建 Docker 镜像](#build_docker)
- [未来改进](#future_improves)
- [反馈](#feedbk)

<a name="features"/>

## 特性

- 支持多个进程/容器共享单个 GPU
- 多 GPU 支持：自动检测并管理节点上所有可用 GPU
- 显存和故障隔离得到保证，因为共置进程使用不同的 CUDA 上下文
- 对应用程序完全透明，无需修改代码
- 每个进程/容器都可使用完整的 GPU 显存
   - 使用统一内存将 GPU 显存交换到系统内存
   - 智能调度器：
     - 当任务可放入 GPU 显存时，自动允许并行执行
     - 当显存超卖时，序列化重叠的 GPU 工作以避免颠簸
     - 实现自适应内核窗口（Adaptive Kernel Window）流控以保证公平性
     - 基于显存使用情况的动态时间片
   - 应用程序如果在 TQ 结束前完成工作，会提前释放 GPU
- Kubernetes Device Plugin 支持请求 `nvshare.com/gpu` 资源
- **Prometheus 监控支持**：内置 exporter，支持 GPU 利用率、显存使用及调度器状态监控

<a name="key_idea"/>

## 核心理念

1. 使用 `cudaMalloc()` 时，CUDA 应用的显存分配总和必须小于物理 GPU 显存大小 (`Σ(mem_allocs) <= GPU_mem_size`)。
2. 钩挂并将应用程序中所有 `cudaMalloc()` 调用替换为 `cudaMallocManaged()`（即透明地强制使用 CUDA 的统一内存 API）不会影响正确性，且仅会导致约 1% 的性能下降。
3. 如果应用了 (2)，对于使用 `cudaMalloc()` 编写的应用程序，约束 (1) 不再适用。
4. 当我们超卖 GPU 显存 (`Σ(mem_allocs) > GPU_mem_size`) 时，必须注意避免当共置应用的工作集（即它们*活跃*使用的数据）无法放入 GPU 显存 (`Σ(wss) > GPU_mem_size`) 时产生颠簸。`nvshare-scheduler` 有效地管理了这一点：
    - **并行模式**：如果 `Σ(wss) <= GPU_mem_size`，任务并行运行以最大化利用率。
    - **串行模式**：如果 `Σ(wss) > GPU_mem_size`，调度器将序列化执行以防止颠簸，分配动态时间片的独占访问权。
5. 调度器使用 **自适应内核窗口** 等先进技术来控制提交速率并防止驱动层面的争用。

<a name="supported_gpus"/>

## 支持的 GPU

`XPUShare` 依赖于 Pascal 微架构中引入的统一内存动态缺页处理机制。

它支持 **任何 Pascal (2016) 或更新的 NVIDIA GPU**。

目前仅在 Linux 系统上进行了测试。

<a name="overview"/>

## 概览

<a name="components"/>

### `nvshare` 组件
- `nvshare-scheduler`: 管理节点上所有 GPU 的守护进程。它维护每个 GPU 的独立调度队列，处理锁定和资源仲裁。
- `libnvshare.so`: 注入 CUDA 应用程序的中间层库。它拦截 CUDA 调用，与调度器通信以请求 GPU 访问，并处理 `request_lock`/`drop_lock` 协议。
- `nvsharectl`: 用于实时检查和配置调度器的 CLI 工具。

<a name="details_scheduler"/>

### `nvshare-scheduler` 详情

调度器已显著增强以支持：
1.  **多 GPU 管理**：自动检测所有 GPU 并非为每个 GPU 创建独立的无锁上下文。
2.  **智能调度**：根据实时内存压力动态在并行和串行执行之间切换。
3.  **自适应流控**：使用加性增乘性减 (AIMD) 算法（类似于 TCP）动态调整允许的未决内核数量，确保重负载下的系统稳定性。

<a name="single_oversub"/>

### 单个进程的显存超卖

`XPUShare` 允许每个共置进程使用完整的物理 GPU 显存。默认情况下，它不允许单个进程分配超过 GPU 容量的显存，因为这可能导致进程内部颠簸，无论同一 GPU 上是否存在其他进程。

如果您遇到 `CUDA_ERROR_OUT_OF_MEMORY`，这意味着您的应用程序尝试分配的显存超过了 GPU 的总容量。

您可以设置 `NVSHARE_ENABLE_SINGLE_OVERSUB=1` 环境变量，以允许单个进程使用超过 GPU 物理可用显存的内存。这可能会导致性能下降。

<a name="acknowledgements"/>

## 致谢

本项目是 **Georgios Alexopoulos** 原创项目 [nvshare](https://github.com/grgalex/nvshare) 的分支和延续。我们对他为实现无显存限制的实用 GPU 共享所做的开创性工作表示深深的感谢。他的原始论文和实现为这些多 GPU 和智能调度功能奠定了坚实的基础。

请在此处查看原始项目：https://github.com/grgalex/nvshare

<a name="deployment_guide"/>

## 部署指南

有关详细的部署说明（包括高级配置和故障排除），请参阅 [用户手册](docs/user-guide/deployment.md)。

<a name="future_improves"/>

## 未来改进
- 节点内 GPU 迁移。
- 节点间 GPU 迁移。
- **支持 NPU（例如 Ascend, Cambricon）及非 Nvidia GPU。**
- **优先级调度。**

<a name="feedbk"/>

## 反馈
- 在此存储库上打开 Github issue 提交任何问题/错误/建议。
- 如果您的组织正在使用 `XPUShare` (nvshare)，可以给我发消息/邮件，我可以将您添加到 `USERS.md`。
