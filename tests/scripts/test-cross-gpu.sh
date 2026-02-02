#!/bin/bash
# 场景 3：跨 GPU 负载分布测试
# 验证多 Pod 是否能分布到不同 GPU
# 配置：1:10 虚拟化比，2 GPU = 20 vGPU
# 配置：1:10 虚拟化比，2 GPU = 20 vGPU
# 默认启动 4 个 Pod 测试并发，可通过参数指定更多

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

MANIFESTS_DIR="$SCRIPT_DIR/../kubernetes/manifests"

# 默认 4 个 Pod (可通过命令行参数覆盖)
POD_COUNT=${1:-3}

print_header "测试场景 3：跨 GPU 负载分布"
echo "Pod 数量: $POD_COUNT"
echo "启动 $POD_COUNT 个 Pod 进行测试"
echo ""

# 清理之前的测试 Pod
kubectl delete pod -l app=nvshare-cross-gpu --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

# 获取镜像 URL（使用 pytorch-add 标准版，约 12GB 显存，测试超分）
IMAGE=$(get_image_url "$MANIFESTS_DIR/nvshare-pytorch-pod-1.yaml")
echo "镜像: $IMAGE"
echo ""

# 获取测试开始时间 (UTC RFC3339 format for kubectl logs --since-time)
TEST_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Test Start Time: $TEST_START_TIME"

# 创建多个 Pod（启用超分）
echo "启动 $POD_COUNT 个 PyTorch 测试 Pod (每 Pod ~6GB 显存)..."
PODS=()
for i in $(seq 1 $POD_COUNT); do
    POD_NAME="nvshare-cross-gpu-$i"
    PODS+=("$POD_NAME")
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  labels:
    app: nvshare-cross-gpu
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
sleep 10

# 检查 Pod 分布
echo ""
echo "Pod 分布情况："
kubectl get pods -l app=nvshare-cross-gpu -o wide

# Progress monitoring function
monitor_progress() {
    local pods=("$@")
    local start_time=$(date +%s)
    local timeout=6000
    local completed_count=0
    local total_count=${#pods[@]}

    echo "Monitoring progress for $total_count pods..."

    while [ $completed_count -lt $total_count ]; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            echo "Timeout waiting for pods to complete."
            return 1
        fi

        echo -n "$(date '+%H:%M:%S') [Elapsed: ${elapsed}s] "
        completed_count=0
        
        for pod in "${pods[@]}"; do
            # Get Pod Status
            local status=$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [ "$status" == "Succeeded" ] || [ "$status" == "Failed" ]; then
                echo -n "$pod: $status | "
                ((completed_count++))
            elif [ "$status" == "Running" ]; then
                # Attempt to extract progress from logs (tqdm format like ' 32%|... | 1280/4000')
                # We grep for '%' and take the last match to show current progress
                local progress=$(kubectl logs "$pod" --tail=20 2>/dev/null | grep -o "[0-9]\+%" | tail -n 1)
                if [ -z "$progress" ]; then
                    # Fallback: look for iteration count like ' 120/4000'
                    progress=$(kubectl logs "$pod" --tail=20 2>/dev/null | grep -o "[0-9]\+/[0-9]\+" | tail -n 1)
                fi
                
                if [ -z "$progress" ]; then
                     echo -n "$pod: Running (Wait...) | "
                else
                     echo -n "$pod: Running ($progress) | "
                fi
            else
                echo -n "$pod: $status | "
            fi
        done
        echo "" # Newline
        
        sleep 5
    done
    echo "All pods finished."
}

# 并行等待所有 Pod 完成并显示进度
monitor_progress "${PODS[@]}"

# 检查 scheduler 日志查看 GPU 分配
echo ""
echo "Scheduler Log Analysis (GPU Distribution):"

# Fetch logs from all scheduler pods
for pod in $(kubectl -n nvshare-system get pods -l name=nvshare-scheduler -o jsonpath='{.items[*].metadata.name}'); do
    echo "Analyzing scheduler pod: $pod"
    kubectl -n nvshare-system logs $pod --since-time="$TEST_START_TIME" 2>/dev/null > /tmp/scheduler_$pod.log
done

# Python script to parse and print table
python3 -c "
import re
import glob

print(f'{'Pod Name':<30} | {'Client ID':<18} | {'GPU UUID':<40}')
print('-' * 92)

log_files = glob.glob('/tmp/scheduler_*.log')
seen_clients = set()

# Regex to match the NEW log format
# \"Registered client <id> on GPU <uuid> with Pod name = <name>, ...\"
# Also support possible variations or partial matches
regex = re.compile(r'Registered client ([0-9a-f]+) on GPU ([a-zA-Z0-9-]+) with Pod name = ([^,]+)')

for log_file in log_files:
    try:
        with open(log_file, 'r', errors='ignore') as f:
            for line in f:
                if 'Registered client' in line and 'on GPU' in line:
                    match = regex.search(line)
                    if match:
                        client_id, gpu_uuid, pod_name = match.groups()
                        # Clean up pod name (trim whitespace)
                        pod_name = pod_name.strip()
                        if client_id not in seen_clients:
                             # Try to clean UUID if it has prefix 'GPU-'
                            if gpu_uuid.startswith('GPU-'):
                                short_uuid = gpu_uuid[4:12] + '...'
                            else:
                                short_uuid = gpu_uuid[:8] + '...'
                                
                            print(f'{pod_name:<30} | {client_id:<18} | {gpu_uuid:<40}')
                            seen_clients.add(client_id)
    except Exception as e:
        print(f'Error reading {log_file}: {e}')
"
rm /tmp/scheduler_*.log 2>/dev/null

# 检查结果
check_results "${PODS[@]}"
exit_code=$?

if [ $exit_code -eq 0 ]; then
    print_header "✅ 测试通过：跨 GPU 负载分布成功"
else
    print_header "⚠️ 测试部分完成，请检查日志"
fi

exit $exit_code
