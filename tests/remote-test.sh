#!/bin/bash
set -e

# Configuration
REMOTE_HOST="139.196.28.96"
REMOTE_USER="root"
REMOTE_DIR="/root/code/nvshare"
# Using port 22 for code sync/build as per user instructions (implied by "ssh ... 免密登录")
SSH_OPTS="-o StrictHostKeyChecking=no" 

export KUBECONFIG=~/Code/configs/kubeconfig-fuyao-gpu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."

SKIP_SETUP="false"
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--skip-setup)
      SKIP_SETUP="true"
      shift # past argument
      ;;
    --serial)
      SERIAL_MODE="true"
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

if [ "$SKIP_SETUP" == "true" ]; then
    echo "Skipping setup steps (Auto-commit, Sync, Build, Clean, Deploy)..."
else
    echo "===== 0. Local Auto-Commit ====="
    cd "$PROJECT_ROOT"
    if [ -n "$(git status --porcelain)" ]; then
        echo "Changes detected. Committing locally..."
        git add .
        git commit -m "wip: auto-commit by remote-test.sh [$(date +%H:%M:%S)]"
    else
        echo "No changes to commit."
    fi

    echo "===== 1. Syncing Code to $REMOTE_HOST ====="
    # Sync current directory to remote (excluding .git to save time/bandwidth if not needed, or include if git metadata needed)
    # User said "scp -r nvshare/", assuming we sync the content effectively.
    # We use rsync for efficiency.
    if command -v rsync &> /dev/null; then
        # Include .git so remote build uses correct commit hash for tags
        rsync -avz --exclude '.idea' "$PROJECT_ROOT/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
    else
        # Fallback to scp (slower but works without rsync)
        echo "rsync not found, using scp..."
        ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_DIR"
        scp $SSH_OPTS -r "$PROJECT_ROOT/"* "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
    fi

    echo "===== 2. Remote Build ====="
    ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "cd $REMOTE_DIR && make all"

    echo "===== 3. Updating Local Manifests ====="
    "$SCRIPT_DIR/update-manifests.sh"

    echo "===== 4. Cleaning Cluster ====="
    echo "Deleting workloads..."
    kubectl delete pod -l app=nvshare-cross-gpu --ignore-not-found=true --wait=false 2>/dev/null || true
    # Wait a bit for pod termination to start
    sleep 3

    echo "Deleting system components..."
    kubectl -n nvshare-system delete ds nvshare-device-plugin nvshare-scheduler --ignore-not-found=true --wait=true

    # Ensure workloads are fully gone (optional but good for safety)
    echo "Waiting for pods to terminate..."
    kubectl wait --for=delete pod -l app=nvshare-cross-gpu --timeout=60s 2>/dev/null || true

    echo "===== 5. Deploying New System ====="
    
    TARGET_MODE="auto"
    if [ "$SERIAL_MODE" == "true" ]; then
        TARGET_MODE="serial"
        echo "Deploying Scheduler in SERIAL mode..."
    else
        echo "Deploying Scheduler in AUTO/CONCURRENT mode..."
    fi

    # Generate temporary manifest with environment variable using safer logic (no sed/platform issues)
    SCHEDULER_MANIFEST="/tmp/nvshare-scheduler-deployed.yaml"
    rm -f "$SCHEDULER_MANIFEST"
    
    while IFS= read -r line; do
        echo "$line" >> "$SCHEDULER_MANIFEST"
        if [[ "$line" == *"imagePullPolicy:"* ]]; then
            echo "        env:" >> "$SCHEDULER_MANIFEST"
            echo "        - name: NVSHARE_SCHEDULING_MODE" >> "$SCHEDULER_MANIFEST"
            echo "          value: \"$TARGET_MODE\"" >> "$SCHEDULER_MANIFEST"
        fi
    done < "$SCRIPT_DIR/manifests/scheduler.yaml"

    kubectl apply -f "$SCHEDULER_MANIFEST"
    kubectl apply -f "$SCRIPT_DIR/manifests/device-plugin.yaml"

    echo "Waiting for DaemonSets to rollout..."
    kubectl -n nvshare-system rollout status ds/nvshare-scheduler --timeout=60s
    kubectl -n nvshare-system rollout status ds/nvshare-device-plugin --timeout=60s
fi

echo "===== 6. Running Test ====="
# Run with default 4 pods or passed arg
"$SCRIPT_DIR/scripts/test-cross-gpu.sh" "$@"

