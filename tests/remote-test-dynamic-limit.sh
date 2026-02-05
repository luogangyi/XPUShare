#!/bin/bash
set -e

# Test script for Dynamic GPU Memory Limit via Annotations
# Tests dynamic memory limit adjustment without pod restart

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
    kubectl delete pod -l app=nvshare-manual-test --ignore-not-found=true --wait=true 2>/dev/null || true
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
        
        if [ "$status" == "Running" ]; then
            return 0
        elif [ "$status" == "Failed" ] || [ "$status" == "Succeeded" ]; then
            return 2
        fi
        
        sleep 2
    done
}

# Setup phase
if [ "$SKIP_SETUP" != "true" ]; then
    log_info "===== 0. Local Auto-Commit ====="
    cd "$PROJECT_ROOT"
    if [ -n "$(git status --porcelain)" ]; then
        log_info "Changes detected. Committing locally..."
        git add .
        git commit -m "wip: auto-commit by remote-test-dynamic-limit.sh [$(date +%H:%M:%S)]"
    fi

    log_info "===== 1. Syncing Code to $REMOTE_HOST ====="
    rsync -avz --exclude '.idea' "$PROJECT_ROOT/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"

    log_info "===== 2. Remote Build (with libcurl) ====="
    # Must build and push ALL components because comm.h (protocol) changed
    ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "cd $REMOTE_DIR && make build-base && make all"

    log_info "===== 3. Updating Local Manifests ====="
    "$SCRIPT_DIR/update-manifests.sh"

    log_info "===== 4. Deploying RBAC for Pod annotation access ====="
    kubectl apply -f "$K8S_MANIFESTS_DIR/scheduler-rbac.yaml"

    log_info "===== 5. Redeploying Components ====="
    # Redeploy both because of protocol change and library update
    kubectl -n nvshare-system delete ds nvshare-scheduler nvshare-device-plugin --ignore-not-found=true --wait=true
    
    kubectl apply -f "$MANIFESTS_DIR/scheduler.yaml"
    kubectl apply -f "$MANIFESTS_DIR/device-plugin.yaml"
    
    log_info "Waiting for DaemonSets..."
    kubectl -n nvshare-system rollout status ds/nvshare-scheduler --timeout=120s
    kubectl -n nvshare-system rollout status ds/nvshare-device-plugin --timeout=120s
fi

# Use a long-running test image (same as other tests)
IMAGE="registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b"

echo ""
echo "==========================================="
echo "  Dynamic Memory Limit Test (Annotations)"
echo "==========================================="
echo ""

cleanup_pods

#######################################
# Test: Dynamic Memory Limit Adjustment
#######################################
log_step "Creating test pod with initial NO memory limit..."

kubectl apply -f "$SCRIPT_DIR/kubernetes/manifests/manual-test-pod.yaml"

if ! wait_for_pod_running "manual-dynamic-test" 60; then
    log_error "Pod failed to start"
    kubectl describe pod manual-dynamic-test || true
    exit 1
fi

log_info "Pod is running. Checking scheduler logs for initial state..."

echo ""
echo "Scheduler logs (last 10 lines):"
kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=10 || true
echo ""

#######################################
# Step 1: Add memory limit annotation
#######################################
log_step "Step 1: Adding memory limit annotation (2Gi)..."

kubectl annotate pod manual-dynamic-test nvshare.com/gpu-memory-limit=2Gi --overwrite

log_info "Waiting for scheduler to detect annotation change (5-10 seconds)..."
sleep 10

echo ""
echo "Scheduler logs after annotation (last 15 lines):"
kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=15 || true
echo ""

#######################################
# Step 2: Update memory limit annotation
#######################################
log_step "Step 2: Updating memory limit annotation (4Gi)..."

kubectl annotate pod manual-dynamic-test nvshare.com/gpu-memory-limit=4Gi --overwrite

log_info "Waiting for scheduler to detect annotation change (5-10 seconds)..."
sleep 10

echo ""
echo "Scheduler logs after update (last 15 lines):"
kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=15 || true
echo ""

#######################################
# Step 3: Remove memory limit annotation
#######################################
log_step "Step 3: Removing memory limit annotation..."

kubectl annotate pod manual-dynamic-test nvshare.com/gpu-memory-limit-

log_info "Waiting for scheduler to detect annotation removal (5-10 seconds)..."
sleep 10

echo ""
echo "Scheduler logs after removal (last 15 lines):"
kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=15 || true
echo ""

#######################################
# Step 4: Verify OOM enforcement
#######################################
log_step "Step 4: Verifying OOM enforcement (Limit 1Gi)..."

# 1. Set strict limit (1Gi) - too small for pytorch init + context
kubectl annotate pod manual-dynamic-test nvshare.com/gpu-memory-limit=1Gi --overwrite
log_info "Waiting for 1Gi limit to be applied..."
sleep 10

# 2. Exec into pod and try to run a workload
log_info "Executing /pytorch-add-small.py inside pod (Expect Failure)..."
set +e # Disable exit-on-error temporarily
kubectl exec manual-dynamic-test -- python3 /pytorch-add-small.py
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
    echo -e "${GREEN}[PASS] Workload failed as expected (Potential OOM).${NC}"
else
    echo -e "${RED}[FAIL] Workload succeeded but should have OOM'd with 1Gi limit!${NC}"
    # cleanup_pods # Don't cleanup yet so we can inspect
    exit 1
fi

# Reset limit
kubectl annotate pod manual-dynamic-test nvshare.com/gpu-memory-limit-

#######################################
# Cleanup
#######################################
cleanup_pods

echo ""
#######################################
# Verification Logic
#######################################
log_step "Verifying logs..."

SCHEDULER_POD=$(kubectl -n nvshare-system get pod -l name=nvshare-scheduler -o jsonpath="{.items[0].metadata.name}")
log_info "Checking logs from Scheduler Pod: $SCHEDULER_POD"

SCHEDULER_LOGS=$(kubectl -n nvshare-system logs "$SCHEDULER_POD" --tail=100)

if echo "$SCHEDULER_LOGS" | grep -q "Registered client"; then
    echo "[PASS] Client registered successfully."
else
    log_error "Verification FAILED: Client did not register with scheduler."
    echo ""
    log_error "Device Plugin Logs (tail 50):"
    kubectl -n nvshare-system logs -l name=nvshare-device-plugin --tail=50
    echo ""
    cleanup_pods
    exit 1
fi

if echo "$SCHEDULER_LOGS" | grep -q "Running 1 update_limit tests"; then
    # Optional logic if we had specific test markers, but here we look for UPDATE_LIMIT
    :
fi

# We expect at least one UPDATE_LIMIT message (for 2Gi or 4Gi)
if echo "$SCHEDULER_LOGS" | grep -q "Sending UPDATE_LIMIT"; then
    log_info "Verified: UPDATE_LIMIT message sent to client."
else
    log_error "Verification FAILED: No UPDATE_LIMIT message found in scheduler logs."
    echo "$SCHEDULER_LOGS"
    cleanup_pods
    exit 1
fi

if echo "$SCHEDULER_LOGS" | grep -E -q "Memory limit changed|Applying initial memory limit"; then
    log_info "Verified: Annotation change detected."
else
    log_error "Verification FAILED: Annotation change not detected."
    cleanup_pods
    exit 1
fi

#######################################
# Cleanup
#######################################
cleanup_pods

echo ""
echo "==========================================="
echo "  Test PASSED"
echo "==========================================="
echo ""
