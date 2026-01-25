# Libnvshare 部署模式与运行分析

## 1. 总体架构图

<div align="center">
<img src="images/mermaid001045.svg" alt="nvshare architecture" width="800"/>
</div>

## 2. 组件部署与运行模式

### 2.1 `libnvshare.so` (库/Client)

*   **部署位置**: 并不直接包含在用户镜像中，而是**存在于宿主机**，由 `nvshare-device-plugin` 提供。
*   **注入方式**: 
    1.  `nvshare-device-plugin` 启动时，会将镜像内的 `libnvshare.so` 拷贝/挂载到宿主机的 `/var/run/nvshare/libnvshare.so` (或其他约定路径)。
    2.  当用户 Pod 申请 `nvshare.com/gpu` 资源时，`nvshare-device-plugin` 的 `Allocate` 钩子被触发。
    3.  `Allocate` 返回的 `ContainerResponse` 中包含：
        *   **Mounts**: 将宿主机的 `/var/run/nvshare/libnvshare.so` 挂载到容器内的 `/usr/lib/nvshare/libnvshare.so`。
        *   **Envs**: 设置环境变量 `LD_PRELOAD=/usr/lib/nvshare/libnvshare.so`。
*   **运行模式**: **In-Process (进程内)**。它不是一个独立的进程，而是作为动态链接库加载到**用户的业务进程**空间中。它与业务进程同生共死。

### 2.2 `nvshare-scheduler` (调度器)

*   **部署模式**: **DaemonSet**。确保集群中每个 GPU 节点上都有且仅有一个调度器实例。
*   **运行状态**: **常驻后台进程 (Daemon)**。
*   **职责**:
    *   创建并监听 Unix Domain Socket (`/var/run/nvshare/scheduler.sock`)。
    *   接受来自同一节点上所有用户 Pod (通过 `libnvshare`) 的连接请求。
    *   集中管理该节点上所有 GPU 的锁状态和时间片轮转。
*   **通信依赖**: 依赖 HostPath 卷 `/var/run/nvshare` 来暴露 Socket 文件，供此时运行在不同容器的用户进程访问。

### 2.3 `nvshare-device-plugin` (设备插件)

*   **部署模式**: **DaemonSet**。
*   **运行状态**: **常驻后台进程**。
*   **职责**:
    *   **资源发现**: 向 Kubelet 上报虚拟 GPU 资源数量 (如 `nvshare.com/gpu: 10`)。
    *   **资源分配 (Allocate)**: 实际上不进行物理层面的 GPU 切分，而是通过注入 `LD_PRELOAD` 和挂载配置，让用户容器具备使用 `libnvshare` 能力的“资格”。
    *   **库分发**: 它的 Pod 包含一个 InitContainer 或在主容器生命周期钩子中，负责将 `libnvshare.so` 文件放置到宿主机目录，作为类似“安装”的步骤。

## 3. 部署流程总结

1.  **部署 Scheduler**: `kubectl apply -f scheduler.yaml`。调度器启动，监听 Socket。
2.  **部署 Device Plugin**: `kubectl apply -f device-plugin.yaml`。
    *   插件启动，将 `libnvshare.so` 放到宿主机共享目录。
    *   向 Kubelet 注册 `nvshare.com/gpu`。
3.  **用户部署业务 Pod**:
    *   YAML 中 `resources: limits: nvshare.com/gpu: 1`。
    *   Kubelet 调用 Device Plugin 的 `Allocate`。
    *   Device Plugin 返回配置：挂载 `libnvshare.so`，挂载 `scheduler.sock`，设置 `LD_PRELOAD`。
    *   Pod 启动，业务进程加载 `libnvshare.so`，连接 Scheduler，开始受控运行。

## 4. 关键问题解答

*   **Q: `libnvshare` 需要在业务容器中 preload 吗？**
    *   **A: 不需要用户手动操作。** 用户不需要修改 Dockerfile 去安装 libnvshare 或设置 LD_PRELOAD。这一切都由 Device Plugin 在 Pod 启动瞬间自动注入完成。对用户是透明的。

*   **Q: Client 运行在哪里？**
    *   **A:** Client 代码 (`src/client.c`) 编译在 `libnvshare.so` 中，因此它**运行在用户的业务容器内**，属于用户进程的一部分。

*   **Q: Scheduler 运行在哪里？**
    *   **A:** 运行在独立的 `nvshare-scheduler` 容器中（属于 `nvshare-system` 命名空间），但通过 HostPath 与用户容器共享 Socket。

*   **Q: 为什么需要 HostPath？**
    *   **A:** 因为 Client (用户容器) 和 Scheduler (系统容器) 需要跨容器通信（Unix Socket）以及共享文件（.so库），HostPath 是 K8s 中实现节点级共享最直接的方式。
