#!/bin/bash
set -e

SCHEDULER_LOG_NAME="$1"
POD_NAME_PREFIX="$2"

if [ -z "$SCHEDULER_LOG_NAME" ] || [ -z "$POD_NAME_PREFIX" ]; then
    echo "Usage: $0 <scheduler_log_name> <pod_name_prefix>"
    echo "Example: $0 scheduler16.log complex-test"
    exit 1
fi

# Generate timestamp
TIMESTAMP=$(date +"%Y%m%d-%H%M")
LOG_DIR=".tmplog/$TIMESTAMP"

echo "Creating log directory: $LOG_DIR"
mkdir -p "$LOG_DIR"

# 1. Fetch remote scheduler log
echo "Fetching remote scheduler log: $SCHEDULER_LOG_NAME"
scp -P 32027 root@139.196.28.96:/root/"$SCHEDULER_LOG_NAME" "$LOG_DIR/"

# 2. Setup Kubeconfig
export KUBECONFIG=~/Code/configs/kubeconfig-fuyao-gpu

# 3. Find pods
echo "Searching for pods with prefix: $POD_NAME_PREFIX"
PODS=$(kubectl get pods -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "^$POD_NAME_PREFIX")

if [ -n "$PODS" ]; then
    for POD in $PODS; do
        echo "Exporting logs for pod: $POD"
        kubectl logs "$POD" --timestamps > "$LOG_DIR/$POD.log"
    done
else
    echo "No pods found with prefix: $POD_NAME_PREFIX"
fi

echo "Done. Logs saved to $LOG_DIR"
