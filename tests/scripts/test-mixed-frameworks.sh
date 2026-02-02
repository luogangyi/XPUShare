#!/bin/bash
# 场景 5：混合框架测试
# 验证 PyTorch 和 TensorFlow 任务混合共享

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

MANIFESTS_DIR="$SCRIPT_DIR/../workloads/manifests"

print_header "测试场景 5：混合框架测试"
echo "同时运行 PyTorch 和 TensorFlow 任务"
echo ""

# 清理之前的测试 Pod
kubectl delete pod -l app=nvshare-mixed --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

# 获取镜像 URL
PYTORCH_IMAGE=$(get_image_url "$MANIFESTS_DIR/nvshare-pytorch-small-pod-1.yaml")
TF_IMAGE=$(get_image_url "$MANIFESTS_DIR/nvshare-tf-small-pod-1.yaml")
echo "PyTorch 镜像: $PYTORCH_IMAGE"
echo "TensorFlow 镜像: $TF_IMAGE"
echo ""

# 默认为 2 对 (即 4 个 Pod)
PAIR_COUNT=${1:-2}

# 创建 Pod
echo "启动 $PAIR_COUNT 对 (共 $((PAIR_COUNT * 2)) 个) PyTorch + TensorFlow 测试 Pod..."
PODS=()
for i in $(seq 1 $PAIR_COUNT); do
    PT_POD="nvshare-mixed-pytorch-$i"
    TF_POD="nvshare-mixed-tf-$i"
    PODS+=("$PT_POD" "$TF_POD")
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $PT_POD
  labels:
    app: nvshare-mixed
    framework: pytorch
spec:
  restartPolicy: OnFailure
  containers:
  - name: pytorch-ctr
    image: $PYTORCH_IMAGE
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    - name: NVSHARE_ENABLE_SINGLE_OVERSUB
      value: "1"
    resources:
      limits:
        nvshare.com/gpu: 1
---
apiVersion: v1
kind: Pod
metadata:
  name: $TF_POD
  labels:
    app: nvshare-mixed
    framework: tensorflow
spec:
  restartPolicy: OnFailure
  containers:
  - name: tf-ctr
    image: $TF_IMAGE
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
    print_header "✅ 测试通过：混合框架共享成功"
else
    print_header "⚠️ 测试失败或部分未完成"
fi

exit $exit_code
