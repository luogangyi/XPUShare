# Configuration
REMOTE_HOST="139.196.28.96"
REMOTE_USER="root"
REMOTE_DIR="/root/code/nvshare"
COMMON_SSH_OPTS="-o StrictHostKeyChecking=no"
BUILD_SSH_OPTS="$COMMON_SSH_OPTS -p 22"
GPU_SSH_OPTS="$COMMON_SSH_OPTS -p 32027"

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

log_timestamp() { date "+%H:%M:%S"; }
log_info() { echo -e "${GREEN}[INFO] [$(log_timestamp)]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN] [$(log_timestamp)]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR] [$(log_timestamp)]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP] [$(log_timestamp)]${NC} $1"; }

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
        git commit -m "wip: auto-commit by remote-test-compute-limit.sh [$(date +%H:%M:%S)]"
    fi

    log_info "===== 1. Syncing Code to $REMOTE_HOST (Port 22) ====="
    rsync -avz --exclude '.idea' -e "ssh $BUILD_SSH_OPTS" "$PROJECT_ROOT/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"

    log_info "===== 2. Remote Build (Port 22) ====="
    ssh $BUILD_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "cd $REMOTE_DIR && make build-base && make all"

    log_info "===== 3. Updating Local Manifests ====="
    "$SCRIPT_DIR/update-manifests.sh"

    log_info "===== 4. Redeploying Components ====="
    kubectl -n nvshare-system delete ds nvshare-scheduler nvshare-device-plugin --ignore-not-found=true --wait=true
    
    kubectl apply -f "$MANIFESTS_DIR/scheduler.yaml"
    kubectl apply -f "$MANIFESTS_DIR/device-plugin.yaml"
    
    log_info "Waiting for DaemonSets..."
    kubectl -n nvshare-system rollout status ds/nvshare-scheduler --timeout=120s
fi

echo ""
echo "==========================================="
echo "  Dynamic Compute Limit Test (Annotations)"
echo "==========================================="
echo ""

cleanup_pods

#######################################
# Test: Dynamic Compute Limit Adjustment
#######################################
log_step "Creating test pod with initial NO limit..."

# Ensure we use an image that runs long enough (matrix multiplication loop)
kubectl apply -f "$SCRIPT_DIR/kubernetes/manifests/manual-test-pod.yaml"

if ! wait_for_pod_running "manual-dynamic-test" 60; then
    log_error "Pod failed to start"
    exit 1
fi

log_info "Pod is running. Starting metrics collection from GPU Host (Port 30327)..."

# Ensure log directory exists (just in case)
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

# Start dmon in background on REMOTE (detached)
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "nohup nvidia-smi dmon -s u -d 1 -c 300 > $REMOTE_DIR/dmon.log 2>&1 &"
log_info "Started nvidia-smi dmon (detached)"

#######################################
# Step 1: Add compute limit annotation (30%)
#######################################
log_step "Step 1: Setting compute limit to 30%..."
kubectl annotate pod manual-dynamic-test nvshare.com/gpu-core-limit=30 --overwrite

log_info "Waiting for scheduler to detect annotation change..."
sleep 10
echo "Checking logs for 'Compute limit changed'..."
if kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=50 | grep -q "Compute limit changed"; then
    log_info "Verified: Annotation change detected."
else
    log_error "Failed to detect annotation change in logs."
    exit 1
fi

log_info "Collecting samples for 30% limit 30s..."
sleep 30

#######################################
# Step 2: Increase compute limit (80%)
#######################################
log_step "Step 2: Increasing compute limit to 80%..."
kubectl annotate pod manual-dynamic-test nvshare.com/gpu-core-limit=80 --overwrite

log_info "Waiting for scheduler to detect annotation change..."
sleep 10
if kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=50 | grep -q "Compute limit changed.*80%"; then
    log_info "Verified: Annotation change detected."
else
    log_error "Failed to detect annotation change in logs."
    exit 1
fi

log_info "Collecting samples for 80% limit (30s)..."
sleep 30

#######################################
# Step 3: Remove limit
#######################################
log_step "Step 3: Removing compute limit..."
kubectl annotate pod manual-dynamic-test nvshare.com/gpu-core-limit-

log_info "Waiting for scheduler to detect removal..."
sleep 10
if kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=50 | grep -q "Compute limit changed.*100%"; then
    log_info "Verified: Annotation change detected."
else
    log_error "Failed to detect annotation change in logs."
    exit 1
fi

log_info "Collecting samples for 100% limit (10s)..."
sleep 10

# Stop dmon
log_info "Stopping metrics collection..."
kill $DMON_PID || true
# Ensure remote process is killed too
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "pkill -f 'nvidia-smi dmon'" || true

log_step "Analyzing GPU Utilization..."
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "cat $REMOTE_DIR/dmon.log" > "$SCRIPT_DIR/dmon.log"

# Python analysis script
cat <<EOF > "$SCRIPT_DIR/analyze_dmon.py"
import sys

def parse_dmon(filename):
    data = []
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print("Error: dmon.log not found")
        return []

    for line in lines:
        if line.startswith('#') or 'sm' in line:
            continue
        parts = line.strip().split()
        if not parts: continue
        # Format: gpu pwr gtemp mtemp sm ...
        # index 4 is sm
        try:
            sm_util = int(parts[4])
            data.append(sm_util)
        except (ValueError, IndexError):
            pass
    return data

data = parse_dmon('$SCRIPT_DIR/dmon.log')
print(f"Total samples collected: {len(data)}")

# Timeline assumptions (approximate):
# 0-10s: Startup/No Limit
# 10s: 30% Annotation applied
# 10-20s: Detection lag + transition
# 20-50s: 30% Limit Active (Step 1)
# 50s: 80% Annotation applied
# 50-60s: Detection lag + transition
# 60-90s: 80% Limit Active (Step 2)
# 90s+: Removal

def analyze(name, data, start_idx, end_idx, target):
    if start_idx >= len(data) or end_idx > len(data):
        print(f"[{name}] Not enough samples ({len(data)} < {end_idx})")
        return

    subset = data[start_idx:end_idx]
    if not subset:
        print(f"[{name}] No data in range {start_idx}-{end_idx}")
        return

    avg = sum(subset) / len(subset)
    print(f"[{name}] Target: {target}% | Actual Avg: {avg:.2f}% | Samples: {len(subset)}")
    
    # Deviation check (+/- 15%)
    diff = abs(avg - target)
    if diff > 15:
        print(f"  -> WARN: Deviation > 15%")
    else:
        print(f"  -> PASS: Within tolerance")

# Adjust indices based on script sleeps:
# Start logging -> Step 1 (immed) -> sleep 10 (detect) -> sleep 30 (sample)
# Actually:
# 0s: Pod run & dmon start
# ... (wait pod running) ...
# T0: Step 1 (30%) applied
# T0+10s: Detection wait
# T0+40s: End of 30% sampling
# T0+40s: Step 2 (80%) applied
# T0+50s: Detection wait
# T0+80s: End of 80% sampling

# Since dmon is started AFTER pod is running, index 0 is roughly T0.
# Let's use conservative windows:
analyze("Step 1 (30%)", data, 15, 35, 30)
analyze("Step 2 (80%)", data, 55, 75, 80)

EOF

python3 "$SCRIPT_DIR/analyze_dmon.py"

