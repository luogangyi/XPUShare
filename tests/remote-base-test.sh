#!/bin/bash
set -e

# Configuration
REMOTE_HOST="139.196.28.96"
REMOTE_USER="root"
REMOTE_DIR="/root/code/nvshare"
SSH_OPTS="-o StrictHostKeyChecking=no" 
export KUBECONFIG=~/Code/configs/kubeconfig-fuyao-gpu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

echo "===== 0. Cleaning up NVShare Components ====="
echo "Deleting workloads..."
kubectl delete pod -l app=nvshare-cross-gpu --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl delete pod -l app=nvshare-small-workload --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl delete pod -l app=nvshare-idle-small-workload --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3
echo "Deleting system components..."
kubectl -n nvshare-system delete ds nvshare-device-plugin nvshare-scheduler --ignore-not-found=true --wait=true
echo "Waiting for pods to terminate..."
kubectl wait --for=delete pod -l app=nvshare-cross-gpu --timeout=60s 2>/dev/null || true
kubectl wait --for=delete pod -l app=nvshare-small-workload --timeout=60s 2>/dev/null || true
kubectl wait --for=delete pod -l app=nvshare-idle-small-workload --timeout=60s 2>/dev/null || true

# Helper function to run a single test case
run_baseline_test() {
    local test_name=$1
    local src_yaml=$2
    local label=$3
    local pod_base_name=$4

    echo "===== Running Baseline Test: $test_name ====="
    
    # Generate baseline yaml on the fly
    local base_yaml="/tmp/${pod_base_name}-base.yaml"
    sed 's/nvshare\.com\/gpu/nvidia\.com\/gpu/g' "$src_yaml" > "$base_yaml"
    # Also remove NVShare env vars to be clean, though they shouldn't hurt? 
    # User said "modify limit is native nvidia.com/gpu". keeping envs is fine as they are ignored without the library hooked.
    # But wait, the library MIGHT be inside the image. If LD_PRELOAD is set in image, it might try to contact scheduler.
    # The image `registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-5fed3e5b` likely has libnvshare installed.
    # But without `nvshare.com/gpu` resource, the device plugin won't inject the socket path or LD_PRELOAD if it was doing that?
    # Actually, the user's Dockerfile adds correct entrypoints or env vars?
    # If the image has LD_PRELOAD set globally, we might issue.
    # Assuming standard behavior where we just want to measure raw execution on Nvidia GPU.
    
    echo "Deploying 1 pod from $base_yaml (Serial execution)..."
    
    # We use a unique name to avoid conflicts if cleanup failed slightly
    local pod_name="${pod_base_name}-baseline"
    
    # Extract image to verify
    local image=$(grep "image:" "$base_yaml" | head -1 | sed 's/.*image: //' | tr -d ' ')
    echo "Image: $image"
    
    # We need to modify the name in the yaml, or simply use kubectl run logic?
    # Better to use the yaml but override metadata.name
    # Using sed to replace the name line is risky if multiple 'name:' exist.
    # Let's write a clean minimal pod yaml here using cat
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  labels:
    app: baseline-test
    test-case: $test_name
spec:
  restartPolicy: OnFailure
  containers:
  - name: ctr
    image: $image
    # Clear NVShare specific envs if possible or just let them be.
    # We want base performance.
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

    # Monitor
    echo "Waiting for pod $pod_name..."
    sleep 5
    
    # Simple wait loop
    local start_time=$(date +%s)
    local end_time=0
    local status="Unknown"
    
    while true; do
        status=$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$status" == "Succeeded" ]; then
            end_time=$(date +%s)
            break
        elif [ "$status" == "Failed" ]; then
            end_time=$(date +%s)
            break
        fi
        
        # Check logs for progress or PASS
        if kubectl logs "$pod_name" 2>/dev/null | grep -q "PASS"; then
             status="Succeeded"
             end_time=$(date +%s)
             break
        fi
        
        echo -n "."
        sleep 5
    done
    echo ""
    
    local duration=$((end_time - start_time))
    echo "Test $test_name Finished. Status: $status. Duration ~${duration}s (Includes startup)"
    
    # Use common.sh check_results logic for accurate timing from k8s status
    # We need to source common.sh. It's in tests/scripts/common.sh
    # But this script is in tests/.
    source "$SCRIPT_DIR/scripts/common.sh"
    
    check_results "$pod_name"
    
    # Cleanup
    kubectl delete pod "$pod_name" --wait=true
    echo "---------------------------------------------------"
    echo ""
}

# 1. Standard Workload
run_baseline_test "Standard" "$SCRIPT_DIR/kubernetes/manifests/nvshare-pytorch-pod-1.yaml" "app=nvshare-cross-gpu" "pytorch-add"

# 2. Small Workload
run_baseline_test "Small" "$SCRIPT_DIR/kubernetes/manifests/nvshare-pytorch-small-pod-1.yaml" "app=nvshare-small-workload" "pytorch-small"

# 3. Idle Small Workload
run_baseline_test "Idle-Small" "$SCRIPT_DIR/kubernetes/manifests/nvshare-pytorch-idle-small-pod-1.yaml" "app=nvshare-idle-small-workload" "pytorch-idle-small"

echo "===== All Baseline Tests Completed ====="
