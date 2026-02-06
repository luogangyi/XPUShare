#!/bin/bash
set -e

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
        git commit -m "wip: auto-commit by remote-test-complex.sh [$(date +%H:%M:%S)]"
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
echo "  Complex Compute Limit Test (Multi-Pod)"
echo "==========================================="
echo ""

cleanup_pods

#######################################
# Deploy Pods
#######################################
log_step "Deploying 2 Test Pods..."

# Use a common label app=nvshare-complex-test
for i in 1 2; do
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: complex-test-$i
  labels:
    app: nvshare-complex-test
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
done

if ! wait_for_pod_running "complex-test-1" 60; then log_error "Pod 1 failed"; exit 1; fi
if ! wait_for_pod_running "complex-test-2" 60; then log_error "Pod 2 failed"; exit 1; fi

log_info "Pods are running. Initializing monitoring..."

# Ensure local log directory exists
mkdir -p .tmplog

# Ensure remote log directory exists
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

# Get GPU Mapping (UUID -> Index)
log_info "Retrieving GPU Topology..."
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "nvidia-smi -L" > ".tmplog/nvidia_smi_L.txt"
cat ".tmplog/nvidia_smi_L.txt"

# Start dmon
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "nohup nvidia-smi dmon -s u -d 1 -c 300 > $REMOTE_DIR/complex_dmon.log 2>&1 &"
DMON_PID=$! # This is local PID of ssh, not handy. We use pkill later.
log_info "Started nvidia-smi dmon (detached)"

#######################################
# Scenario 1: Set Limits (Test-1: 30%, Test-2: 60%)
#######################################
log_step "Setting Limits: Test-1=30%, Test-2=60%..."
kubectl annotate pod complex-test-1 nvshare.com/gpu-core-limit=30 --overwrite
kubectl annotate pod complex-test-2 nvshare.com/gpu-core-limit=60 --overwrite

log_info "Waiting for scheduler detection..."
sleep 10
kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=100 | grep "Compute limit changed"

wait_for_scheduler_log() {
    local pattern=$1
    local timeout=${2:-30}
    log_info "Waiting for log: '$pattern' (timeout ${timeout}s)..."
    local start_time=$(date +%s)
    while true; do
        # Check logs (recent 60s to capture events)
        if kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=100 --prefix=false | grep -q "$pattern"; then
            log_info "Found log: $pattern"
            return 0
        fi
        
        local current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt $timeout ]; then
            log_error "Timeout waiting for log: $pattern"
            return 1
        fi
        sleep 2
    done
}

#######################################
# Scenario 1: Set Limits (Test-1: 30%, Test-2: 60%)
#######################################
log_step "Setting Limits: Test-1=30%, Test-2=60%..."
kubectl annotate pod complex-test-1 nvshare.com/gpu-core-limit=30 --overwrite
kubectl annotate pod complex-test-2 nvshare.com/gpu-core-limit=60 --overwrite

# Wait for both events
wait_for_scheduler_log "Compute limit changed.*30%"
wait_for_scheduler_log "Compute limit changed.*60%"

log_info "Collecting samples (30s)..."
sleep 30

#######################################
# Scenario 2: Dynamic Update (Test-1: 70%, Test-2: 20%)
#######################################
log_step "Updating Limits: Test-1=70%, Test-2=20%..."
kubectl annotate pod complex-test-1 nvshare.com/gpu-core-limit=70 --overwrite
kubectl annotate pod complex-test-2 nvshare.com/gpu-core-limit=20 --overwrite

wait_for_scheduler_log "Compute limit changed.*70%"
wait_for_scheduler_log "Compute limit changed.*20%"

log_info "Collecting samples (30s)..."
sleep 30

#######################################
# Stop & Analyze
#######################################
log_step "Step 3: Removing Limits..."
kubectl annotate pod complex-test-1 nvshare.com/gpu-core-limit-
kubectl annotate pod complex-test-2 nvshare.com/gpu-core-limit-

wait_for_scheduler_log "Compute limit changed.*100%"

log_info "Collecting samples (10s)..."
sleep 10

#######################################
# Stop & Analyze
#######################################
log_info "Stopping metrics collection..."
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "pkill -f 'nvidia-smi dmon'" || true

log_step "Retrieving Logs & Analyzing..."
ssh $GPU_SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "cat $REMOTE_DIR/complex_dmon.log" > ".tmplog/complex_dmon.log"

# Retrieve Scheduler logs to map Pod -> UUID
kubectl -n nvshare-system logs -l name=nvshare-scheduler --tail=1000 > ".tmplog/scheduler_full.log"

# Analysis Script
cat <<EOF > "$SCRIPT_DIR/analyze_complex.py"
import re
import sys

def parse_gpu_topology(filename):
    # GPU 0: Tesla T4 (UUID: GPU-...)
    mapping = {}
    with open(filename, 'r') as f:
        for line in f:
            m = re.search(r'GPU\s+(\d+):.*(UUID:\s+GPU-[0-9a-f-]+)', line)
            if m:
                idx = int(m.group(1))
                uuid = m.group(2).split()[-1] # GPU-xxxx
                mapping[uuid] = idx
    return mapping

def parse_pod_uuid_mapping(filename):
    # [NVSHARE][INFO]: Registered client ... on GPU GPU-xxxx with Pod name = complex-test-1
    pod_map = {}
    with open(filename, 'r') as f:
        for line in f:
            if "Registered client" in line and "Pod name =" in line:
                m_pod = re.search(r'Pod name = ([\w-]+)', line)
                m_gpu = re.search(r'GPU (GPU-[0-9a-f-]+)', line)
                if m_pod and m_gpu:
                    pod_map[m_pod.group(1)] = m_gpu.group(1)
    return pod_map

def parse_dmon(filename):
    data = {} # idx -> list of values
    with open(filename, 'r') as f:
        for line in f:
            if line.startswith('#') or 'sm' in line: continue
            parts = line.strip().split()
            if len(parts) < 5: continue
            try:
                idx = int(parts[0])
                sm = int(parts[4])
                if idx not in data: data[idx] = []
                data[idx].append(sm)
            except: pass
    return data

uuid_to_idx = parse_gpu_topology(".tmplog/nvidia_smi_L.txt")
pod_to_uuid = parse_pod_uuid_mapping(".tmplog/scheduler_full.log")
dmon_data = parse_dmon(".tmplog/complex_dmon.log")

print("Mapping Info:")
for pod, uuid in pod_to_uuid.items():
    if uuid in uuid_to_idx:
        idx = uuid_to_idx[uuid]
        print(f"  {pod} -> {uuid} -> GPU {idx}")
    else:
        print(f"  {pod} -> {uuid} -> GPU ???")

def analyze_phase(phase_name, start, end, targets):
    print(f"\nPhase: {phase_name} (Samples {start}-{end})")
    for pod, target in targets.items():
        if pod not in pod_to_uuid:
            print(f"  {pod}: No mapping found")
            continue
        uuid = pod_to_uuid[pod]
        idx = uuid_to_idx.get(uuid)
        
        if idx is not None and idx in dmon_data:
            samples = dmon_data[idx]
            if start < len(samples):
                subset = samples[start:min(end, len(samples))]
                if subset:
                    avg = sum(subset)/len(subset)
                    print(f"  {pod} (GPU {idx}): Target {target}% | Actual {avg:.1f}%")
                    if abs(avg - target) > 15:
                         print("    -> WARN: High deviation")
                    else:
                         print("    -> PASS")
                else:
                    print(f"  {pod} (GPU {idx}): No data in range")
        else:
            print(f"  {pod}: No dmon data for GPU {idx}")

# Timeline:
# 0s: Start
# 10s: Setup
# Scen 1 (30s): ~15-45s (conservative)
# 40s: Update
# Scen 2 (30s): ~55-85s (conservative)

analyze_phase("Scenario 1", 15, 35, {"complex-test-1": 30, "complex-test-2": 60})
analyze_phase("Scenario 2", 55, 75, {"complex-test-1": 70, "complex-test-2": 20})

EOF

python3 "$SCRIPT_DIR/analyze_complex.py"

cleanup_pods
