# XPUShare Dashboard 手动安装部署（不使用脚本）

本文档给出不依赖 `dashboard/scripts/*.sh` 的手动部署流程，覆盖：

- 集群内安装（推荐，使用 ServiceAccount 自动获取 K8s API 凭据）
- Prometheus 采集与配置
- NodePort 暴露
- 基础连通性与指标验证
- 集群外安装（external 模式）

## 0. 前置条件与变量

1. 已有可用 Kubernetes 集群访问权限（`kubectl` 可用）。
2. `xpushare-scheduler` 已部署在 `xpushare-system` 命名空间。
3. 已构建并推送 dashboard 镜像，例如：
   `registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:v0.1-8081c64`

建议先设置以下变量。文档中所有地址和端口示例都需要替换为你的实际值。

```bash
export DASHBOARD_NAMESPACE=xpushare-system
export DASHBOARD_NODEPORT=32050        # 改成你的 NodePort
export DASHBOARD_HOST="your-dashboard-host" # 改成你的访问地址（IP 或域名）

export PROM_NAMESPACE=kube-system
export PROM_SERVICE=cmss-kcs-prometheus-system   # 改成你的 Prometheus Service 名称
export PROM_PORT=9090
export PROM_BASE_URL="http://${PROM_SERVICE}.${PROM_NAMESPACE}.svc:${PROM_PORT}"
```

可选：切换 kubeconfig（示例）：

```bash
export KUBECONFIG=~/Code/configs/kubeconfig-kcs-npu
```

## 1. 确认 Prometheus 地址

先找集群里实际可用的 Prometheus Service 地址，不要直接复用历史地址：

```bash
kubectl get svc -A | grep -Ei 'prometheus|thanos'
```

验证可查询：

```bash
kubectl -n "${PROM_NAMESPACE}" port-forward "svc/${PROM_SERVICE}" 19090:${PROM_PORT}
curl -s 'http://127.0.0.1:19090/api/v1/query?query=up' | head
```

## 2. 配置 Prometheus 抓取 xpushare 指标

### 2.1 Prometheus Operator 场景（推荐）

1. 确认存在 ServiceMonitor CRD：

```bash
kubectl get crd servicemonitors.monitoring.coreos.com
```

2. 创建 xpushare 的 metrics Service 和 ServiceMonitor：

```bash
kubectl apply -f dashboard/deploy/xpushare-scheduler-metrics.yaml
kubectl -n "${DASHBOARD_NAMESPACE}" get svc xpushare-scheduler-metrics
kubectl -n "${DASHBOARD_NAMESPACE}" get servicemonitor xpushare-scheduler
```

3. 需要调整抓取参数（如 `interval/path`）时，直接编辑 ServiceMonitor：

```bash
kubectl -n "${DASHBOARD_NAMESPACE}" edit servicemonitor xpushare-scheduler
```

4. 若 ServiceMonitor 已创建但仍未被 Prometheus 发现，检查并编辑 Prometheus CR 选择器：

```bash
# 当前集群对象示例：kube-system/cmss-kcs-prometheus
kubectl -n "${PROM_NAMESPACE}" edit prometheus cmss-kcs-prometheus
```

重点检查字段：

- `spec.serviceMonitorNamespaceSelector`
- `spec.serviceMonitorSelector`

### 2.2 非 Operator 场景（原生 Prometheus）

1. 找到 Prometheus 配置 ConfigMap：

```bash
kubectl -n "${PROM_NAMESPACE}" get configmap | grep -Ei 'prometheus.*(config|server)'
```

2. 编辑该 ConfigMap（把 `<PROM_CONFIGMAP>` 替换为实际名称）：

```bash
kubectl -n "${PROM_NAMESPACE}" edit configmap <PROM_CONFIGMAP>
```

在 `prometheus.yml` 的 `scrape_configs` 下增加：

```yaml
- job_name: xpushare-scheduler-metrics
  kubernetes_sd_configs:
    - role: endpoints
      namespaces:
        names:
          - xpushare-system
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
      action: keep
      regex: xpushare-scheduler-metrics;metrics
```

3. 让配置生效（按你的部署类型选择其一）：

```bash
kubectl -n "${PROM_NAMESPACE}" rollout restart deployment/<PROM_DEPLOYMENT>
```

```bash
kubectl -n "${PROM_NAMESPACE}" rollout restart statefulset/<PROM_STATEFULSET>
```

### 2.3 验证采集是否生效

```bash
kubectl -n "${PROM_NAMESPACE}" port-forward "svc/${PROM_SERVICE}" 19090:${PROM_PORT}
curl -s 'http://127.0.0.1:19090/api/v1/query?query=count(xpushare_client_info)'
curl -s 'http://127.0.0.1:19090/api/v1/query?query=up{namespace="xpushare-system",service="xpushare-scheduler-metrics"}'
```

预期：

- `count(xpushare_client_info)` 返回非 0
- `up{...service="xpushare-scheduler-metrics"}` 返回 `1`

## 3. 手动部署 Dashboard（集群内模式）

### 3.1 初次部署（编辑清单）

编辑文件 `dashboard/deploy/incluster.yaml`，至少修改两处：

1. `Deployment.spec.template.spec.containers[0].image`
2. `ConfigMap.data.config.yaml` 中 `prometheus.baseURL`（改成你的 `PROM_BASE_URL`）

应用部署：

```bash
kubectl get ns "${DASHBOARD_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${DASHBOARD_NAMESPACE}"
kubectl apply -f dashboard/deploy/incluster.yaml
kubectl -n "${DASHBOARD_NAMESPACE}" rollout status deployment/xpushare-dashboard --timeout=180s
```

### 3.2 已部署后修改 Prometheus 地址（kubectl edit）

如果 dashboard 已经跑起来，不想改 YAML 重装，可直接编辑运行中配置：

```bash
kubectl -n "${DASHBOARD_NAMESPACE}" edit configmap xpushare-dashboard-config
```

在 `config.yaml` 里修改：

```yaml
prometheus:
  baseURL: "http://<your-prometheus-service>.<your-prometheus-namespace>.svc:9090"
```

然后重启 dashboard 让配置生效：

```bash
kubectl -n "${DASHBOARD_NAMESPACE}" rollout restart deployment/xpushare-dashboard
kubectl -n "${DASHBOARD_NAMESPACE}" rollout status deployment/xpushare-dashboard --timeout=180s
```

## 4. 暴露 NodePort

`incluster.yaml` 默认是 `ClusterIP`，需要手动改成 NodePort（端口改成你的实际值）：

```bash
kubectl -n "${DASHBOARD_NAMESPACE}" patch svc xpushare-dashboard --type merge -p \
  "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"http\",\"port\":80,\"targetPort\":\"http\",\"nodePort\":${DASHBOARD_NODEPORT}}]}}"
```

验证：

```bash
kubectl -n "${DASHBOARD_NAMESPACE}" get svc xpushare-dashboard -o wide
```

预期端口显示为 `80:${DASHBOARD_NODEPORT}/TCP`。

## 5. 部署后验证（API）

以下 URL 里的 `${DASHBOARD_HOST}` 与 `${DASHBOARD_NODEPORT}` 要替换为你的地址和端口。

### 5.1 健康检查与概览

```bash
curl -s "http://${DASHBOARD_HOST}:${DASHBOARD_NODEPORT}/api/v1/healthz"
curl -s "http://${DASHBOARD_HOST}:${DASHBOARD_NODEPORT}/api/v1/overview"
```

### 5.2 节点与 Pod 列表

```bash
curl -s "http://${DASHBOARD_HOST}:${DASHBOARD_NODEPORT}/api/v1/nodes/xpushare"
curl -s "http://${DASHBOARD_HOST}:${DASHBOARD_NODEPORT}/api/v1/pods/xpushare"
```

### 5.3 Pod 监控指标

```bash
curl -s "http://${DASHBOARD_HOST}:${DASHBOARD_NODEPORT}/api/v1/metrics/pod?namespace=default&pod=<pod-name>"
```

返回 JSON 中应有 `values` 字段；若出现 `errors`，通常是 Prometheus 地址或抓取配置问题。

## 6. 集群外安装（external 模式）

编辑外部配置文件 `dashboard/config/external.example.yaml`（另存为你自己的 `config.yaml`）：

```yaml
server:
  listenAddr: ":8080"

kubernetes:
  mode: "external"
  apiServer: "https://<your-apiserver>:6443"
  tokenFile: "/etc/xpushare-dashboard/k8s.token"
  caFile: "/etc/xpushare-dashboard/ca.crt"
  insecureSkipTLSVerify: false

prometheus:
  baseURL: "http://<your-prometheus-service>.<your-prometheus-namespace>.svc:9090"
  tokenFile: "/etc/xpushare-dashboard/prom.token"
  timeoutSec: 10
```

运行方式（二选一）：

```bash
# 本地运行
cd dashboard
go run ./main.go -config ./config/config.yaml
```

```bash
# 容器运行
docker run --rm -p 8080:8080 \
  -v /path/config.yaml:/etc/xpushare-dashboard/config.yaml:ro \
  -v /path/k8s.token:/etc/xpushare-dashboard/k8s.token:ro \
  -v /path/ca.crt:/etc/xpushare-dashboard/ca.crt:ro \
  registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:v0.1-8081c64 \
  -config /etc/xpushare-dashboard/config.yaml
```

## 7. 常见问题排查

1. Dashboard 无监控数据
   - 检查 `xpushare-dashboard-config` 里的 `prometheus.baseURL` 是否正确。
   - 检查 `count(xpushare_client_info)` 是否非 0。
   - 检查 `up{service="xpushare-scheduler-metrics"}` 是否为 `1`。

2. `NodeIP:${DASHBOARD_NODEPORT}` 不通但 `ClusterIP:80` 可通
   - 按运行手册排查：`dashboard/docs/nodeport_connectivity_runbook.md`

3. 只有 `exported_namespace/exported_pod` 标签
   - 当前 dashboard 已兼容 `namespace/pod` 与 `exported_namespace/exported_pod` 双标签查询。
