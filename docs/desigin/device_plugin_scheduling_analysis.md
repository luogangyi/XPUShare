# Device Plugin 多 GPU 调度策略分析与设计

## 1. 现状分析

### 1.1 当前实现机制

目前的 Device Plugin 实现 (`server.go` 和 `devices.go`) 采用的是 **静态列表上报** 机制。

*   **设备生成 (`devices.go`)**: 双重循环生成设备列表。
    ```go
    for _, uuid := range UUIDs { // 物理 GPU 循环
        for j := 0; j < N; j++ { // 虚拟化循环
            devs = append(devs, generateDeviceID(uuid, j))
        }
    }
    ```
    生成的设备 ID 列表顺序是：`[GPU1_v1, GPU1_v2, ..., GPU1_vn, GPU2_v1, GPU2_v2, ...]`。

*   **Kubelet 调度行为**:
    *   Kubelet 在进行设备分配时，默认策略通常是从 `ListAndWatch` 上报的列表中**按顺序选择**处于 `Healthy` 状态的设备。
    *   由于我们的列表是按物理 GPU 聚合的，Kubelet 会优先填满第一个物理 GPU 的所有虚拟槽位，然后才开始分配第二个物理 GPU。
    *   **结论**: 当前代码**不支持**负载均衡，反而会导致仅仅使用第一个 GPU (Bin-packing 效果)，直到它被完全占满。这在资源争抢场景下是最差的策略。

### 1.2 `GetPreferredAllocation` 缺失

Device Plugin API 定义了 `GetPreferredAllocation` 接口，允许插件根据自定义逻辑（如拓扑、负载）给 Kubelet 推荐“最佳”设备。

目前 `server.go` 中未实现该逻辑（或返回空），导致 Kubelet 回退到默认的顺序分配策略。

## 2. 设计方案

为了实现多 GPU 间的负载均衡（让请求优先分布到不同的物理 GPU 上），我们需要实现 `GetPreferredAllocation` 接口。

### 2.1 方案 A: 基于分配数的静态负载均衡 (推荐)

此方案仅依赖 Kubelet 传入的 `AvailableDeviceIDs` 信息，不需要外部通信，实现简单且健壮。

**算法逻辑**:
当 Kubelet 请求 `GetPreferredAllocation`，并传入 `AvailableDeviceIDs`（当前空闲的设备列表）时：

1.  **分组**: 解析 `AvailableDeviceIDs`，将虚拟设备按其所属的物理 GPU UUID 分组。
2.  **计数**: 统计每个物理 GPU 当前**剩余**的空闲虚拟设备数量 (`FreeCount`)。
3.  **排序**: 将物理 GPU 按 `FreeCount` **降序**排序。
    *   `FreeCount` 越大，说明该 GPU 上已分配的任务越少（负载越低）。
4.  **选择**: 从排序后排名第一（最空闲）的物理 GPU 中，选取一个虚拟设备 ID 作为推荐结果返回。

**效果**:
*   假设有 GPU1, GPU2，各 10 个槽位。
*   Req 1: GPU1(10空), GPU2(10空) -> 随机或选 GPU1 -> 分配 GPU1_v1。
*   Req 2: GPU1(9空), GPU2(10空) -> 选 GPU2 (因为10>9) -> 分配 GPU2_v1。
*   Req 3: GPU1(9空), GPU2(9空) -> 选 GPU1 -> 分配 GPU1_v2。
*   **结果**:实现了 Round-Robin 效果，负载均匀分布。

### 2.2 方案 B: 基于实时负载的动态调度 (高级)

此方案需要 Device Plugin 与 `nvshare-scheduler` 通信，获取真实的 GPU 负载信息（如活跃进程数、GPU 利用率）。

**算法逻辑**:
1.  Device Plugin 在 `GetPreferredAllocation` 中，通过 Unix Socket 询问 Scheduler：“每个 UUID 当前有多少活跃进程？”
2.  Scheduler 返回各 UUID 的真实负载数据。
3.  Device Plugin 根据真实负载排序，选择负载最低的物理 GPU 对应的虚拟设备。

**优缺点**:
*   **优点**: 更精准。即使 GPU1 分配了 5 个 Pod 但都在休眠，GPU2 分配了 1 个 Pod 但在满载，该方案能正确调度到 GPU1。
*   **缺点**: 实现复杂，通过 Socket 同步调用可能增加延迟和故障点。鉴于 `nvshare` 的时间片轮转特性，方案 A 通常已经足够好。

## 3. 实现建议

建议优先实施 **方案 A**。

**修改点**:
1.  在 `server.go` 中实现 `GetPreferredAllocation` 方法。
2.  解析 ID 格式 (`UUID__Ordinal`) 的工具函数需要复用或提取。
3.  无需修改 `devices.go` 的列表生成逻辑，因为顺序已经不重要了。

## 4. 伪代码示例 (Go)

```go
func (m *NvshareDevicePlugin) GetPreferredAllocation(ctx context.Context, r *pluginapi.PreferredAllocationRequest) (*pluginapi.PreferredAllocationResponse, error) {
    resp := &pluginapi.PreferredAllocationResponse{}
    for _, req := range r.ContainerRequests {
        // 1. Group available devices by physical UUID
        uuidFreeCounts := make(map[string]int)
        uuidToDevices := make(map[string][]string)
        
        for _, devID := range req.AvailableDeviceIDs {
            uuid := parseUUID(devID)
            uuidFreeCounts[uuid]++
            uuidToDevices[uuid] = append(uuidToDevices[uuid], devID)
        }

        // 2. Find UUID with max free count (Least Allocated)
        var bestUUID string
        maxFree := -1
        
        for uuid, count := range uuidFreeCounts {
            if count > maxFree {
                maxFree = count
                bestUUID = uuid
            }
        }

        // 3. Return one device from the best bucket
        if bestUUID != "" {
            resp.ContainerResponses = append(resp.ContainerResponses, &pluginapi.ContainerPreferredAllocationResponse{
                DeviceIDs: []string{uuidToDevices[bestUUID][0]},
            })
        }
    }
    return resp, nil
}
```
