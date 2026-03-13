# NodePort 32050 连通性排障与修复

## 结论先行

如果 `ClusterIP:80` 可访问，但 `NodeIP:32050` 不可访问，才是 NodePort 规则问题。  
如果 `NodeIP:32050` 在集群内可访问，但公网 `139.196.28.96:32050` 不可访问，问题在公网映射/隧道层，不在 Kubernetes Service。

## 一键诊断

```bash
cd /Users/luogangyi/Code/nvshare
export KUBECONFIG=~/Code/configs/kubeconfig-kcs-npu
./dashboard/scripts/diagnose_nodeport.sh
```

诊断产物保存在：
`/Users/luogangyi/Code/nvshare/dashboard/artifacts/<timestamp>-nodeport-diagnose/`

重点看：

- `probe_clusterip_80.txt`
- `probe_node_<ip>_32050.txt`

## 一键修复公网 32050 映射（基于 SSH 反向隧道）

```bash
cd /Users/luogangyi/Code/nvshare
export KUBECONFIG=~/Code/configs/kubeconfig-kcs-npu
./dashboard/scripts/repair_32050_connectivity.sh
```

默认参数：

- `PUBLIC_HOST=aliyun`
- `PUBLIC_IP=139.196.28.96`
- `PUBLIC_PORT=32050`
- `LOCAL_PORT=18080`
- `NAMESPACE=xpushare-system`
- `SERVICE=xpushare-dashboard`

可覆盖示例：

```bash
PUBLIC_PORT=32060 LOCAL_PORT=18081 ./dashboard/scripts/repair_32050_connectivity.sh
```

## 根因特征（本次）

本次现场定位结果是：`139.196.28.96:32050` 被 `sshd` 会话监听占用（端口转发残留），导致 TCP 建连但 HTTP 空响应。  
修复脚本会先清理该端口旧监听，再重建隧道。
