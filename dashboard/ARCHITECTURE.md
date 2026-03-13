# Dashboard 方案说明

## 1. 目标映射

| 需求 | 实现方案 |
| --- | --- |
| 动态调整 Pod 算力/显存 | 后端 `PATCH /api/v1/pods/{ns}/{pod}/quota` -> Pod annotations |
| 显示当前 Pod 配额 | `GET /api/v1/pods/xpushare` 返回当前 annotation 值 |
| 查看 xpushare 节点与资源 | `GET /api/v1/nodes/xpushare` 聚合 Node + Pod 分配情况 |
| 查看虚拟 GPU 指标 | `GET /api/v1/metrics/pod` 由后端查询 Prometheus |
| 支持集群内/外安装 | `kubernetes.mode` + `config/*.example.yaml` |
| 规避跨域 | 前端仅访问同源后端 API，后端代理 K8s/Prometheus |

## 2. 数据来源

1. Kubernetes API
   - `GET /api/v1/nodes`
   - `GET /api/v1/pods`
   - `PATCH /api/v1/namespaces/{ns}/pods/{name}`
2. Prometheus API
   - `GET /api/v1/query`

## 3. 关键计算逻辑

### 3.1 xpushare 节点识别

- `node.status.allocatable["xpushare.com/gpu"] > 0` 视为启用 xpushare。

### 3.2 节点运行时识别（cuda/cann）

- 优先检查 `nvidia.com/gpu` -> `cuda`
- 否则检查常见 Ascend/NPU 资源键 -> `cann`
- 若都不命中 -> `unknown`

### 3.3 虚拟 GPU 已分配数

- 按节点汇总非终态 Pod（非 Succeeded/Failed）中 `limits/requests["xpushare.com/gpu"]`。

## 4. 安全与权限

1. 集群内模式
   - 自动读取 ServiceAccount token、CA、APIServer。
2. 集群外模式
   - 配置文件显式提供 APIServer/token/CA。
3. RBAC 最小权限
   - `nodes`: `get/list/watch`
   - `pods`: `get/list/watch/patch`

## 5. 建议后续增强

1. 接入 OIDC 与细粒度 RBAC（只读/运维）。
2. 配额变更审计（谁改的、改了什么、何时改）。
3. 支持多 Prometheus、多集群数据源。
4. 指标页增加时间序列与告警状态联动。
5. 节点 runtime 识别支持可配置映射表。
