#!/bin/bash
# 清理所有测试 Pod

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

echo "清理所有测试 Pod..."

# 清理各种测试 Pod
kubectl delete pod -l app=xpushare-multi-pod --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=xpushare-mixed --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=xpushare-cross-gpu --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=xpushare-stress --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=xpushare-memory-test --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=xpushare-test --ignore-not-found=true --wait=false 2>/dev/null

# 清理直接创建的 Pod
kubectl delete pod xpushare-pytorch-add-1 xpushare-pytorch-add-2 --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod xpushare-tf-matmul-1 xpushare-tf-matmul-2 --ignore-not-found=true --wait=false 2>/dev/null

echo -e "${GREEN}✓${NC} 清理命令已发送"
echo ""
echo "当前测试 Pod："
kubectl get pods 2>/dev/null | grep xpushare || echo "无测试 Pod 运行"
