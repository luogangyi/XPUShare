# CANN 环境安装与测试记录（Dashboard）

## 目标

1. 构建并推送镜像到：
   `registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:<tag>`
2. 在 CANN 集群部署 Dashboard。
3. 使用 NodePort `32050` 暴露服务。
4. 验证可通过 `http://139.196.28.96:32050` 访问。

## 脚本

- 构建并推送镜像：
  [build_and_push_dashboard.sh](/Users/luogangyi/Code/nvshare/dashboard/scripts/build_and_push_dashboard.sh)
- 安装到 CANN 集群（NodePort 32050）：
  [install_cann_dashboard_nodeport.sh](/Users/luogangyi/Code/nvshare/dashboard/scripts/install_cann_dashboard_nodeport.sh)
- 连通性与接口测试：
  [test_cann_dashboard.sh](/Users/luogangyi/Code/nvshare/dashboard/scripts/test_cann_dashboard.sh)

## 操作步骤

1. 构建并推送镜像

```bash
cd /Users/luogangyi/Code/nvshare
./dashboard/scripts/build_and_push_dashboard.sh <tag>
```

2. 安装到 CANN 集群

```bash
cd /Users/luogangyi/Code/nvshare
./dashboard/scripts/install_cann_dashboard_nodeport.sh \
  registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:<tag>
```

脚本会自动探测 Prometheus 地址（优先 `cmss-kcs-prometheus-system.kube-system.svc:9090`）。
如需手动指定，可追加第二个参数：

```bash
./dashboard/scripts/install_cann_dashboard_nodeport.sh \
  registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:<tag> \
  http://cmss-kcs-prometheus-system.kube-system.svc:9090
```

> 如果环境里没有 `kubectl`，可指定例如：
>
> ```bash
> KUBECTL_BIN="k0s kubectl" ./dashboard/scripts/install_cann_dashboard_nodeport.sh <image>
> ```

3. 执行测试

```bash
cd /Users/luogangyi/Code/nvshare
./dashboard/scripts/test_cann_dashboard.sh http://139.196.28.96:32050
```

测试脚本默认会先测公网地址；若公网链路失败，会自动回退到 `kubectl port-forward` 继续完成功能验证并保存结果。

## 测试产物保存

测试脚本会将产物保存到：

- `/Users/luogangyi/Code/nvshare/dashboard/artifacts/<timestamp>-cann-dashboard-test/`

包含：

- `run.log`
- `kubectl_deploy.txt`
- `kubectl_pods.txt`
- `kubectl_svc.txt`
- `healthz.txt`
- `overview.txt`
- `nodes.txt`
- `pods.txt`

## 本次实际执行记录

- 执行日期：2026-03-13
- 分支：`dashboard`
- 代码提交：
  - `d7b2f76`（Dashboard 主体）
  - `46de863`（修复多架构镜像构建）
  - `8b6ef59`（增强安装/测试脚本，补充执行记录）
- 最终镜像：
  - `registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:v0.1-46de863`
- 部署结果：
  - `deployment/xpushare-dashboard` rollout 成功，`READY 1/1`
  - `service/xpushare-dashboard` 为 `NodePort`，端口 `80:32050/TCP`
- 连通性测试：
  - 公网地址 `http://139.196.28.96:32050/api/v1/healthz`：`curl (52) Empty reply from server`
  - 回退 `kubectl port-forward` 后接口验证通过：
    - `/api/v1/healthz` 返回 `{\"status\":\"ok\"...}`
    - `/api/v1/overview`、`/api/v1/nodes/xpushare`、`/api/v1/pods/xpushare` 均可成功返回 JSON
- 测试产物：
  - `/Users/luogangyi/Code/nvshare/dashboard/artifacts/20260313-101156-cann-dashboard-test/`
