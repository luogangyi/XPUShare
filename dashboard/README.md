# XPUShare Dashboard

本目录提供一套可落地的 Dashboard 方案与实现骨架，目标是满足以下能力：

1. 动态调整 Pod 算力配额（`xpushare.com/gpu-core-limit`）和显存配额（`xpushare.com/gpu-memory-limit`）。
2. 显示当前 Pod 配额状态。
3. 查看集群内启用 xpushare 的节点，展示每节点：
   - 物理 GPU/NPU 数量
   - 节点运行时类型（`cuda`/`cann`）
   - 虚拟 GPU 总量、已分配、空闲
4. 查看虚拟 GPU 指标（数据从 Prometheus 读取）。
5. 同时支持集群内安装和集群外安装。
6. 前端不直连 K8s API/Prometheus，统一通过后端代理，规避跨域和凭据暴露。

## 架构设计

```text
Browser
  |
  | HTTPS
  v
XPUShare Dashboard Backend (Go)
  |---> Kubernetes API (list/get/patch pods, list nodes)
  |---> Prometheus HTTP API (/api/v1/query)
```

### 设计要点

1. 前后端同源部署，前端只访问 `/api/v1/*`。
2. 后端统一处理 K8s Token、TLS、Prometheus Token。
3. 配额更新通过 PATCH Pod Annotation 实现，和 scheduler 现有动态更新链路保持一致。
4. 节点概览基于 `xpushare.com/gpu` allocatable 识别 xpushare 节点。

## 目录结构

- `main.go`: 服务入口，内嵌前端静态资源。
- `internal/config`: 配置加载（in-cluster/external 双模式）。
- `internal/k8s`: Kubernetes API 客户端。
- `internal/prom`: Prometheus API 客户端。
- `internal/service`: 业务聚合层（节点、Pod、配额、指标）。
- `internal/httpapi`: REST API 路由。
- `web/`: Dashboard 前端页面（K8s 风格）。
- `deploy/incluster.yaml`: 集群内安装示例（Deployment+RBAC+Service）。
- `config/*.example.yaml`: 集群内/外配置示例。

## API 设计

- `GET /api/v1/healthz`
- `GET /api/v1/overview`
- `GET /api/v1/nodes/xpushare`
- `GET /api/v1/pods/xpushare`
- `PATCH /api/v1/pods/{namespace}/{pod}/quota`
  - Body:
    ```json
    {
      "coreLimit": 60,
      "memoryLimit": "4Gi"
    }
    ```
  - `memoryLimit` 传空字符串 `""` 表示删除该 annotation。
- `GET /api/v1/metrics/pod?namespace=<ns>&pod=<name>`
- `GET /api/v1/metrics/cards`
- `GET /api/v1/metrics/card/timeseries?gpuUUID=<uuid>&gpuIndex=<index>&minutes=60&stepSeconds=30`

## 运行方式

### 1) 本地调试（集群外）

```bash
cd dashboard
cp config/external.example.yaml config/config.yaml
# 编辑 config/config.yaml，填入 apiserver/token/prometheus
go run ./main.go -config ./config/config.yaml
```

访问：`http://127.0.0.1:8080`

### 2) 集群内部署

1. 构建镜像：

```bash
cd dashboard
docker build -t <your-registry>/xpushare-dashboard:latest .
docker push <your-registry>/xpushare-dashboard:latest
```

2. 修改 `deploy/incluster.yaml`：
- `image`
- `prometheus.baseURL`

3. 应用：

```bash
kubectl apply -f deploy/incluster.yaml
```

4. 访问：

```bash
kubectl -n xpushare-system port-forward svc/xpushare-dashboard 8080:80
```

### 3) 手动部署（不使用脚本）

完整步骤（含 Prometheus 抓取配置、NodePort `32050` 暴露、验证与排障）见：

- [docs/manual_install.md](docs/manual_install.md)

## 自动化脚本

说明：以下涉及端口（如 `32050`）和地址的示例都需要替换成你的实际值。

- 构建并推送镜像：
  [scripts/build_and_push_dashboard.sh](scripts/build_and_push_dashboard.sh)
- CANN 集群安装（NodePort 32050）：
  [scripts/install_cann_dashboard_nodeport.sh](scripts/install_cann_dashboard_nodeport.sh)
- CANN 环境连通性与接口测试：
  [scripts/test_cann_dashboard.sh](scripts/test_cann_dashboard.sh)
- NodePort 诊断：
  [scripts/diagnose_nodeport.sh](scripts/diagnose_nodeport.sh)
- 公网 32050 连通性修复：
  [scripts/repair_32050_connectivity.sh](scripts/repair_32050_connectivity.sh)
- CANN 安装测试文档：
  [docs/cann_install_test.md](docs/cann_install_test.md)
- 手动安装文档（不使用脚本）：
  [docs/manual_install.md](docs/manual_install.md)
- NodePort 连通性运行手册：
  [docs/nodeport_connectivity_runbook.md](docs/nodeport_connectivity_runbook.md)

## 配置说明

### Kubernetes 配置

- `mode: incluster|external|auto`
- `apiServer`: external 模式必填
- `token` 或 `tokenFile`
- `caFile`
- `insecureSkipTLSVerify`

### Prometheus 配置

- `baseURL`
- `token` 或 `tokenFile`
- `timeoutSec`

## 我补充的关键需求（建议纳入正式需求）

1. **权限模型**：应支持只读角色与运维角色分离（只读可看，运维可改配额）。
2. **审计日志**：配额变更需记录操作者、时间、旧值、新值。
3. **多集群支持**：生产通常不止一个集群，建议后端支持多集群数据源。
4. **高可用**：Dashboard 至少双副本，配合 Ingress + HPA。
5. **安全**：
   - 外部模式 token 禁止明文写入仓库，建议来自 Secret 或外部密钥系统。
   - Prometheus 若启用鉴权，必须支持 Bearer Token/MTLS。
6. **性能目标**：定义刷新频率、最大节点/Pod规模、接口延迟 SLO。
7. **告警闭环**：建议在 UI 中联动阈值告警（显存超限、长期 throttled、队列拥塞）。
8. **兼容性边界**：明确 CANN 资源名规范（不同集群厂商资源 key 可能不同）。

## 已知限制

1. 节点 `cuda/cann` 识别基于资源键推断，若集群资源键自定义，需按实际补充映射规则。
2. 当前指标页展示的是 Pod 级聚合值，尚未内建时序图与历史回放。
3. 默认未接入统一登录（OIDC），如面向多租户需在入口层补鉴权。
