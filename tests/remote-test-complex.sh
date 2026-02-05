#!/bin/bash
set -e

# Complex Test Script for Dynamic GPU Memory Limit
# Scenarios: Multi-Pod Isolation, Dynamic Resize, Stability Loop
# Uses existing images and python code injection via kubectl exec

# Configuration
REMOTE_HOST="139.196.28.96"
REMOTE_USER="root"
REMOTE_DIR="/root/code/nvshare"
SSH_OPTS="-o StrictHostKeyChecking=no"

export KUBECONFIG=~/Code/configs/kubeconfig-fuyao-gpu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
K8S_MANIFESTS_DIR="$PROJECT_ROOT/kubernetes/manifests"

SKIP_SETUP="false"

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--skip-setup)
      SKIP_SETUP="true"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

cleanup_pods() {
    log_info "Cleaning up test pods..."
    kubectl delete pod -l app=nvshare-complex-test --ignore-not-found=true --wait=true 2>/dev/null || true
    sleep 2
}

wait_for_pod_running() {
    local pod_name=$1
    local timeout=${2:-60}
    log_info "Waiting for pod $pod_name to be Running..."
    local start_time=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ $elapsed -gt $timeout ]; then
            log_warn "Timeout waiting for pod $pod_name"
            return 1
        fi
        local status=$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [ "$status" == "Running" ]; then return 0; fi
        if [ "$status" == "Failed" ] || [ "$status" == "Succeeded" ]; then return 2; fi
        sleep 2
    done
}

run_allocation_test() {
    local pod_name=$1
    local alloc_gb=$2
    local expect_success=$3 # "true" or "false"

    log_info "Test: Allocating ${alloc_gb}Gi in $pod_name (Expect Success: $expect_success)..."
    
    # Python script to inject
    # float32 = 4 bytes. Count = (GB * 1024^3) / 4. 
    # We use a slight margin (e.g. 0.98 * GB) or exact? 
    # Let's use exact, but note that context takes memory (~300-500MB).
    # If limit is 1Gi and we request 2Gi, it should fail.
    # If limit is 3Gi and we request 2Gi, it should succeed (Context+2Gi < 3Gi).
    
    local python_cmd="
import torch
import sys
try:
    alloc_gb = $alloc_gb
    elements = int(alloc_gb * 1024**3 / 4)
    print(f'Attempting to allocate {alloc_gb} GiB ({elements} float32 elements)...')
    x = torch.empty(elements, dtype=torch.float32, device='cuda')
    print('Allocation successful')
    torch.cuda.synchronize()
except Exception as e:
    print(f'Allocation failed: {e}')
    sys.exit(1)
"
    set +e
    kubectl exec -i "$pod_name" -- python3 -c "$python_cmd"
    local exit_code=$?
    set -e

    if [ "$expect_success" == "true" ]; then
        if [ $exit_code -eq 0 ]; then
            log_info "${GREEN}[PASS] Allocation succeeded as expected.${NC}"
        else
            log_error "${RED}[FAIL] Allocation failed but was expected to succeed!${NC}"
            exit 1
        fi
    else
        if [ $exit_code -ne 0 ]; then
            log_info "${GREEN}[PASS] Allocation failed as expected (OOM).${NC}"
        else
            log_error "${RED}[FAIL] Allocation succeeded but was expected to fail!${NC}"
            exit 1
        fi
    fi
}

# Setup phase
if [ "$SKIP_SETUP" != "true" ]; then
    log_info "===== 0. Setup (Skipping build to use existing images) ====="
    
    log_info "===== 1. Deploying RBAC ====="
    kubectl apply -f "$K8S_MANIFESTS_DIR/scheduler-rbac.yaml"

    log_info "===== 2. Redeploying Components ====="
    kubectl -n nvshare-system delete ds nvshare-scheduler nvshare-device-plugin --ignore-not-found=true --wait=true
    kubectl apply -f "$MANIFESTS_DIR/scheduler.yaml"
    kubectl apply -f "$MANIFESTS_DIR/device-plugin.yaml"
    
    log_info "Waiting for DaemonSets..."
    kubectl -n nvshare-system rollout status ds/nvshare-scheduler --timeout=120s
    kubectl -n nvshare-system rollout status ds/nvshare-device-plugin --timeout=120s
fi

cleanup_pods

echo ""
echo "==========================================="
echo "  Complex Dynamic Memory Limit Test"
echo "==========================================="
echo ""

# Create two test pods
# Using pytorch-add-small image (~4GB cap, but we invoke python manually)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: complex-pod-a
  labels:
    app: nvshare-complex-test
spec:
  restartPolicy: Never
  containers:
  - name: pytorch
    image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b
    command: ["sleep", "3600"]
    resources:
      limits:
        nvshare.com/gpu: 1
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: complex-pod-b
  labels:
    app: nvshare-complex-test
spec:
  restartPolicy: Never
  containers:
  - name: pytorch
    image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b
    command: ["sleep", "3600"]
    resources:
      limits:
        nvshare.com/gpu: 1
EOF

wait_for_pod_running "complex-pod-a"
wait_for_pod_running "complex-pod-b"

################################################################
# Scenario 1: Multi-Pod Isolation
################################################################
log_step "Scenario 1: Multi-Pod Isolation Verification"

# Pod A: Strict Limit (1Gi)
log_info "Setting Pod A limit to 1Gi..."
kubectl annotate pod complex-pod-a nvshare.com/gpu-memory-limit=1Gi --overwrite
sleep 5

# Pod B: Loose Limit (3Gi)
log_info "Setting Pod B limit to 3Gi..."
kubectl annotate pod complex-pod-b nvshare.com/gpu-memory-limit=3Gi --overwrite
sleep 5

# Test A (2Gi alloc -> Fail)
run_allocation_test "complex-pod-a" 2 "false"

# Test B (2Gi alloc -> Success)
run_allocation_test "complex-pod-b" 2 "true"

################################################################
# Scenario 2: Dynamic Resize (Expansion)
################################################################
log_step "Scenario 2: Dynamic Limit Expansion (Resize)"

# Reuse Pod A (Currently 1Gi, failed 2Gi test)
log_info "Expanding Pod A limit to 4Gi..."
kubectl annotate pod complex-pod-a nvshare.com/gpu-memory-limit=4Gi --overwrite
log_info "Waiting for update..."
sleep 10

# Test A (2Gi alloc -> Success)
run_allocation_test "complex-pod-a" 2 "true"

################################################################
# Scenario 3: Stability Loop
################################################################
log_step "Scenario 3: Stability & Stress Loop (5 iterations)"

for i in {1..5}; do
    log_info "--- Iteration $i ---"
    
    # Shrink A to 1Gi
    log_info "Shrinking Pod A to 1Gi..."
    kubectl annotate pod complex-pod-a nvshare.com/gpu-memory-limit=1Gi --overwrite
    sleep 3
    run_allocation_test "complex-pod-a" 2 "false"

    # Expand A to 4Gi
    log_info "Expanding Pod A to 4Gi..."
    kubectl annotate pod complex-pod-a nvshare.com/gpu-memory-limit=4Gi --overwrite
    sleep 3
    run_allocation_test "complex-pod-a" 2 "true"
done

log_info "Stability test completed successfully."

cleanup_pods

echo ""
echo "==========================================="
echo "  Complex Test PASSED"
echo "==========================================="
echo ""
