## `XPUShare`：在不受显存容量限制下实现实用 GPU 共享

`XPUShare`（原名 `nvshare`）是一种 GPU 共享机制，允许多个进程（或运行在 Kubernetes 上的容器）安全并发地使用同一张物理 GPU，并且每个进程都可见整卡显存。

其核心方式是透明启用 GPU 缺页机制，并使用系统内存作为换页空间。为避免 Thrashing（抖动），`XPUShare` 使用 `nvshare-scheduler` 管理 GPU，在给定时间片（Time Quantum, TQ，默认 30 秒）内将 GPU 独占访问权授予单个进程。

该能力仅依赖 NVIDIA 内核驱动提供的 Unified Memory API。除非 NVIDIA 禁用 Unified Memory，否则驱动更新通常不会破坏本项目机制。

在 Kubernetes 中，事实标准（NVIDIA device plugin）通常采用 GPU 与容器 1:1 分配。这对“仅在执行过程中突发使用 GPU”的任务（如长期运行的 Jupyter 交互任务）效率较低。

### 典型使用场景

- 在同一 GPU 上运行 2 个以上、GPU 突发使用不频繁的进程/容器（如交互式应用、ML 推理）
- 在同一 GPU 上运行 2 个以上非交互任务（如 ML 训练），以降低总完工时间并减少排队

## 目录
- [特性](#features)
- [当前能力快照](#capability_snapshot)
- [核心原理](#key_idea)
- [支持的 GPU/NPU](#supported_gpus)
- [总体架构](#overview)
  - [`nvshare` 组件](#components)
  - [`nvshare-scheduler` 细节](#details_scheduler)
  - [单进程显存超分](#single_oversub)
  - [调度器时间片（TQ）](#scheduler_tq)
- [与 HAMi-core 对比](#comparison_hami)
- [延伸阅读](#further_reading)
- [本地部署](#deploy_local)
  - [安装（本地）](#installation_local)
  - [使用（本地）](#usage_local)
  - [测试（本地）](#test_local)
- [Kubernetes 部署](#deploy_k8s)
  - [安装（Kubernetes）](#installation_k8s)
  - [使用（Kubernetes）](#usage_k8s)
    - [使用 `nvshare.com/gpu` 设备](#usage_k8s_device)
    - [（可选）使用 `nvsharectl` 配置调度器](#usage_k8s_conf)
  - [测试（Kubernetes）](#test_k8s)
  - [卸载（Kubernetes）](#uninstall_k8s)
- [本地构建](#build_local)
- [构建 Docker 镜像](#build_docker)
- [未来改进](#future_improves)
- [反馈](#feedbk)

<a name="features"/>

## 特性

- 支持单 GPU 被多个进程/容器共享
- 多 GPU 支持：自动检测并管理节点上的所有 GPU
- 由于共置进程使用不同 CUDA 上下文，可保证内存与故障隔离
- 对应用完全透明，无需改代码
- 每个进程/容器可见整卡显存
  - 使用 Unified Memory 将 GPU 内存页换入系统内存
  - 智能调度器：
    - 当任务工作集可放入显存时自动并行
    - 当显存超分导致工作集重叠时自动串行，避免 Thrashing
    - 使用 Adaptive Kernel Window 流控提升公平性
    - 基于内存压力动态调整时间片
  - 任务若提前完成会在时间片结束前主动释放 GPU
- 提供 Kubernetes device plugin，可请求 `nvshare.com/gpu`
- **Prometheus 指标支持**：内置 exporter，提供 GPU 利用率、显存使用与调度状态指标

<a name="capability_snapshot"/>

## 当前能力快照（基于 xpushare 验证）

以下结论来自当前 `tests/xpushare` 验证矩阵及近期量化结果。

### 1）单卡 GPU/NPU 多容器共享能力

- **CUDA（T4）**
  - 支持多个容器/任务并发共享同一张物理 GPU。
  - 已验证的并发规模包括每轮 `2`、`4` 任务。
  - 同一 `w2@50%` 压测下，示例波次时长：`2 tasks -> 707s`，`4 tasks -> 881s`。
- **CANN / Ascend（910B 路径）**
  - 支持 NPU 节点下 `nvshare.com/gpu` 多任务运行。
  - 当前 xpushare 验证显示 oversub on/off 两条路径均可稳定完成（均成功）。

### 2）相对原生单卡单任务基线的算力表现

- **CUDA 长基线参考（`w6`）**
  - 单任务基线：`246.27s`。
  - 单任务配额相对基线倍率：
    - `25% quota -> 3.700x`
    - `50% quota -> 1.787x`
    - `75% quota -> 1.293x`
  - 同卡双任务配额混配相对基线倍率：
    - `25/75 mix -> 3.961x / 1.851x`
    - `30/60 mix -> 3.243x / 1.956x`（`30/60 runtime ratio = 1.658`）
- **配额动态更新响应**
  - 动态算力配额在指标中可观测生效时延约 `~5s`。
- **指标采集开销**
  - 当前测得近似 0：`-0.004%`（off/on 对比，噪声级别）。
- **NPU（910B）**
  - 当前 xpushare 结果：oversub off/on 时长 `6.774s / 6.895s`（均成功）。
  - NPU 的“长基线下配额线性”尚未被该矩阵完全覆盖。

### 3）配额生效与基线比例关系

- CUDA 配额控制已被验证为**有效**，并在长基线回归中持续贴近预期比例。
- 同卡多任务比较显示稳定顺序关系（`lower quota -> longer runtime`）以及可区分的倍率差。
- 近期中等基线复跑中，多 GPU 并行倍率也保持在配置容差内（4 任务波次约 `~2.10x`、`~2.08x`）。

### 4）当前遗留问题（产品层面）

- **NPU 配额精度覆盖仍不完整**：当前已验证 oversub 路径稳定，但 NPU 在长基线下的配额倍率一致性仍需更广泛回归覆盖。

<a name="key_idea"/>

## 核心原理

1. 使用 `cudaMalloc()` 时，CUDA 应用总显存分配受物理显存限制（`Σ(mem_allocs) <= GPU_mem_size`）。
2. 将应用中的 `cudaMalloc()` 透明替换为 `cudaMallocManaged()`（强制使用 CUDA Unified Memory）不影响正确性，且通常仅带来约 1% 性能损耗。
3. 采用第 2 点后，第 1 点的硬约束对使用 `cudaMalloc()` 编写的应用不再成立。
4. 当显存超分（`Σ(mem_allocs) > GPU_mem_size`）时，如果共置任务活跃工作集无法同时放入显存（`Σ(wss) > GPU_mem_size`），必须避免 Thrashing。`nvshare-scheduler` 的处理方式：
   - **Parallel Mode**：若 `Σ(wss) <= GPU_mem_size`，并行执行以最大化吞吐。
   - **Serialized Mode**：若 `Σ(wss) > GPU_mem_size`，串行调度并分配动态时间片，避免抖动。
5. 调度器通过 **Adaptive Kernel Window** 等机制控制提交速率，减少驱动层争用。

<a name="comparison_hami"/>

## 与 HAMi-core 对比

XPUShare 与 [HAMi-core](https://github.com/Project-HAMi/HAMi-core) 都通过 `LD_PRELOAD` 劫持 CUDA Driver API 实现共享，但架构路径不同：

| | HAMi-core | XPUShare |
|:---|:---|:---|
| **Hooked APIs** | ~150+ | ~16 |
| **Memory Strategy** | 软件虚拟化：拦截 alloc/free/query 并在原生 `cudaMalloc` 上做限制 | 硬件辅助：`cudaMalloc` → `cudaMallocManaged`（Unified Memory），页错误与换页由驱动处理 |
| **Compute Quota** | NVML 轮询 + sleep 限流 | 中心化 scheduler + Adaptive Kernel Window（AIMD）流控 |
| **Device Virtualization** | 可向容器暴露 GPU 子集 | 不做设备虚拟化；scheduler 管理每 GPU 队列 |
| **Coordination** | 文件锁（`/tmp/vgpulock/`） | Unix socket 连接专用 scheduler daemon |
| **Memory Oversubscription** | 不支持（受物理显存硬上限约束） | 原生支持（基于 Unified Memory） |
| **CUDA Compatibility** | 需持续跟踪 CUDA 新 API（Graph/MemPool/Virtual Memory/IPC 等） | 相对稳定，新 API 不易绕过核心机制 |

**根本差异**：HAMi-core 保留 `cudaMalloc` 语义，必须覆盖所有可能分配/释放/查询显存路径（Arrays、Mipmaps、Memory Pools、VMM、IPC、External Resources、CUDA Graph 等）；漏拦截会导致显存记账失真。XPUShare 则把显存管理下放给 NVIDIA Unified Memory 硬件/驱动，仅在关键控制点（kernel launch、alloc/free、memcpy）拦截。

详细分析见：[HAMi-core vs XPUShare Comparison](docs/design/hami_core_vs_xpushare_comparison.md)

<a name="supported_gpus"/>

## 支持的 GPU/NPU

`XPUShare` 的 CUDA 侧依赖 Pascal 架构引入的 Unified Memory 动态缺页机制。

- 支持 **Pascal（2016）及更新的 NVIDIA GPU**
- 支持 **Ascend 910B NPU**
- 目前仅在 Linux 系统上完成验证

<a name="overview"/>

## 总体架构

<a name="components"/>

### `nvshare` 组件
- `nvshare-scheduler`：节点级守护进程，管理所有 GPU，维护每卡独立调度队列并负责锁与仲裁。
- `libnvshare.so`：注入 CUDA 应用的拦截库，负责 CUDA API 拦截、向 scheduler 申请 GPU 访问、处理 `request_lock`/`drop_lock` 协议。
- `nvsharectl`：实时查看与配置 scheduler 的命令行工具。

<a name="details_scheduler"/>

### `nvshare-scheduler` 细节

调度器已增强以支持：
1. **多 GPU 管理**：自动检测所有 GPU，并创建相互独立的调度上下文。
2. **智能调度**：根据实时内存压力在并行/串行模式间切换。
3. **自适应流控**：采用 AIMD（类似 TCP）动态控制允许的 pending kernels 数量，在高负载下保持系统稳定。

<a name="single_oversub"/>

### 单进程显存超分

`XPUShare` 允许共置进程各自看到整卡显存。默认情况下，不允许单个进程分配超过物理显存总量，以避免该进程内部出现严重 Thrashing（与是否存在其他进程无关）。

若出现 `CUDA_ERROR_OUT_OF_MEMORY`，表示应用尝试分配的显存超过了 GPU 总容量。

可以设置环境变量 `NVSHARE_ENABLE_SINGLE_OVERSUB=1`，允许单进程分配超过物理显存的内存，但这通常会带来性能下降。

<a name="acknowledgements"/>

## Ascend NPU（CANN）支持状态（实验性）

本仓库包含**实验性 CANN/Ascend NPU 后端**。当前状态如下：

- 已实现（本分支已验证，见 `docs/design/cann_npu_virtualization_analysis.md` 及相关 smoke/quota 测试）：
  - 基于 `LD_PRELOAD` 的 NPU 后端识别与 ACL runtime hook 路径（`libascendcl.so` / `aclrt*`）
  - Ascend Kubernetes 集成：`nvshare-device-plugin` + `nvshare-scheduler`（在 NPU 节点暴露 `nvshare.com/gpu`）
  - NPU 显存配额与算力配额控制
  - 通过 scheduler + annotations 动态更新配额（memory/core）
  - Prometheus 指标（scheduler/client 配额状态及 NPU 相关利用率/记账路径）
  - CUDA + CANN smoke/perf/quota 测试脚本（`tests/remote-test-smoke.sh`）

- 尚未实现 / 未完全验证：
  - 面向生产的 NPU 透明显存超分能力（与 CUDA UVM 的 `cudaMalloc -> managed` 对应）
  - 进程级“真实驻留 HBM 显存”精确指标（当前指标更偏分配/配额，不是精确驻留）
  - 更广泛框架兼容性验证（当前主要覆盖 `torch_npu`）

- **跨 Pod 并发的关键前提**：
  - 默认情况下，**多个 Pod 并发共享同一张 Ascend 物理 NPU** 会被 Ascend 驱动/runtime 隔离检查阻断（`drvRet=87`）。
  - 若需启用跨 Pod NPU 虚拟化，**必须**使用 `npu_bypass.ko` kretprobe 模块对 CANN 驱动打补丁。
  - 本分支已将 `npupatch/` 打包进 `nvshare-device-plugin` 镜像，并通过 `npu-bypass-loader` initContainer（`/opt/npupatch/load-npu-bypass.sh`）在 CANN 节点加载模块。
  - 使用前请先阅读并执行部署文档：[docs/design/design-npu-container-isolation-bypass.md](docs/design/design-npu-container-isolation-bypass.md)
  - 补丁包、源码构建、预编译模块适用条件及安装说明见：[npupatch/README.md](npupatch/README.md)
  - 验证路径：
    - 运行 `tests/remote-test-smoke.sh --clusters cann` 完成构建/部署/端到端验证
    - 脚本默认会在部署前卸载目标 NPU 节点 `npu_bypass`，并在部署后验证由 device-plugin 自动重新加载
    - 常用开关：`XP_CANN_RESET_NPU_MODULE`、`XP_CANN_VERIFY_NPU_MODULE`、`XP_CANN_NODE_SSH_HOST`、`XP_CANN_NODE_SSH_USER`、`XP_CANN_NODE_SSH_PORT`


## 致谢

本项目基于 **Georgios Alexopoulos** 的原始项目 [nvshare](https://github.com/grgalex/nvshare) 继续演进。其开创性的设计与实现为“突破显存容量限制的实用 GPU 共享”奠定了基础。

原始项目地址：https://github.com/grgalex/nvshare

<a name="deployment_guide"/>

## 部署指南

详细部署说明（含高级配置与故障排查）请参阅：[Deployment Guide](docs/user-guide/deployment.md)

<a name="future_improves"/>

## 未来改进
- 节点内 GPU 迁移
- 节点间 GPU 迁移
- **支持其他 GPU/NPU（例如 PPU、寒武纪）**
- **基于优先级的调度**

<a name="feedbk"/>

## 反馈
- 如有问题/缺陷/建议，请在本仓库提交 GitHub issue
- 若你的组织在使用 `XPUShare`（nvshare），可联系维护者以加入 `USERS.md`
