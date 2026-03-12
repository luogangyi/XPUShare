# NPU 容器隔离校验关闭 —— 设计与实现文档

## 1. 背景与目标

### 1.1 问题回顾

在 `xpushare` NPU 虚拟化场景下，同一物理 NPU（如 `/dev/davinci0`）被挂载给多个 Pod 共享。CANN 驱动的 UDA（User Device Access）子系统实施了**基于 Linux `mnt_namespace` 的容器级硬件隔离**，导致跨 Pod 并发访问同一 NPU 时第二个 Pod 收到 `DRV_ERROR_RESOURCE_OCCUPIED (87)` 错误。

详见前期分析文档：[npu-concurrency-analysis-gemini31.md](file:///Users/luogangyi/Code/xpushare/docs/design/npu-concurrency-analysis-gemini31.md)

### 1.2 修改目标

通过一个**独立的内核模块** `npu_bypass.ko`，在不修改原始驱动代码的前提下，利用 Linux kretprobe 机制在运行时 hook 关键隔离检查函数，允许跨 Pod 共享同一物理 NPU 设备。

> [!IMPORTANT]
> 该模块仅用于 xpushare 等需要跨容器共享 NPU 的受控场景。关闭隔离校验意味着放弃驱动层的容器安全隔离保护，用户需自行确保应用层的资源调度安全。

---

## 2. 驱动隔离机制分析

驱动的容器隔离涉及**两条路径**，都需要旁路：

### 2.1 Path 1: 设备 open 路径 (`/dev/davinciX`)

```
open(/dev/davinci0)
 → uda_access_open()
   → uda_cur_is_admin()         ← 非 admin 才做占用检查
   → uda_occupy_dev()
     → uda_occupy_dev_by_ns()   ← 🔴 namespace 冲突返回 -EBUSY
```

| 函数 | 作用 |
|------|------|
| `uda_cur_is_admin()` | 判断当前进程是否为 admin（host 进程或有特权），admin 跳过占用检查 |
| `uda_task_access_judge_ok()` | 核心鉴权：比较 task 的 mnt_namespace 与设备绑定的 namespace |
| `uda_occupy_dev_by_ns()` | 将设备绑定到 namespace，已被占用时返回 -EBUSY |

### 2.2 Path 2: ioctl 路径 (`/dev/davinci_manager`)

```
halGetDeviceInfo(devId=0)
 → ioctl(DEVDRV_MANAGER_GET_DEVINFO)
   → devdrv_manager_trans_and_check_id()
     → devdrv_manager_container_logical_id_to_physical_id()  ← 🔴 ns_node 查找失败
       → uda_devid_to_phy_devid()
         → uda_ns_node_devid_to_udevid()  ← 无 ns_node 时返回 -EAGAIN
```

| 函数 | 作用 |
|------|------|
| `devdrv_manager_container_is_in_container()` | 判断当前进程是否在容器中 |
| `devdrv_manager_container_logical_id_to_physical_id()` | 逻辑设备 ID → 物理设备 ID 转换 |
| `uda_ns_node_devid_to_udevid()` | 通过 ns_node 查找 devid → udevid 映射 |

### 2.3 关键发现：ns_node 创建机制

当 `uda_ns_node_devid_to_udevid` 返回 `-EAGAIN` 时，调用方 `uda_dev_inst_get_by_devid` 会触发 `uda_setup_ns_node()` 为当前 namespace 创建 ns_node。**但 ns_node 创建后的重试仅在 `uda_cur_is_admin()` 返回 true 时执行**。这意味着：
- 必须 hook `uda_cur_is_admin` → true，让 Pod B 的 ns_node 能正确创建并重试
- 不能覆盖 `-EAGAIN`，否则 ns_node 创建永远不会触发

---

## 3. 实现方案：独立 kretprobe 内核模块

### 3.1 方案选择

| 方案 | 优劣 | 结论 |
|------|------|------|
| ① 修改 `uda_access.c` + 全量编译安装 | 模块名/符号不兼容，替换后 NPU 不工作 | ❌ |
| ② **独立 kretprobe 模块** `npu_bypass.ko` | 零侵入，即插即用 | ✅ 采用 |

### 3.2 Hook 设计（7 个 hook）

| # | Hook 函数 | 所在模块 | 覆盖策略 | 目的 |
|---|-----------|---------|---------|------|
| 1 | `uda_cur_is_admin` | ascend_uda | → true | 🔑 跳过 open 占用 + 启用 ns_node 重试 |
| 2 | `uda_can_access_udevid` | ascend_uda | → true | ns_node 设备枚举时允许访问 |
| 3 | `uda_proc_can_access_udevid` | ascend_uda | → true | PID 访问检查 |
| 4 | `uda_occupy_dev_by_ns` | ascend_uda | 仅抑制 -EBUSY | 保留正常 ns 绑定，只覆盖冲突 |
| 5 | `devdrv_manager_container_is_in_container` | drv_devmng_host | → 0 | ioctl 路径视为宿主机进程 |
| 6 | `devdrv_manager_container_logical_id_to_physical_id` | ascend_uda | 失败时 phy=logical | ioctl 路径逻辑→物理 ID 转换 |
| 7 | `uda_ns_node_devid_to_udevid` | ascend_uda | **不覆盖 -EAGAIN** | 让 ns_node 创建流程正常触发 |

> [!WARNING]
> Hook 4（`uda_occupy_dev_by_ns`）和 Hook 7（`uda_ns_node_devid_to_udevid`）的策略至关重要：
> - Hook 4 **不能**无条件返回 0，否则跳过 namespace 绑定 → Pod B 没有 ns_node → SQ 寄存器映射失败
> - Hook 7 **不能**覆盖 -EAGAIN，否则 `uda_setup_ns_node()` 永远不被调用 → ns_node 不创建

---

## 4. 源码

源码位于 [`src/npu_bypass/`](file:///Users/luogangyi/Code/cann/driver/src/npu_bypass)：

- [npu_bypass.c](file:///Users/luogangyi/Code/cann/driver/src/npu_bypass/npu_bypass.c) — kretprobe hook 实现（~230 行）
- [Makefile](file:///Users/luogangyi/Code/cann/driver/src/npu_bypass/Makefile)

---

## 5. 部署与使用

### 5.1 编译（在目标 ARM64 910B 机器上）

```bash
cd /root/npu_bypass
make
```

### 5.2 启用旁路

```bash
insmod /root/npu_bypass/npu_bypass.ko
```

### 5.3 关闭旁路

```bash
rmmod npu_bypass
```

### 5.4 开机自动加载

```bash
cp npu_bypass.ko /lib/modules/$(uname -r)/updates/
depmod -a
echo "npu_bypass" > /etc/modules-load.d/npu_bypass.conf
```

---

## 6. 风险与注意事项

> [!WARNING]
> 加载 `npu_bypass.ko` 后，驱动层不再对设备进行容器级别的独占保护：
> - 同一物理 NPU 可被不同容器的进程同时操作
> - 需要上层应用（如 xpushare）自行保证时分复用和资源安全
> - 不建议在非受控的多租户环境中使用

### 6.1 并发安全

kretprobe 机制本身是线程安全的（`maxactive=64`）。Hook 只修改返回值，不修改数据结构。

### 6.2 兼容性

- 依赖 `CONFIG_KPROBES=y`（已在目标内核确认）
- 依赖 `ascend_uda.ko` 和 `drv_devmng_host.ko` 中的符号可见性（已通过 kallsyms 确认）
- `rmmod npu_bypass` 可随时恢复原始行为

---

## 7. 验证方案

1. **单 Pod 测试**：加载 `npu_bypass.ko` 后，`npu-smi info` 正常
2. **跨 Pod 并发测试**：两个 Pod 分别运行 PyTorch 任务，不再报 error 87/507033
3. **卸载恢复测试**：`rmmod npu_bypass` 后，恢复隔离行为
