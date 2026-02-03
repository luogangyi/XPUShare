#!/bin/bash
set -e

# Test script for GPU Memory Limit feature
# Tests three scenarios:
#   1. Limit too small (1Gi) - should fail with OOM
#   2. Limit sufficient (4Gi) - should pass
#   3. No limit - should pass

# Configuration
REMOTE_HOST="139.196.28.96"
REMOTE_USER="root"
REMOTE_DIR="/root/code/nvshare"
SSH_OPTS="-o StrictHostKeyChecking=no"

export KUBECONFIG=~/Code/configs/kubeconfig-fuyao-gpu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."

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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup_pods() {
    log_info "Cleaning up test pods..."
    kubectl delete pod -l app=nvshare-memlimit-test --ignore-not-found=true --wait=false 2>/dev/null || true
    sleep 2
}

wait_for_pod() {
    local pod_name=$1
    local timeout=${2:-120}
    local expected_status=${3:-"Completed"}
    
    log_info "Waiting for pod $pod_name (timeout: ${timeout}s)..."
    
    local start_time=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_warn "Timeout waiting for pod $pod_name"
            return 1
        fi
        
        local status=$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        local container_status=$(kubectl get pod "$pod_name" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || echo "")
        
        if [ "$status" == "Succeeded" ]; then
            return 0
        elif [ "$status" == "Failed" ] || [ "$container_status" == "Error" ] || [ "$container_status" == "OOMKilled" ]; then
            return 2
        fi
        
        sleep 3
    done
}

get_pod_logs() {
    local pod_name=$1
    kubectl logs "$pod_name" 2>/dev/null || echo "(no logs available)"
}

# Setup phase
if [ "$SKIP_SETUP" != "true" ]; then
    log_info "===== 0. Local Auto-Commit ====="
    cd "$PROJECT_ROOT"
    if [ -n "$(git status --porcelain)" ]; then
        log_info "Changes detected. Committing locally..."
        git add .
        git commit -m "wip: auto-commit by remote-test-memlimit.sh [$(date +%H:%M:%S)]"
    fi

    log_info "===== 1. Syncing Code to $REMOTE_HOST ====="
    rsync -avz --exclude '.idea' "$PROJECT_ROOT/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"

    log_info "===== 2. Remote Build ====="
    ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "cd $REMOTE_DIR && make all"

    log_info "===== 3. Updating Local Manifests ====="
    "$SCRIPT_DIR/update-manifests.sh"

    log_info "===== 4. Redeploying System Components ====="
    kubectl -n nvshare-system delete ds nvshare-device-plugin nvshare-scheduler --ignore-not-found=true --wait=true
    kubectl apply -f "$SCRIPT_DIR/manifests/scheduler.yaml"
    kubectl apply -f "$SCRIPT_DIR/manifests/device-plugin.yaml"
    
    log_info "Waiting for DaemonSets..."
    kubectl -n nvshare-system rollout status ds/nvshare-scheduler --timeout=60s
    kubectl -n nvshare-system rollout status ds/nvshare-device-plugin --timeout=60s
fi

# Get the image from existing manifest
IMAGE=$(grep "image:" "$SCRIPT_DIR/manifests/nvshare-pytorch-small-pod-1.yaml" | head -1 | awk '{print $2}')
if [ -z "$IMAGE" ]; then
    IMAGE="registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b"
fi

log_info "Using image: $IMAGE"

# Clean up any existing test pods
cleanup_pods

echo ""
echo "=========================================="
echo "  GPU Memory Limit Feature Test Suite"
echo "=========================================="
echo ""

# Test results
declare -A TEST_RESULTS

#######################################
# Test 1: Memory limit too small (should FAIL)
#######################################
log_info "===== Test 1: Memory Limit 1Gi (Expect FAIL) ====="
log_info "pytorch-add-small allocates ~1.5GB, so 1Gi limit should cause OOM"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: memlimit-test-1gi
  labels:
    app: nvshare-memlimit-test
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: $IMAGE
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    - name: NVSHARE_GPU_MEMORY_LIMIT
      value: "1Gi"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF

wait_for_pod "memlimit-test-1gi" 60
result=$?

logs=$(get_pod_logs "memlimit-test-1gi")
if echo "$logs" | grep -q "Memory allocation rejected\|CUDA_ERROR_OUT_OF_MEMORY\|OutOfMemory\|memory limit"; then
    log_info "✅ Test 1 PASSED: Memory limit correctly enforced (allocation rejected)"
    TEST_RESULTS["test1"]="PASS"
else
    if [ $result -eq 0 ]; then
        log_error "❌ Test 1 FAILED: Pod succeeded but should have been rejected by memory limit"
        TEST_RESULTS["test1"]="FAIL"
    else
        log_info "✅ Test 1 PASSED: Pod failed as expected"
        TEST_RESULTS["test1"]="PASS"
    fi
fi

echo ""
echo "Test 1 Logs (last 20 lines):"
echo "$logs" | tail -20
echo ""

# Clean up
kubectl delete pod memlimit-test-1gi --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

#######################################
# Test 2: Memory limit sufficient (should PASS)
#######################################
log_info "===== Test 2: Memory Limit 4Gi (Expect PASS) ====="
log_info "4Gi should be enough for ~1.5GB allocation"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: memlimit-test-4gi
  labels:
    app: nvshare-memlimit-test
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: $IMAGE
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    - name: NVSHARE_GPU_MEMORY_LIMIT
      value: "4Gi"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF

wait_for_pod "memlimit-test-4gi" 600
result=$?

logs=$(get_pod_logs "memlimit-test-4gi")
if [ $result -eq 0 ] && echo "$logs" | grep -q "PASS"; then
    log_info "✅ Test 2 PASSED: Task completed with 4Gi limit"
    TEST_RESULTS["test2"]="PASS"
else
    log_error "❌ Test 2 FAILED: Task should succeed with 4Gi limit"
    TEST_RESULTS["test2"]="FAIL"
fi

echo ""
echo "Test 2 Logs (last 10 lines):"
echo "$logs" | tail -10
echo ""

# Clean up
kubectl delete pod memlimit-test-4gi --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3

#######################################
# Test 3: No memory limit (should PASS)
#######################################
log_info "===== Test 3: No Memory Limit (Expect PASS) ====="
log_info "Default behavior without limit"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: memlimit-test-nolimit
  labels:
    app: nvshare-memlimit-test
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: $IMAGE
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF

wait_for_pod "memlimit-test-nolimit" 600
result=$?

logs=$(get_pod_logs "memlimit-test-nolimit")
if [ $result -eq 0 ] && echo "$logs" | grep -q "PASS"; then
    log_info "✅ Test 3 PASSED: Task completed without memory limit"
    TEST_RESULTS["test3"]="PASS"
else
    log_error "❌ Test 3 FAILED: Task should succeed without limit"
    TEST_RESULTS["test3"]="FAIL"
fi

echo ""
echo "Test 3 Logs (last 10 lines):"
echo "$logs" | tail -10
echo ""

# Clean up
cleanup_pods

#######################################
# Summary
#######################################
echo ""
echo "=========================================="
echo "           Test Summary"
echo "=========================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

for test in "test1" "test2" "test3"; do
    result=${TEST_RESULTS[$test]:-"UNKNOWN"}
    if [ "$result" == "PASS" ]; then
        ((PASS_COUNT++))
        echo -e "  $test: ${GREEN}PASS${NC}"
    else
        ((FAIL_COUNT++))
        echo -e "  $test: ${RED}FAIL${NC}"
    fi
done

echo ""
echo "Total: $PASS_COUNT passed, $FAIL_COUNT failed"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}=========================================="
    echo "  ✅ All tests passed!"
    echo -e "==========================================${NC}"
    exit 0
else
    echo -e "${RED}=========================================="
    echo "  ❌ Some tests failed!"
    echo -e "==========================================${NC}"
    exit 1
fi
