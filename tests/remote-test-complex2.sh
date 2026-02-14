#!/bin/bash
set -e

LOG_SUFFIX="$1"
if [ -z "$LOG_SUFFIX" ]; then
    echo "Usage: $0 <log_suffix>"
    echo "Example: $0 16 (will save to scheduler16.log)"
    exit 1
fi

SCHEDULER_LOG="scheduler${LOG_SUFFIX}.log"

# Configuration
REMOTE_HOST="139.196.28.96"
REMOTE_USER="root"
REMOTE_DIR="/root/code/nvshare"
COMMON_SSH_OPTS="-o StrictHostKeyChecking=no"
GPU_SSH_OPTS="$COMMON_SSH_OPTS -p 32027"

export KUBECONFIG=~/Code/configs/kubeconfig-fuyao-gpu

# Placement settle time (seconds): wait after first two 30% pods
PLACEMENT_SETTLE_SECONDS="${PLACEMENT_SETTLE_SECONDS:-8}"


# Setup Options
SKIP_SETUP="false"
while [[ $# -gt 1 ]]; do
  case $1 in
    -s|--skip-setup)
      SKIP_SETUP="true"
      shift
      ;;
    *)
      # Assume first arg is LOG_SUFFIX if set early, but we handle logic below
      # Actually, let's just parse flags and assume LOG_SUFFIX is positional at end or handled
      shift
      ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
GET_LOG_SCRIPT="$SCRIPT_DIR/scripts/get-remote-log.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $(date +%H:%M:%S)${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN] $(date +%H:%M:%S)${NC} $1"; }

# 0. Setup Phase
if [ "$SKIP_SETUP" != "true" ]; then
    log_info "===== 0. Local Auto-Commit ====="
    cd "$PROJECT_ROOT"
    if [ -n "$(git status --porcelain)" ]; then
        log_info "Changes detected. Committing locally..."
        git add .
        git commit -m "wip: auto-commit by remote-test-complex2.sh [$(date +%H:%M:%S)]"
    fi

    log_info "===== 1. Syncing Code to $REMOTE_HOST (Port 22) ====="
    rsync -avz --exclude '.idea' -e "ssh $COMMON_SSH_OPTS -p 22" "$PROJECT_ROOT/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"

    log_info "===== 2. Remote Build (Port 22) ====="
    ssh $COMMON_SSH_OPTS -p 22 "$REMOTE_USER@$REMOTE_HOST" "cd $REMOTE_DIR && make build-base && make all"

    log_info "===== 3. Updating Local Manifests ====="
    # Assuming update-manifests.sh exists there
    if [ -f "$SCRIPT_DIR/update-manifests.sh" ]; then
        "$SCRIPT_DIR/update-manifests.sh"
    fi

    log_info "===== 4. Redeploying Components ====="
    kubectl -n nvshare-system delete ds nvshare-scheduler nvshare-device-plugin --ignore-not-found=true --wait=true
    
    # We assume manifests are in $MANIFESTS_DIR or project root/deploy?
    # Reference script uses "$MANIFESTS_DIR/scheduler.yaml"
    # But MANIFESTS_DIR is defined as "$SCRIPT_DIR/manifests"
    
    # Let's try to apply from standard locations if manifests dir not perfect
    kubectl apply -f "$PROJECT_ROOT/deploy/02-scheduler.yaml" || kubectl apply -f "$MANIFESTS_DIR/scheduler.yaml"
    kubectl apply -f "$PROJECT_ROOT/deploy/01-device-plugin.yaml" || kubectl apply -f "$MANIFESTS_DIR/device-plugin.yaml"
    
    log_info "Waiting for Scheduler Rollout..."
    kubectl -n nvshare-system rollout status daemonset/nvshare-scheduler --timeout=120s
fi


# 1. Cleanup previous pods
log_info "Cleaning up previous pods..."
kubectl delete pod -l app=nvshare-complex-test --ignore-not-found=true --wait=false 2>/dev/null || true

log_info "Waiting for pods to be deleted..."
while kubectl get pod -l app=nvshare-complex-test 2>/dev/null | grep -q "complex-test"; do
    echo -ne "Waiting for pods to terminate...\r"
    sleep 2
done
echo ""
log_info "Pods deleted."

# 2. Start Remote Logging in Background
log_info "Starting remote scheduler logging to $SCHEDULER_LOG..."
# kill previous logger if any (optional, but good practice to allow multiple runs sequentially)
# We don't want to kill ALL loggers, maybe just the one we start? 
# For now, let's just start a new one.
# Use nohup to ensure it survives disconnection, run in background.
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "nohup sh -c 'kubectl -n nvshare-system logs -f -l name=nvshare-scheduler --timestamps | grep -v JSON > $SCHEDULER_LOG' > /dev/null 2>&1 & echo \$!" > .remote_logger_pid
REMOTE_PID=$(cat .remote_logger_pid)
log_info "Remote logger PID: $REMOTE_PID"

# 3. Create 4 Concurrent Tasks
log_info "Deploying 4 concurrent tasks (50%, 50%, 50%, 50%)..."
# log_info "Deploying 4 concurrent tasks (50%, 50%, 50%, 50%)..."

# Helper to apply pod
apply_task_pod() {
    local id=$1
    local limit=$2
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: complex-test-$id
  labels:
    app: nvshare-complex-test
  annotations:
    nvshare.com/gpu-core-limit: "$limit"
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b
    env:
    - name: NVSHARE_DEBUG
      value: "1"
    resources:
      limits:
        nvshare.com/gpu: 1
EOF
}

apply_task_pod 1 50
apply_task_pod 2 50
log_info "Waiting ${PLACEMENT_SETTLE_SECONDS}s to let first two 30% pods settle..."
sleep "$PLACEMENT_SETTLE_SECONDS"
apply_task_pod 3 50
apply_task_pod 4 50

# 4. Wait loop (Max 30 mins)
log_info "Waiting for tasks to complete (Timeout: 30m)..."
START_TIME=$(date +%s)
TIMEOUT=$((30 * 60))

while true; do
    ALL_DONE=true
    p1=$(kubectl get pod complex-test-1 -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    p2=$(kubectl get pod complex-test-2 -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    p3=$(kubectl get pod complex-test-3 -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    p4=$(kubectl get pod complex-test-4 -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    echo -ne "Status: P1=$p1 P2=$p2 P3=$p3 P4=$p4\r"

    for status in $p1 $p2 $p3 $p4; do
        if [ "$status" != "Succeeded" ] && [ "$status" != "Failed" ]; then
            ALL_DONE=false
        fi
    done

    if [ "$ALL_DONE" = "true" ]; then
        echo ""
        log_info "All tasks completed!"
        break
    fi

    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo ""
        log_warn "Timeout reached after 30 minutes!"
        break
    fi
    sleep 10
done

# 5. Stop Remote Logging
log_info "Stopping remote logger (PID: $REMOTE_PID)..."
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "kill $REMOTE_PID" || true

# 6. Fetch Logs
log_info "Fetching logs..."
if [ -f "$GET_LOG_SCRIPT" ]; then
    "$GET_LOG_SCRIPT" "$SCHEDULER_LOG" "complex-test"
else
    log_warn "Log fetch script helper not found at $GET_LOG_SCRIPT"
fi

log_info "Test Finished."
