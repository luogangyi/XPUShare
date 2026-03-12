# CANN 显存超分（类 CUDA UVM）深入分析与实现方案

## 1. 背景与目标

目标是在 CANN/Ascend 上实现与 CUDA `cuMemAllocManaged` 类似的“可超物理显存申请 + 按需迁移”能力，且保持与当前 xpushare 调度/配额链路兼容。

本方案聚焦：

- 对用户透明（继续使用 `aclrtMalloc*` / torch_npu 常规路径）。
- 支持“申请量超过单卡 HBM”的运行能力。
- 保持 xpushare 当前的调度锁与配额控制模型。
- 补齐可观测性，区分“申请量”和“驻留/迁移行为”。

不在本阶段目标内：

- 强一致的“每进程真实驻留字节”精确值（CANN 当前公开接口难以直接给出逐进程驻留字节）。
- 通过 SVM cgroup 实现硬性内存封顶（当前开源实现存在空实现，见第 2.6 节）。

---

## 2. 基于 CANN 源码的关键事实链

### 2.1 ACL 默认分配路径不是 SVM managed 路径

1) `aclrtMalloc` 默认调用 `rtMalloc`，不是 `rtMemAllocManaged`：

- `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:178`
- `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:220`

2) `rtMalloc` 走 `ApiImpl::DevMalloc`：

- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api/api_c_memory.cc:51`
- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api/api_c_memory.cc:59`

3) `ApiImpl::DevMalloc` 最终调用 `Driver->DevMemAlloc`：

- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:7965`
- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:8039`

4) `DevMemAlloc` 在线路径会落到 `DevMemAllocManaged(...)`（注意这是 Driver 内部函数名，不等于 managed API），其 flag 多数是 `MEM_DEV|MEM_TYPE_HBM`：

- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:1176`
- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:1210`

结论：**当前 ACL 默认内存路径并不等价 CUDA UVM managed 分配。**

### 2.2 CANN 确实提供了独立的 managed/SVM API 路径

1) runtime 头文件存在 managed API：

- `/Users/luogangyi/Code/cann/runtime/pkg_inc/runtime/runtime/mem.h:497` (`rtMemAllocManaged`)
- `/Users/luogangyi/Code/cann/runtime/pkg_inc/runtime/runtime/mem.h:506` (`rtMemFreeManaged`)
- `/Users/luogangyi/Code/cann/runtime/pkg_inc/runtime/runtime/mem.h:40` (`RT_MEMORY_SVM`)
- `/Users/luogangyi/Code/cann/runtime/pkg_inc/runtime/runtime/mem.h:143` (`RT_MEMCPY_MANAGED`)

2) `rtMemAllocManaged` 调用链：

- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api/api_c.cc:917`
- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:2587`
- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:2051`

3) 该 managed 链路最终使用 `MEM_SVM_HUGE/MEM_SVM_NORMAL`：

- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:2072`
- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:2077`
- `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:2094`

结论：**CANN 在 runtime/driver 层具备 SVM managed 分配能力，能作为类 UVM 的核心实现基础。**

### 2.3 driver 层支持 prefetch/advise，但语义需谨慎使用

- `drvMemPrefetchToDevice`：
  - 声明：`/Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h:2182`
  - 实现要求 SVM 地址：`/Users/luogangyi/Code/cann/driver/src/ascend_hal/svm/v2/devmm/devmm_svm.c:1453`

- `halMemAdvise`：
  - 声明：`/Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h:2482`
  - 实现：`/Users/luogangyi/Code/cann/driver/src/ascend_hal/svm/v2/devmm/devmm_svm.c:3991`

- runtime 对应封装：
  - `rtMemPrefetchToDevice`：`/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api/api_c.cc:1044`
  - `rtMemAdvise`：`/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api/api_c.cc:945`

注意：`rtMemAdvise` 在 runtime 有特性门控（`RT_FEATURE_MEM_L2_CACHE_PERSISTANT`），因此其跨版本/跨芯片行为应视为“可选增强”，不能作为核心路径强依赖。

### 2.4 TS/默认内存类型策略对 910B 是静态 HBM

- `Runtime::GetTsMemType` 静态模式返回 `RT_MEMORY_HBM`：
  - `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/runtime.cc:4627`
  - `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/runtime.cc:4633`

- 910B 平台属性为 `GET_TS_MEM_TYPE_STATIC`：
  - `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/platform/910_B_93/dev_info_reg.cc:237`

结论：不能把“TS 或默认分配”误认为 managed/SVM。

### 2.5 可观测性方面，存在 managed 位置与页故障计数能力

- 指针属性可区分 `DV_MEM_SVM/DV_MEM_SVM_DEVICE/DV_MEM_SVM_HOST`：
  - `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:2495`
  - `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:2584`

- 可获取 page fault count：
  - `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:5356`
  - runtime 周期检测：`/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/runtime.cc:5489`

### 2.6 SVM cgroup 在开源代码里是空实现

- `/Users/luogangyi/Code/cann/driver/src/sdk_driver/svm/v2/master/comm/svm_master_cgroup.c:20`
- `/Users/luogangyi/Code/cann/driver/src/sdk_driver/svm/v2/master/comm/svm_master_cgroup.c:25`

即：当前开源版本不应假设可以依赖 SVM cgroup 做强硬配额治理。

---

## 3. xpushare 当前实现与目标差距

当前 xpushare NPU hook 已拦截 `aclrtMalloc*`，但仍直接调用 `real_aclrtMalloc*`：

- `/Users/luogangyi/Code/xpushare/src/hook.c:2311`
- `/Users/luogangyi/Code/xpushare/src/hook.c:2399`

这意味着：

- 调度器看到的是“申请量口径”（`sum_allocated`），不是 managed/SVM 迁移后驻留口径。
- 即便开启 oversub admission，底层分配仍可能走 HBM 路径，行为与 CUDA UVM 不同。

此外，当前 NPU 头定义未声明 `rtMemAllocManaged/rtMemFreeManaged/rtMemPrefetchToDevice/rtMemAdvise`，无法直接走 managed 路径：

- `/Users/luogangyi/Code/xpushare/src/npu_defs.h`

---

## 4. 推荐实现方案（分阶段）

## 4.1 Phase A（必须）：`aclrtMalloc* -> rtMemAllocManaged` 主路径改造

### 4.1.1 设计原则

- 默认启用“托底可回退”：若任一关键 symbol 不可用，则自动回退到原 ACL 分配路径。
- 只改“用户可见大块分配”路径，不触碰 runtime 内部大量 `rtMalloc` 使用点，避免破坏 CANN 自身内部生命周期。
- 配置开关可一键关闭，便于线上回退。

### 4.1.2 具体改造点

1) 新增 runtime 符号绑定（`RTLD_NEXT`）：

- `rtMemAllocManaged`
- `rtMemFreeManaged`
- `rtMemPrefetchToDevice`（可选）
- `rtMemAdvise`（可选）

2) `aclrtMalloc/aclrtMallocAlign32/aclrtMallocCached` 拦截逻辑：

- 优先调用 `rtMemAllocManaged(devPtr, aligned_size, RT_MEMORY_SVM, module_id)`。
- 若失败或 symbol 缺失，回退 `real_aclrtMalloc*`。

3) `aclrtMallocWithCfg`：

- **Phase A 默认回退原实现**（因 cfg 结构跨版本差异大，且当前 xpushare 不引入 CANN 头）。
- 在 metadata 中记录 fallback 原因，便于后续 Phase C 增强。

4) `aclrtFree`：

- 按分配 metadata 判断：managed 分配走 `rtMemFreeManaged`；否则走 `real_aclrtFree`。

5) 分配元数据扩展：

- `alloc_api`：`managed_rt` / `acl_native`
- `requested_size`
- `effective_size`
- `alloc_ts`
- `managed_prefetch_state`

### 4.1.3 对齐策略

为了兼容 ACL 现有行为，保留 `aclrtMalloc*` 的 size 对齐语义：

- 参考 `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:134`。
- 继续按 32 字节对齐和 padding 规则计算 `effective_size`，再传给 managed 分配。

### 4.1.4 开关与回退

建议新增：

- `XPUSHARE_NPU_OVERSUB_ALLOC_MODE`：`managed`(默认) / `acl`
- `XPUSHARE_NPU_MANAGED_FALLBACK`：`1`(默认，失败回退) / `0`(失败即报错)

---

## 4.2 Phase B（建议）：迁移增强（prefetch 优先）

核心目标是降低首轮 page fault 抖动，不把它作为功能正确性依赖。

1) 在获得调度锁后（`LOCK_OK` 后首个计算前）对热点分配调用 `rtMemPrefetchToDevice`。

2) 不默认依赖 `rtMemAdvise` 做“驱逐到 Host”语义（跨芯片/版本语义不稳定，且 runtime 有 feature gate）。

3) 若 `prefetch` 不可用，功能仍正确，仅性能退化。

建议新增：

- `XPUSHARE_NPU_PREFETCH_ENABLE=1`
- `XPUSHARE_NPU_PREFETCH_MIN_BYTES`（小对象不 prefetch）
- `XPUSHARE_NPU_PREFETCH_MAX_OPS_PER_CYCLE`（避免控制面抖动）

---

## 4.3 Phase C（增强）：覆盖更广调用路径

在不破坏兼容性的前提下逐步覆盖：

- `aclrtMallocWithCfg` 的受控 managed 化（仅识别到安全 cfg 组合时切换）。
- 可选拦截 `rtMemAllocManaged` 直调用路径，保证统计一致性。

不建议拦截通用 `rtMalloc` 并强制改 managed，因为 runtime 内部大量基础设施分配也走该接口，风险高。

---

## 5. 可观测性设计（必须落地）

### 5.1 指标分层

必须明确三层口径：

1) `allocated_bytes`：应用申请量（xpushare 当前已有，来自 hook metadata）。
2) `managed_bytes`：走 managed 路径的申请量子集。
3) `residency_signal`：迁移/故障信号（如 prefetch 调用计数、page fault count 增量）。

### 5.2 建议新增指标

- `xpushare_client_npu_alloc_mode{mode}` gauge
- `xpushare_client_npu_managed_allocated_bytes` gauge
- `xpushare_client_npu_native_allocated_bytes` gauge
- `xpushare_client_npu_managed_alloc_fallback_total{reason}` counter
- `xpushare_client_npu_prefetch_total{result}` counter
- `xpushare_client_npu_page_fault_delta` gauge/counter（可通过 driver/runtime 能力采样）

### 5.3 驻留口径说明

由于 CANN 当前公开接口不直接提供“逐进程实时驻留字节”标准口径，文档和监控需明确：

- `managed_allocated_bytes` 是“申请侧”而非“实时驻留侧”。
- page fault/prefetch 作为迁移行为代理信号，不直接等同驻留大小。

---

## 6. 与配额/调度链路的关系

### 6.1 内存配额

- 调度器继续以 `MEM_UPDATE` 申请量口径做 admission（当前机制不变）。
- managed 化后，可在不改调度协议的情况下提升“超物理分配可运行性”。

### 6.2 算力配额

- 不改现有 `core limit` 控制逻辑。
- 但需在性能分析中区分“配额导致慢”与“page fault 导致慢”。

### 6.3 内存水位保护

- 建议保留现有 `high/low` 水位保护作为兜底（防止迁移风暴导致抖动放大）。

---

## 7. 测试与验收标准

## 7.1 功能验收

1) 单任务超分：申请量 > 单卡物理 HBM，任务可运行且不立即 OOM。
2) 多任务同卡：2/4/8 并发下，任务均可完成，且无系统级崩溃。
3) fallback 验证：禁用 managed symbol 或注入失败时可自动回落到 ACL 原路径。

## 7.2 观测验收

1) 新增指标可被 Prometheus 抓取。
2) 能区分 managed/native 分配量。
3) page fault/prefetch 指标在超分压力场景有显著变化。

## 7.3 性能验收

1) 非超分场景：与当前版本相比单任务退化可控（目标 < 5%，超阈值需排查）。
2) 超分场景：相较原 ACL 路径“直接失败/OOM”，managed 路径能完成任务；吞吐波动需给出可解释指标（page fault/prefetch）。

---

## 8. 风险与规避

1) **CANN 版本符号差异**
- 风险：`rtMemAllocManaged` 等符号缺失或 ABI 变化。
- 规避：运行时探测 + fallback，严格日志标注。

2) **`aclrtMallocWithCfg` 兼容性风险**
- 风险：cfg 语义复杂，强改造可能破坏框架。
- 规避：Phase A 先回退原路径，后续白名单增强。

3) **驻留不可直接精确观测**
- 风险：用户误把申请量当驻留量。
- 规避：指标分层 + 文档说明 + page fault/prefetch 代理信号。

4) **SVM cgroup 不可依赖**
- 风险：误以为内核侧可做强硬限流。
- 规避：继续以 scheduler admission + 水位保护为主。

---

## 9. 实施里程碑

### M1（1~2 天）

- 完成符号绑定与 `aclrtMalloc*` managed 主路径。
- 完成 `aclrtFree` 双路径释放。
- 完成 fallback 与基础日志。

### M2（1~2 天）

- 新增 managed/native 指标。
- 加入 prefetch 可选增强。
- 完成最小回归（smoke + perf 基线）。

### M3（2~3 天）

- 完成 `aclrtMallocWithCfg` 白名单增强（可选）。
- 完成多并发长稳压测与文档固化。

---

## 10. 最终结论

结合当前 `/Users/luogangyi/Code/cann` 的 driver/runtime 源码，CANN 在技术上具备“类 CUDA UVM”能力基础，但 **必须把 xpushare 的 NPU 分配入口从 `aclrtMalloc` 默认链路切换到 `rtMemAllocManaged` 链路**，才能真正实现可用的显存超分。

推荐按本方案分阶段落地：先做“可运行 + 可回退 + 可观测”的最小闭环（Phase A），再做迁移优化与高级兼容（Phase B/C）。
