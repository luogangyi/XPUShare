#!/bin/bash
# 清理所有测试 Pod

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

echo "清理所有测试 Pod..."

# 清理各种测试 Pod
kubectl delete pod -l app=nvshare-multi-pod --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=nvshare-mixed --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=nvshare-cross-gpu --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=nvshare-stress --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=nvshare-memory-test --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod -l app=nvshare-test --ignore-not-found=true --wait=false 2>/dev/null

# 清理直接创建的 Pod
kubectl delete pod nvshare-pytorch-add-1 nvshare-pytorch-add-2 --ignore-not-found=true --wait=false 2>/dev/null
kubectl delete pod nvshare-tf-matmul-1 nvshare-tf-matmul-2 --ignore-not-found=true --wait=false 2>/dev/null

echo -e "${GREEN}✓${NC} 清理命令已发送"
echo ""
echo "当前测试 Pod："
kubectl get pods 2>/dev/null | grep nvshare || echo "无测试 Pod 运行"
