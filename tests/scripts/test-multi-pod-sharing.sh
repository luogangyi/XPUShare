#!/bin/bash
# 场景 2：多 Pod GPU 共享测试
# 验证 4 个 Pod 在单 GPU 上的时分复用

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

MANIFESTS_DIR="$SCRIPT_DIR/../workloads/manifests"

print_header "测试场景 2：多 Pod GPU 共享"

# 清理之前的测试 Pod
kubectl delete pod -l app=nvshare-multi-pod --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

# 获取镜像 URL
IMAGE=$(get_image_url "$MANIFESTS_DIR/nvshare-tf-small-pod-1.yaml")
echo "镜像: $IMAGE"
echo ""

# 默认为 4 个 Pod
POD_COUNT=${1:-4}

# 创建 Pod
echo "启动 $POD_COUNT 个 TensorFlow 测试 Pod..."
PODS=()
for i in $(seq 1 $POD_COUNT); do
    POD_NAME="nvshare-multi-pod-$i"
    PODS+=("$POD_NAME")
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  labels:
    app: nvshare-multi-pod
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

# 并行等待所有 Pod 完成
wait_all_pods_complete 600 "${PODS[@]}"

# 检查结果
check_results "${PODS[@]}"
exit_code=$?

if [ $exit_code -eq 0 ]; then
    print_header "✅ 测试通过：多 Pod GPU 共享成功"
else
    print_header "❌ 测试失败或部分未完成"
fi

exit $exit_code
