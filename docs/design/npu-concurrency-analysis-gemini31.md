# NPU 并发问题深度分析 (NPU Concurrency Analysis)

## 1. 现象与报错路径梳理

在基于 `nvshare` 的 CANN NPU 拦截实现下，当同一台宿主机物理 NPU 上被调度了 2 个不同的 Pod 时，其中一个 Pod 内的 PyTorch 任务会初始化失败。

核心报错日志及完整调用链如下：
```text
[INIT][DEFAULT]Call halGetDeviceInfo failed: drvRet=87, module type=0, info type=1.
-> GetDeviceType (runtime_keeper.cc:64)
-> GetChipType (通过获取硬件版本推断芯片)
-> GetLibRuntimeSoName (runtime_keeper.cc:142)
-> CreateRuntimeImpl (runtime_keeper.cc:156)
-> BootRuntime (runtime_keeper.cc:239)
-> Instance (api.cc:15)
-> rtRegTaskFailCallbackByModule (api_c.cc:2108)
-> RegErrorTrackingCallBack (error_tracking.cc:121)
-> Initialize (ge_executor.cc:310)
-> aclInit (acl.cpp:308)
```
不仅如此，底层驱动级别的错误也清晰地报出：
```text
EL0005: [PID: 6] 2026-02-21-16:36:40.114.368 The resources are busy.
Possible Cause: 1. The resources have been occupied.
```

**对比测试现象**：在 **同一个 Pod 内** 启动 2 个平行的 PyTorch 进程，任务可以双双成功执行。这说明：单个物理 NPU 完全具备处理多进程并发的能力，问题出在**跨容器 (Cross-Pod / Cross-Container) 的访问隔离上**。

---

## 2. 根本原因深度分析 (Root Cause)

### 2.1 错误码 `drvRet=87` 的含义
根据开源的 Ascend driver error 枚举定义（位于 `include/driver/ascend_hal_error.h`），`87` 对应的错误码是：
```c
typedef enum tagDrvError {
    ...
    DRV_ERROR_RESOURCE_OCCUPIED = 87,
    ...
} drvError_t;
```
这验证了底层报错 `The resources are busy`。

### 2.2 为什么同 Pod 并发成功，跨 Pod 并发失败？
Ascend CANN 底层 NPU 内核驱动 (`davinci` 驱动) 实施了严格的**容器级硬件隔离机制**。

1. **底层机制**：默认情况下，Ascend 内核驱动在进程第一次打开并初始化 NPU 设备节点（如 `/dev/davinci0`）时，会将该设备的所有权与当前进程所在的 **cgroup（控制组）** 或 **Namespace (命名空间)** 进行绑定。
2. **同 Pod 场景**：由于 Kubernetes 中同一个 Pod 内的所有容器共享同一个 Sandbox（共享资源隔离组，处于相同的父 cgroup 和资源域下），无论启动多少个进程，驱动层判断这些进程均属于“合法的设备拥有者”，因此允许多个进程复用这块物理 NPU。
3. **跨 Pod (nvshare) 场景**：`nvshare` 将同一个裸物理设备节点 `/dev/davinci0` 挂载给了两个具有彼此完全隔离的 cgroup 的不同 Pod。
   - Pod A 最先执行了 `aclInit` 并成功占有了 `/dev/davinci0`。
   - Pod B 随后执行 `aclInit`，其底层调用 `halGetDeviceInfo`。由于发起了 ioctl，Ascend 驱动捕获了该请求，校验 Pod B 的 cgroup 环境，发现与当前占有设备的 Pod A (cgroup) 不一致。于是，出于安全隔离目的，立即拒绝访问，抛出 `DRV_ERROR_RESOURCE_OCCUPIED (87)`。

### 2.3 `nvshare` 的拦截局限性
即使 `nvshare` 在 userspace 中正确实现了 `aclInit` 串行化 Gate（通过发送接收 `INIT_GRANTED`），并在 API 上控制配额，但也无法绕过 Linux Kernel 中 Ascend 驱动的 cgroup 级权限检查。`nvshare` 只是透传了同一个 Host 设备字符文件，导致冲突在内核驱动层爆发。

---

## 3. 解决方案探讨

要解决此问题，核心是绕过或适配底层 Ascend Driver 的容器独占限制。

### 方案 1：切换为 vNPU (Ascend 硬件虚拟化 / SR-IOV) [推荐]
华为 Ascend 原生支持基于 SR-IOV 技术的算力切分（vNPU / vascend）。不要把物理 `/dev/davinci0` 共享挂载给多个 Pod，而是通过 NPU 驱动自带的工具创建两个独立的虚拟设备（例如 `/dev/vdavinci100`, `/dev/vdavinci101`），然后分配给 Pod A 和 Pod B。
* **优点**：内核级彻底隔离，完美绕过 87 错误，且天然支持 CUBE/VECTOR 的切分限制，不需要深度 HOOK API。
* **代价**：改变了 nvshare 现有的时分复用/软件拦截架构。

### 方案 2：统一 Cgroup 欺骗或共享
如果一定要用 `nvshare` 的 userspace API 劫持方案，需要让内核驱动认为两个 Pod 属于同一个域。这可以通过挂载宿主机的真实 cgroup 路径，或者通过在注入时将 nvshare 运行进程统一种植到一个共用的父 Cgroup 进程内执行（类似于守护进程分离）。
* **风险**：侵入 K8s/Docker 的隔离机制，且非常依赖各种驱动层未闭源的版本实现，极易随驱动升级而失效。

### 方案 3：Client-Server API 代理架构 (MPS 架构)
在宿主机启动一个核心 Daemon (属于单一 cgroup)，它唯一持有开启 NPU 硬件的权限。所有通过 `nvshare` 启动的 Pod，其 `acl_*` API 全部由 `LD_PRELOAD` 劫持转化为 IPC（如 RPC/Socket）调用，并发送给这个中间 Daemon 代理执行。
* **优点**：彻底兼容硬件对单一容器强占用的限制，是纯碎的软件分时/空间超卖。
* **缺点**：工程量极大，相当于要实现 NPU 版本的 rCUDA。

---

## 4. 补充信息需求 (Need more info)
针对当前得出的结论，为了为您确定最佳的修改路线，请求您协助补充以下信息：

1. **底层驱动能力查询**：您当前宿主机的 NPU 驱动版本是否支持 / 已启用 vNPU 功能？能否执行 `npu-smi info -m 1` 查看是否支持切分？
2. **产品预期边界**：您是希望 `nvshare` NPU 版走向轻量级的 “**自动分配 vNPU 来替代 API HOOK**”，还是坚持要走 “**纯软件级别 API HOOK + 时分复用分发**”？
3. **部署权限**：如果您倾向方案2，是否允许 nvshare daemon 在下发 Pod 的时候，对该 Pod 的 cgroup path 和 ns 做特权级的目录符号链接（symlink）和欺骗？

---

## 5. 驱动层 Cgroup 欺骗修改指南 (针对坚持纯软件拦截路线)

如果您决定坚持基于 `nvshare` 纯软件 API 拦截与时分复用的架构，并在内核驱动层做 Cgroup 欺骗，以绕过不同 Pod 抢占产生的 `DRV_ERROR_RESOURCE_OCCUPIED (87)`。通过对 `driver` 源码深度分析，需要修改以下几个关键点：

### 5.1 修改点一：容器 ID 提取逻辑 (绕过不同 Pod 的独立身份)
Ascend 驱动会解析 Linux 系统的 `/proc/self/cpuset` 以及 cgroup path 来提取 `container_id`。我们需要欺骗驱动，让所有进程都返回一个统一的假的容器 ID，让它认为大家都在同一个 Pod 里。
* **文件所在路径**：`/Users/luogangyi/Code/cann/driver/src/sdk_driver/dms/devmng/drv_devmng/drv_devmng_host/ascend910/devdrv_manager_container.c`
* **目标函数**：`STATIC void devdrv_manager_get_container_id(unsigned long long *container_id)`
* **修改方式**：
  直接在函数开头返回一个魔术值（固定伪造的 `container_id`）并跳过原生查询逻辑。
  ```c
  STATIC void devdrv_manager_get_container_id(unsigned long long *container_id)
  {
      if (container_id != NULL) {
          // [Hack for nvshare] Force all containers to share the same container_id
          *container_id = 0x12345678ULL;
      }
      return;
  }
  ```

### 5.2 修改点二：UDA 访问鉴权绕过 (关闭 cgroup 白名单访问限制)
CANN 驱动的 UDA (User Device Access) 子系统会严格校验当前进程（`current`）的命名空间/cgroup 是否合法拥有对特定 `udevid`（底层硬件）的访问权。如果不匹配，直接返回鉴权失败，导致上游抛出 `87`。
* **文件所在路径**：`/Users/luogangyi/Code/cann/driver/src/sdk_driver/pbl/uda/uda_access.c`
* **目标函数一**：`bool uda_proc_can_access_udevid(ka_pid_t hostpid, u32 udevid)` 和 `bool uda_can_access_udevid(u32 udevid)`
* **修改方式**：
  强制返回 `true`，使得驱动不再因挂载跨越问题阻拦设备的打开（open）和操作指令（ioctl）。
  ```c
  bool uda_proc_can_access_udevid(ka_pid_t hostpid, u32 udevid)
  {
      return true; // [Hack for nvshare] Bypass isolation check
  }
  
  bool uda_can_access_udevid(u32 udevid)
  {
      return true; // [Hack for nvshare] Bypass isolation check
  }
  ```

### 5.3 修改点三：命名空间鉴权绕过 (关闭 vDevice 对 ns/pid 的绑定校验)
* **文件所在路径**：`/Users/luogangyi/Code/cann/driver/src/ascend_hal/dms/drv_devmng/ascend910/devdrv_container.c` 和 `devdrv_manager.c`
* **函数**：`int devdrv_manager_container_check_devid_in_container_ns(u32 devid, struct task_struct *task)`
* **修改方式**：
  在函数体一开始直接返回 0 (代表鉴权通过)。
  ```c
  int devdrv_manager_container_check_devid_in_container_ns(u32 devid, struct task_struct *task)
  {
      return 0; // [Hack for nvshare] always pass
  }
  ```

### 小结
这种驱动层面的 Hack (Hack Driver) 需要重新编译 Ascend SDK Driver（内核 `.ko` 模块）并在宿主机替换原生的 `ascend_hal` 与核心驱动。这样一来，K8s 无论起了多少个 Pod，即使它们使用了各自独立的 cgroup，内核驱动由于被硬改，也会无条件允许各容器进程高并发地向 `/dev/davinciX` 下发指令。`nvshare` 再配合顶层的 Userspace 拦截，就可以正常做纯软件级时分复用了。
