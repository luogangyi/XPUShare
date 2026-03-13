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
  registry.cn-hangzhou.aliyuncs.com/xpushare/xpushare-dashboard:<tag> \
  http://prometheus-k8s.monitoring.svc:9090
```

3. 执行测试

```bash
cd /Users/luogangyi/Code/nvshare
./dashboard/scripts/test_cann_dashboard.sh http://139.196.28.96:32050
```

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

本节由本次发布执行后补充，记录最终镜像 tag、kubectl rollout 状态和接口测试结果。
