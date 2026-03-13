# XPUShare Dashboard 手动安装部署（不使用脚本）

本文档给出不依赖 `dashboard/scripts/*.sh` 的手动部署流程，覆盖：

- 集群内安装（推荐，使用 ServiceAccount 自动获取 K8s API 凭据）
- Prometheus 采集与配置
- NodePort `32050` 暴露
- 基础连通性与指标验证
- 集群外安装（external 模式）

## 0. 前置条件

1. 已有可用 Kubernetes 集群访问权限（`kubectl` 可用）。
2. `xpushare-scheduler` 已部署在 `xpushare-system` 命名空间。
3. 已构建并推送 dashboard 镜像，例如：
   `registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:v0.1-8081c64`

可选：切换 kubeconfig（CANN 环境示例）：

```bash
export KUBECONFIG=~/Code/configs/kubeconfig-kcs-npu
```

## 1. 确认 Prometheus 地址

先找集群里实际可用的 Prometheus Service 地址，不要写死旧地址。

```bash
kubectl get svc -A | grep -Ei 'prometheus|thanos'
```

本项目当前 CANN 集群实测可用地址为：

```text
http://cmss-kcs-prometheus-system.kube-system.svc:9090
```

可验证是否可查询：

```bash
kubectl -n kube-system port-forward svc/cmss-kcs-prometheus-system 19090:9090
curl -s 'http://127.0.0.1:19090/api/v1/query?query=up' | head
```

## 2. 配置 Prometheus 抓取 xpushare 指标

### 2.1 创建 scheduler metrics Service + ServiceMonitor

如果集群安装了 Prometheus Operator（存在 ServiceMonitor CRD）：

```bash
kubectl get crd servicemonitors.monitoring.coreos.com
kubectl apply -f /Users/luogangyi/Code/nvshare/dashboard/deploy/xpushare-scheduler-metrics.yaml
```

创建后确认：

```bash
kubectl -n xpushare-system get svc xpushare-scheduler-metrics
kubectl -n xpushare-system get servicemonitor xpushare-scheduler
```

### 2.2 验证 Prometheus 已采集到 xpushare 指标

```bash
kubectl -n kube-system port-forward svc/cmss-kcs-prometheus-system 19090:9090
curl -s 'http://127.0.0.1:19090/api/v1/query?query=count(xpushare_client_info)'
curl -s 'http://127.0.0.1:19090/api/v1/query?query=up{namespace="xpushare-system",service="xpushare-scheduler-metrics"}'
```

预期：

- `count(xpushare_client_info)` 返回非 0
- `up{...service="xpushare-scheduler-metrics"}` 返回 `1`

### 2.3 无 ServiceMonitor CRD 的情况

若 `servicemonitors.monitoring.coreos.com` 不存在，需要在 Prometheus 自身配置里增加 scrape job（示例）：

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

然后 reload Prometheus 配置，并重复 2.2 验证。

## 3. 手动部署 Dashboard（集群内模式）

### 3.1 准备清单

编辑文件：
[incluster.yaml](/Users/luogangyi/Code/nvshare/dashboard/deploy/incluster.yaml)

至少修改两处：

1. `Deployment.spec.template.spec.containers[0].image`
2. `ConfigMap.data.config.yaml` 中 `prometheus.baseURL`

建议值（当前 CANN 集群）：

```yaml
prometheus:
  baseURL: "http://cmss-kcs-prometheus-system.kube-system.svc:9090"
  timeoutSec: 10
```

### 3.2 应用部署

```bash
kubectl get ns xpushare-system >/dev/null 2>&1 || kubectl create ns xpushare-system
kubectl apply -f /Users/luogangyi/Code/nvshare/dashboard/deploy/incluster.yaml
kubectl -n xpushare-system rollout status deployment/xpushare-dashboard --timeout=180s
```

## 4. 暴露 NodePort 32050

默认 `incluster.yaml` 里 Service 是 `ClusterIP`，需要手动改为 NodePort：

```bash
kubectl -n xpushare-system patch svc xpushare-dashboard --type merge -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":"http","nodePort":32050}]}}'
```

验证：

```bash
kubectl -n xpushare-system get svc xpushare-dashboard -o wide
```

预期端口显示 `80:32050/TCP`。

## 5. 部署后验证（API）

### 5.1 健康检查与概览

```bash
curl -s http://139.196.28.96:32050/api/v1/healthz
curl -s http://139.196.28.96:32050/api/v1/overview
```

### 5.2 节点与 Pod 列表

```bash
curl -s http://139.196.28.96:32050/api/v1/nodes/xpushare
curl -s http://139.196.28.96:32050/api/v1/pods/xpushare
```

### 5.3 Pod 监控指标

```bash
curl -s 'http://139.196.28.96:32050/api/v1/metrics/pod?namespace=default&pod=<pod-name>'
```

返回 JSON 中应有 `values` 字段；若出现 `errors`，通常是 Prometheus 地址/抓取配置问题。

## 6. 集群外安装（external 模式）

编辑外部配置文件：
[external.example.yaml](/Users/luogangyi/Code/nvshare/dashboard/config/external.example.yaml)

示例：

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
  baseURL: "http://cmss-kcs-prometheus-system.kube-system.svc:9090"
  tokenFile: "/etc/xpushare-dashboard/prom.token"
  timeoutSec: 10
```

运行方式（二选一）：

```bash
# 本地运行
cd /Users/luogangyi/Code/nvshare/dashboard
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
   - 检查 `prometheus.baseURL` 是否可从 dashboard Pod 内访问。
   - 检查 `count(xpushare_client_info)` 是否非 0。
   - 检查 `up{service="xpushare-scheduler-metrics"}` 是否为 `1`。

2. `NodeIP:32050` 不通但 `ClusterIP:80` 可通
   - 先按运行手册排查：
     [nodeport_connectivity_runbook.md](/Users/luogangyi/Code/nvshare/dashboard/docs/nodeport_connectivity_runbook.md)

3. 只有 `exported_namespace/exported_pod` 标签
   - 当前 dashboard 已兼容 `namespace/pod` 与 `exported_namespace/exported_pod` 双标签查询。
