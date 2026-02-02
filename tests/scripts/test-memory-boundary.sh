#!/bin/bash
# 场景 4：显存边界测试（启用超分）
# 验证大显存任务的 GPU 共享稳定性
# 使用 NVSHARE_ENABLE_SINGLE_OVERSUB=1 启用显存超分

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

MANIFESTS_DIR="$SCRIPT_DIR/../workloads/manifests"

print_header "测试场景 4：显存边界测试（启用超分）"
echo "环境变量: NVSHARE_ENABLE_SINGLE_OVERSUB=1"
echo "测试容器: pytorch-add (~6GB 显存 × 2 = ~12GB)"
echo "T4 显存: 16GB"
echo ""

# 清理之前的测试 Pod
kubectl delete pod -l app=nvshare-memory-test --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

# 获取镜像 URL
IMAGE=$(get_image_url "$MANIFESTS_DIR/nvshare-pytorch-pod-1.yaml")
echo "镜像: $IMAGE"
echo ""

# 创建 2 个大显存 Pod（启用超分）
echo "启动 2 个大显存 PyTorch 测试 Pod（启用显存超分）..."
PODS=()
for i in 1 2; do
    POD_NAME="nvshare-memory-test-$i"
    PODS+=("$POD_NAME")
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  labels:
    app: nvshare-memory-test
spec:
  restartPolicy: OnFailure
  containers:
  - name: pytorch-ctr
    image: $IMAGE
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    - name: NVSHARE_ENABLE_SINGLE_OVERSUB
      value: "1"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF
done

echo ""
echo "提示：可以在另一个终端运行 nvidia-smi -l 1 监控 GPU 使用"

# 并行等待所有 Pod 完成（大任务需要更长时间）
wait_all_pods_complete 900 "${PODS[@]}"

# 检查 OOM
echo ""
echo "检查 OOM 错误..."
OOM_FOUND=0
for pod in "${PODS[@]}"; do
    if kubectl logs $pod 2>/dev/null | grep -qi "out of memory\|OOM"; then
        echo -e "${RED}✗${NC} $pod: 检测到 OOM 错误"
        OOM_FOUND=1
    fi
done
if [ $OOM_FOUND -eq 0 ]; then
    echo -e "${GREEN}✓${NC} 无 OOM 错误"
fi

# 检查结果
check_results "${PODS[@]}"
exit_code=$?

if [ $exit_code -eq 0 ] && [ $OOM_FOUND -eq 0 ]; then
    print_header "✅ 测试通过：显存边界测试成功（超分启用）"
else
    print_header "⚠️ 测试失败或有 OOM 错误"
fi

exit $exit_code
