#!/bin/bash
# Verify Prometheus metrics on remote node
# Usage: ./verify_metrics_remote.sh [POD_NAME]

SCHED_POD=$(kubectl get pod -n nvshare-system -l name=nvshare-scheduler -o jsonpath='{.items[0].metadata.name}')
if [ -z "$SCHED_POD" ]; then
    echo "Error: Scheduler pod not found"
    exit 1
fi

echo "Found scheduler pod: $SCHED_POD"

# Port forward in background
kubectl port-forward -n nvshare-system $SCHED_POD 9402:9402 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

METRICS_URL="http://localhost:9402"

echo "=== 1. Health Check ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $METRICS_URL/healthz)
[ "$HTTP_CODE" = "200" ] && echo "PASS: healthz returns 200" || echo "FAIL: healthz returns $HTTP_CODE"

echo ""
echo "=== 2. Metrics Endpoint ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $METRICS_URL/metrics)
[ "$HTTP_CODE" = "200" ] && echo "PASS: metrics returns 200" || echo "FAIL: metrics returns $HTTP_CODE"

echo ""
echo "=== 3. NVML Status ==="
curl -s $METRICS_URL/metrics | grep "nvshare_nvml_up"

echo ""
echo "=== 4. GPU Info ==="
curl -s $METRICS_URL/metrics | grep "nvshare_gpu_info"

echo ""
echo "=== 5. GPU Memory ==="
curl -s $METRICS_URL/metrics | grep "nvshare_gpu_memory_total_bytes"
curl -s $METRICS_URL/metrics | grep "nvshare_gpu_memory_used_bytes"

echo ""
echo "=== 6. GPU Utilization ==="
curl -s $METRICS_URL/metrics | grep "nvshare_gpu_utilization_ratio"

echo ""
echo "=== 7. Client Info ==="
CLIENT_COUNT=$(curl -s $METRICS_URL/metrics | grep -c "^nvshare_client_info")
echo "Active clients: $CLIENT_COUNT"
curl -s $METRICS_URL/metrics | grep "^nvshare_client_info"

echo ""
echo "=== 8. Scheduler Queues ==="
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_running_clients"
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_request_queue_clients"
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_wait_queue_clients"

echo ""
echo "=== 9. Event Counters ==="
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_messages_total"
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_drop_lock_total"

echo ""
echo "=== 10. Format Check ==="
HELP_COUNT=$(curl -s $METRICS_URL/metrics | grep -c "^# HELP")
TYPE_COUNT=$(curl -s $METRICS_URL/metrics | grep -c "^# TYPE")
echo "HELP lines: $HELP_COUNT, TYPE lines: $TYPE_COUNT"

echo ""
echo "=== 11. Managed Allocation ==="
curl -s $METRICS_URL/metrics | grep "nvshare_client_managed_allocated_bytes"

echo ""
echo "=== 12. NVML Per-Process Usage ==="
curl -s $METRICS_URL/metrics | grep "nvshare_client_nvml_used_bytes"

# Cleanup
kill $PF_PID
