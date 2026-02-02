#!/bin/bash
# 场景：Idle Small Workload 测试
# 验证低算力（Idle）下的并行执行情况
# 默认启动 10 个 Pod 测试并发

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

MANIFESTS_DIR="$SCRIPT_DIR/../kubernetes/manifests"

# 默认 10 个 Pod
POD_COUNT=${1:-10}

print_header "测试场景：Idle Small Workload ($POD_COUNT Pods)"
echo "Pod 数量: $POD_COUNT"

# Clean up
kubectl delete pod -l app=nvshare-idle-small-workload --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

# Get Image
# Note: Since we are building remotely and pushing, we need to know the correct image tag.
# The remote build uses $(git rev-parse HEAD | cut -c 1-8).
# Locally we might not know it easily if HEAD differs. 
# However, the remote-test-idle-small.sh syncs first, so HEAD should match.
# But `get_image_url` might try to parse `nvshare-pytorch-idle-small-pod-1.yaml`.
# I'll update that manifest to have a placeholder or just use what I wrote.
IMAGE_TAG=$(git rev-parse HEAD | cut -c 1-8)
IMAGE="registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-idle-small-5fed3e5b"
echo "使用镜像 (Calculated): $IMAGE"

# 获取测试开始时间 (UTC RFC3339 format for kubectl logs --since-time)
TEST_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Test Start Time: $TEST_START_TIME"

echo "启动 $POD_COUNT 个 Idle Small Workload Pod..."
PODS=()
for i in $(seq 1 $POD_COUNT); do
    POD_NAME="nvshare-idle-small-$i"
    PODS+=("$POD_NAME")
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  labels:
    app: nvshare-idle-small-workload
spec:
  restartPolicy: OnFailure
  containers:
  - name: ctr
    image: $IMAGE
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF
done

sleep 5

echo ""
echo "Pod 分布情况："
kubectl get pods -l app=nvshare-idle-small-workload -o wide

# Progress monitoring function (reused from test-small.sh)
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
            local status=$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [ "$status" == "Succeeded" ] || [ "$status" == "Failed" ]; then
                echo -n "$pod: $status | "
                ((completed_count++))
            elif [ "$status" == "Running" ]; then
                local progress=$(kubectl logs "$pod" --tail=20 2>/dev/null | grep -o "[0-9]\+%" | tail -n 1)
                 if [ -z "$progress" ]; then
                    progress=$(kubectl logs "$pod" --tail=20 2>/dev/null | grep -o "[0-9]\+/[0-9]\+" | tail -n 1)
                fi
                
                if [ -z "$progress" ]; then
                     echo -n "$pod: R | "
                else
                     echo -n "$pod: $progress | "
                fi
            else
                echo -n "$pod: $status | "
            fi
        done
        echo "" 
        
        sleep 5
    done
    echo "All pods finished."
}

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

check_results "${PODS[@]}"
exit_code=$?

if [ $exit_code -eq 0 ]; then
    print_header "✅ 测试通过：Idle Small Workload"
else
    print_header "⚠️ 测试部分完成"
fi

exit $exit_code
