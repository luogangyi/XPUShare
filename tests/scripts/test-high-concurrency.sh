#!/bin/bash
# 场景 6：高并发压力测试
# 验证大量 Pod 同时请求 vGPU 的调度稳定性

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

MANIFESTS_DIR="$SCRIPT_DIR/../workloads/manifests"

POD_COUNT=${1:-15}

print_header "测试场景 6：高并发压力测试"
echo "Pod 数量: $POD_COUNT"
echo "配置: 2 GPU × 10 vGPU = 20 vGPU 总量"
echo ""

# 清理之前的测试 Pod
kubectl delete pod -l app=nvshare-stress --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

# 获取镜像 URL
IMAGE=$(get_image_url "$MANIFESTS_DIR/nvshare-tf-small-pod-1.yaml")
echo "镜像: $IMAGE"
echo ""

# 创建多个 Pod
echo "启动 $POD_COUNT 个 TensorFlow 测试 Pod..."
PODS=()
for i in $(seq 1 $POD_COUNT); do
    POD_NAME="nvshare-stress-$i"
    PODS+=("$POD_NAME")
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  labels:
    app: nvshare-stress
spec:
  restartPolicy: OnFailure
  containers:
  - name: tf-ctr
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

# 等待一会让 Pod 创建
sleep 15

# 显示 Pod 状态
kubectl get pods -l app=nvshare-stress

# 并行等待所有 Pod 完成
wait_all_pods_complete 900 "${PODS[@]}"

# 检查结果
check_results "${PODS[@]}"
exit_code=$?

if [ $exit_code -eq 0 ]; then
    print_header "✅ 测试通过：高并发压力测试成功"
else
    print_header "⚠️ 测试失败或部分未完成"
fi

exit $exit_code
