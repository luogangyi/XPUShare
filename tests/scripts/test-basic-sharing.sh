#!/bin/bash
# 场景 1：基础 GPU 共享验证
# 验证 2 个 Pod 能否共享同一 GPU

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

MANIFESTS_DIR="$SCRIPT_DIR/../workloads/manifests"

print_header "测试场景 1：基础 GPU 共享验证"

# 从 YAML 提取 Pod 名称
POD1=$(get_pod_name "$MANIFESTS_DIR/nvshare-pytorch-small-pod-1.yaml")
POD2=$(get_pod_name "$MANIFESTS_DIR/nvshare-pytorch-small-pod-2.yaml")

echo "Pod 1: $POD1"
echo "Pod 2: $POD2"
echo ""

# 清理之前的测试 Pod
kubectl delete pod $POD1 $POD2 --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

# 启动测试 Pod
echo "启动 2 个 PyTorch 测试 Pod..."
kubectl apply -f "$MANIFESTS_DIR/nvshare-pytorch-small-pod-1.yaml"
kubectl apply -f "$MANIFESTS_DIR/nvshare-pytorch-small-pod-2.yaml"

# 定义 Pod 列表
PODS=("$POD1" "$POD2")

# 并行等待所有 Pod 完成
wait_all_pods_complete 600 "${PODS[@]}"

# 检查结果
check_results "${PODS[@]}"
exit_code=$?

if [ $exit_code -eq 0 ]; then
    print_header "✅ 测试通过：基础 GPU 共享验证成功"
else
    print_header "❌ 测试失败或部分未完成"
fi

exit $exit_code
