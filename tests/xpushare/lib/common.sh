#!/bin/bash

set -euo pipefail

XPUSHARE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
XPUSHARE_ROOT=$(cd "$XPUSHARE_LIB_DIR/.." && pwd)
PROJECT_ROOT=$(cd "$XPUSHARE_ROOT/../.." && pwd)

XPUSHARE_KUBECONFIG_C1_DEFAULT="$HOME/Code/configs/kubeconfig-fuyao-gpu"
XPUSHARE_KUBECONFIG_C2_DEFAULT="$HOME/Code/configs/kubeconfig-kcs-gpu"

XPUSHARE_KUBECONFIG_C1="${XPUSHARE_KUBECONFIG_C1:-$XPUSHARE_KUBECONFIG_C1_DEFAULT}"
XPUSHARE_KUBECONFIG_C2="${XPUSHARE_KUBECONFIG_C2:-$XPUSHARE_KUBECONFIG_C2_DEFAULT}"

XPUSHARE_CLUSTER=""
XPUSHARE_CLUSTER_NAME=""
XPUSHARE_SUITE=""
XPUSHARE_CASE_ID=""
XPUSHARE_CASE_LOG_DIR=""
XPUSHARE_RUN_ID="${XPUSHARE_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
XPUSHARE_LOG_ROOT="${XPUSHARE_LOG_ROOT:-$PROJECT_ROOT/.tmplog/$XPUSHARE_RUN_ID/xpushare}"
XPUSHARE_RESUME_MODE="${XPUSHARE_RESUME_MODE:-0}"
XPUSHARE_RUN_CASE_SUMMARY_FILE="${XPUSHARE_RUN_CASE_SUMMARY_FILE:-}"
XPUSHARE_CASE_START_RFC3339=""
XPUSHARE_CASE_START_EPOCH=""

XPUSHARE_DEFAULT_NAMESPACE="${XPUSHARE_DEFAULT_NAMESPACE:-default}"
XPUSHARE_SYSTEM_NAMESPACE="${XPUSHARE_SYSTEM_NAMESPACE:-nvshare-system}"
XPUSHARE_METRICS_PORT="${XPUSHARE_METRICS_PORT:-9402}"
XPUSHARE_METRICS_LOCAL_PORT="${XPUSHARE_METRICS_LOCAL_PORT:-19402}"

XP_IMAGE_PYTORCH_ADD="${XP_IMAGE_PYTORCH_ADD:-registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-5fed3e5b}"
XP_IMAGE_PYTORCH_ADD_SMALL="${XP_IMAGE_PYTORCH_ADD_SMALL:-registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small-5fed3e5b}"
XP_IMAGE_PYTORCH_ADD_IDLE_SMALL="${XP_IMAGE_PYTORCH_ADD_IDLE_SMALL:-registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-idle-small-5fed3e5b}"

XP_DEFAULT_POD_TIMEOUT_SEC="${XP_DEFAULT_POD_TIMEOUT_SEC:-1800}"
XP_DEFAULT_SUITE_TIMEOUT_SEC="${XP_DEFAULT_SUITE_TIMEOUT_SEC:-3600}"
XP_SOAK_DURATION_SEC="${XP_SOAK_DURATION_SEC:-21600}"
XP_METRICS_SCRAPE_INTERVAL_SEC="${XP_METRICS_SCRAPE_INTERVAL_SEC:-2}"
XP_METRICS_STRESS_DURATION_SEC="${XP_METRICS_STRESS_DURATION_SEC:-120}"
XP_DYNAMIC_UPDATE_EXPECT_SEC="${XP_DYNAMIC_UPDATE_EXPECT_SEC:-15}"
XP_DYNAMIC_UPDATE_OBSERVE_TIMEOUT_SEC="${XP_DYNAMIC_UPDATE_OBSERVE_TIMEOUT_SEC:-90}"
XP_STAB_SHORT_SEC="${XP_STAB_SHORT_SEC:-21600}"
XP_STAB_LONG_SEC="${XP_STAB_LONG_SEC:-86400}"
XP_STAB_UPDATE_INTERVAL_SEC="${XP_STAB_UPDATE_INTERVAL_SEC:-300}"
XP_LEAK_SAMPLE_INTERVAL_SEC="${XP_LEAK_SAMPLE_INTERVAL_SEC:-60}"
XP_ENABLE_DISRUPTIVE="${XP_ENABLE_DISRUPTIVE:-0}"

# Cluster capacity defaults (active GPUs exposed by device-plugin)
# C1: 2 nodes * 2 GPU/node * 10 vGPU/GPU = 40
# C2: 2 nodes * 8 GPU/node * 10 vGPU/GPU = 160
XP_CLUSTER_C1_TOTAL_VGPU="${XP_CLUSTER_C1_TOTAL_VGPU:-40}"
XP_CLUSTER_C2_TOTAL_VGPU="${XP_CLUSTER_C2_TOTAL_VGPU:-160}"
XP_PERF_SCALE_SET_C1="${XP_PERF_SCALE_SET_C1:-}"
XP_PERF_SCALE_SET_C2="${XP_PERF_SCALE_SET_C2:-}"
XP_TEST_POD_DELETE_TIMEOUT_SEC="${XP_TEST_POD_DELETE_TIMEOUT_SEC:-240}"

# SSH placeholders (user should set real values in env or config file)
XPUSHARE_C1_NODE1_SSH="${XPUSHARE_C1_NODE1_SSH:-}"
XPUSHARE_C1_NODE2_SSH="${XPUSHARE_C1_NODE2_SSH:-}"
XPUSHARE_C2_NODE1_SSH="${XPUSHARE_C2_NODE1_SSH:-}"
XPUSHARE_C2_NODE2_SSH="${XPUSHARE_C2_NODE2_SSH:-}"

XP_W4_MATRIX_N_C1="${XP_W4_MATRIX_N_C1:-52000}"
XP_W4_MATRIX_N_C2="${XP_W4_MATRIX_N_C2:-76000}"
XP_W5_DURATION_SEC="${XP_W5_DURATION_SEC:-300}"

# Optional remote scheduler log streaming (large log optimization)
XPUSHARE_REMOTE_SCHED_LOG_DIR="${XPUSHARE_REMOTE_SCHED_LOG_DIR:-/tmp/xpushare-scheduler-logs}"
XPUSHARE_REMOTE_SCHED_ACTIVE=0
XPUSHARE_REMOTE_SCHED_SSH_CMD=""
XPUSHARE_REMOTE_SCHED_NODE_ALIAS=""
XPUSHARE_REMOTE_SCHED_PID=""
XPUSHARE_REMOTE_SCHED_FILE=""

xp_now() {
  date '+%Y-%m-%d %H:%M:%S'
}

xp_log_info() {
  echo "[XPUSHARE][INFO][$(xp_now)] $*"
}

xp_log_warn() {
  echo "[XPUSHARE][WARN][$(xp_now)] $*" >&2
}

xp_log_error() {
  echo "[XPUSHARE][ERROR][$(xp_now)] $*" >&2
}

xp_case_note() {
  local msg="$1"
  echo "[$(xp_now)] $msg" >> "$XPUSHARE_CASE_LOG_DIR/notes.log"
}

xp_case_kv() {
  local key="$1"
  local value="$2"
  echo "$key=$value" >> "$XPUSHARE_CASE_LOG_DIR/metrics.env"
}

xp_case_slug() {
  local raw="$1"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

xp_case_result_path() {
  local suite="$1"
  local case_id="$2"
  echo "$XPUSHARE_LOG_ROOT/$XPUSHARE_CLUSTER_NAME/$suite/$case_id/result.json"
}

xp_case_result_status() {
  local suite="$1"
  local case_id="$2"
  local result_file
  result_file=$(xp_case_result_path "$suite" "$case_id")
  if [ ! -f "$result_file" ]; then
    echo ""
    return 0
  fi
  sed -n 's/^.*"status":"\([^"]*\)".*$/\1/p' "$result_file" | tail -n 1
}

xp_case_should_skip() {
  local suite="$1"
  local case_id="$2"
  local prev

  if [ "$XPUSHARE_RESUME_MODE" != "1" ]; then
    return 1
  fi

  prev=$(xp_case_result_status "$suite" "$case_id")
  if [ "$prev" = "PASS" ]; then
    xp_log_info "resume mode: skip already passed case $case_id ($suite)"
    return 0
  fi

  return 1
}

xp_require_tools() {
  local tool
  for tool in kubectl sed awk grep curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      xp_log_error "missing required tool: $tool"
      exit 1
    fi
  done
}

xp_load_config_file() {
  local cfg="$1"
  if [ -n "$cfg" ]; then
    if [ ! -f "$cfg" ]; then
      xp_log_error "config file not found: $cfg"
      exit 1
    fi
    # shellcheck source=/dev/null
    . "$cfg"
    xp_log_info "loaded config file: $cfg"
  fi
}

xp_select_cluster() {
  local cluster="$1"

  case "$cluster" in
    c1|cluster1)
      export KUBECONFIG="$XPUSHARE_KUBECONFIG_C1"
      XPUSHARE_CLUSTER="c1"
      XPUSHARE_CLUSTER_NAME="cluster1"
      ;;
    c2|cluster2)
      export KUBECONFIG="$XPUSHARE_KUBECONFIG_C2"
      XPUSHARE_CLUSTER="c2"
      XPUSHARE_CLUSTER_NAME="cluster2"
      ;;
    *)
      xp_log_error "unknown cluster: $cluster"
      return 1
      ;;
  esac

  xp_log_info "selected cluster: $XPUSHARE_CLUSTER_NAME"
  xp_log_info "KUBECONFIG=$KUBECONFIG"
}

xp_init_run_dirs() {
  mkdir -p "$XPUSHARE_LOG_ROOT"
  mkdir -p "$XPUSHARE_LOG_ROOT/$XPUSHARE_CLUSTER_NAME"
}

xp_case_begin() {
  local suite="$1"
  local case_id="$2"

  XPUSHARE_SUITE="$suite"
  XPUSHARE_CASE_ID="$case_id"
  XPUSHARE_CASE_LOG_DIR="$XPUSHARE_LOG_ROOT/$XPUSHARE_CLUSTER_NAME/$suite/$case_id"
  XPUSHARE_CASE_START_RFC3339="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  XPUSHARE_CASE_START_EPOCH="$(date +%s)"
  XPUSHARE_REMOTE_SCHED_ACTIVE=0
  XPUSHARE_REMOTE_SCHED_SSH_CMD=""
  XPUSHARE_REMOTE_SCHED_NODE_ALIAS=""
  XPUSHARE_REMOTE_SCHED_PID=""
  XPUSHARE_REMOTE_SCHED_FILE=""

  mkdir -p "$XPUSHARE_CASE_LOG_DIR"
  mkdir -p "$XPUSHARE_CASE_LOG_DIR/pods"

  cat > "$XPUSHARE_CASE_LOG_DIR/meta.env" <<META
RUN_ID=$XPUSHARE_RUN_ID
CLUSTER=$XPUSHARE_CLUSTER_NAME
SUITE=$suite
CASE_ID=$case_id
START_TIME=$(xp_now)
START_TIME_RFC3339=$XPUSHARE_CASE_START_RFC3339
KUBECONFIG=$KUBECONFIG
META

  if xp_start_remote_scheduler_logger; then
    xp_log_info "remote scheduler log capture enabled for case $case_id"
  else
    xp_case_note "remote scheduler log capture not enabled, fallback to in-cluster logs"
  fi

  xp_log_info "===== CASE START: $case_id ($suite, $XPUSHARE_CLUSTER_NAME) ====="
}

xp_analyze_case_artifacts() {
  local status="$1"
  local summary="$2"
  local pod_log_count pass_log_count error_log_count health_code
  local sched_error_count sched_warn_count duration_sec

  pod_log_count=0
  pass_log_count=0
  error_log_count=0
  health_code=""
  sched_error_count=0
  sched_warn_count=0
  duration_sec=0

  if [ -d "$XPUSHARE_CASE_LOG_DIR/pods" ]; then
    pod_log_count=$(find "$XPUSHARE_CASE_LOG_DIR/pods" -type f -name '*.log' | wc -l | awk '{print $1}')
    pass_log_count=$( (grep -Erh "PASS" "$XPUSHARE_CASE_LOG_DIR/pods" 2>/dev/null || true) | wc -l | awk '{print $1}' )
    error_log_count=$( (grep -Erh "ERROR|OutOfMemory|CUDA_ERROR|OOM" "$XPUSHARE_CASE_LOG_DIR/pods" 2>/dev/null || true) | wc -l | awk '{print $1}' )
  fi

  if [ -f "$XPUSHARE_CASE_LOG_DIR/metrics_health.txt" ]; then
    health_code=$(sed -n 's/^HTTP_CODE=\([0-9][0-9][0-9]\)$/\1/p' "$XPUSHARE_CASE_LOG_DIR/metrics_health.txt" | tail -n 1)
  fi

  if [ -f "$XPUSHARE_CASE_LOG_DIR/scheduler.log" ]; then
    sched_error_count=$(grep -Ec "ERROR|error" "$XPUSHARE_CASE_LOG_DIR/scheduler.log" || true)
    sched_warn_count=$(grep -Ec "WARN|warning" "$XPUSHARE_CASE_LOG_DIR/scheduler.log" || true)
  fi

  if [ -n "$XPUSHARE_CASE_START_EPOCH" ]; then
    duration_sec=$(( $(date +%s) - XPUSHARE_CASE_START_EPOCH ))
  fi

  cat > "$XPUSHARE_CASE_LOG_DIR/analysis.env" <<ANALYSIS
STATUS=$status
SUMMARY=$summary
DURATION_SEC=$duration_sec
POD_LOG_COUNT=$pod_log_count
POD_PASS_LINES=$pass_log_count
POD_ERROR_LINES=$error_log_count
METRICS_HEALTH_HTTP_CODE=${health_code:-}
SCHEDULER_ERROR_LINES=$sched_error_count
SCHEDULER_WARN_LINES=$sched_warn_count
ANALYSIS

  cat > "$XPUSHARE_CASE_LOG_DIR/analysis.txt" <<ANALYSIS_TXT
status=$status
summary=$summary
duration_sec=$duration_sec
pod_log_count=$pod_log_count
pod_pass_lines=$pass_log_count
pod_error_lines=$error_log_count
metrics_health_http_code=${health_code:-NA}
scheduler_error_lines=$sched_error_count
scheduler_warn_lines=$sched_warn_count
ANALYSIS_TXT
}

xp_append_run_case_summary() {
  local status="$1"
  local summary="$2"

  if [ -z "$XPUSHARE_RUN_CASE_SUMMARY_FILE" ]; then
    return 0
  fi

  echo -e "$XPUSHARE_CLUSTER_NAME\t$XPUSHARE_SUITE\t$XPUSHARE_CASE_ID\t$status\t$summary\t$XPUSHARE_CASE_LOG_DIR" >> "$XPUSHARE_RUN_CASE_SUMMARY_FILE"
}

xp_case_end() {
  local status="$1"
  local summary="$2"

  if [ "$XPUSHARE_REMOTE_SCHED_ACTIVE" = "1" ]; then
    xp_stop_remote_scheduler_logger "$XPUSHARE_CASE_LOG_DIR/scheduler.log" || true
  fi

  {
    echo "END_TIME=$(xp_now)"
    echo "STATUS=$status"
    echo "SUMMARY=$summary"
  } >> "$XPUSHARE_CASE_LOG_DIR/meta.env"

  cat > "$XPUSHARE_CASE_LOG_DIR/result.json" <<JSON
{"run_id":"$XPUSHARE_RUN_ID","cluster":"$XPUSHARE_CLUSTER_NAME","suite":"$XPUSHARE_SUITE","case_id":"$XPUSHARE_CASE_ID","status":"$status","summary":"$summary","end_time":"$(xp_now)"}
JSON

  xp_analyze_case_artifacts "$status" "$summary"
  xp_append_run_case_summary "$status" "$summary"
  xp_log_info "===== CASE END: $XPUSHARE_CASE_ID status=$status summary=$summary ====="
}

xp_scheduler_pod() {
  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" get pod -l name=nvshare-scheduler \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

xp_assert_scheduler_ready() {
  local ready
  ready=$(kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" get pod -l name=nvshare-scheduler \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c '^Running$' || true)
  if [ "$ready" -lt 1 ]; then
    xp_log_error "no running scheduler pod found in namespace $XPUSHARE_SYSTEM_NAMESPACE"
    return 1
  fi
  return 0
}

xp_remote_scheduler_parse_ssh_for_scp() {
  local ssh_cmd="$1"
  local -a parts
  local token host user port i

  host=""
  user=""
  port="22"

  read -r -a parts <<< "$ssh_cmd"
  if [ "${parts[0]:-}" != "ssh" ]; then
    return 1
  fi

  i=1
  while [ "$i" -lt "${#parts[@]}" ]; do
    token="${parts[$i]}"
    case "$token" in
      -p)
        i=$((i + 1))
        port="${parts[$i]:-$port}"
        ;;
      -l)
        i=$((i + 1))
        user="${parts[$i]:-$user}"
        ;;
      -o|-i|-F|-J|-b|-c|-D|-E|-e|-I|-L|-m|-O|-Q|-R|-S|-W|-w)
        i=$((i + 1))
        ;;
      -*)
        ;;
      *@*)
        host="$token"
        ;;
      *)
        if [ -z "$host" ]; then
          host="$token"
        fi
        ;;
    esac
    i=$((i + 1))
  done

  if [ -z "$host" ]; then
    return 1
  fi
  if [[ "$host" != *@* ]] && [ -n "$user" ]; then
    host="$user@$host"
  fi

  echo "$host|$port"
  return 0
}

xp_start_remote_scheduler_logger() {
  local remote_dir remote_cmd escaped_cmd pid alias ssh_cmd

  remote_dir="$XPUSHARE_REMOTE_SCHED_LOG_DIR/$XPUSHARE_RUN_ID/$XPUSHARE_CLUSTER_NAME/$XPUSHARE_SUITE/$XPUSHARE_CASE_ID"
  XPUSHARE_REMOTE_SCHED_FILE="$remote_dir/scheduler.log"

  for alias in node1 node2; do
    ssh_cmd=$(xp_resolve_ssh_cmd "$XPUSHARE_CLUSTER" "$alias")
    if [ -z "$ssh_cmd" ]; then
      continue
    fi

    remote_cmd="mkdir -p '$remote_dir'; nohup kubectl -n $XPUSHARE_SYSTEM_NAMESPACE logs -f -l name=nvshare-scheduler --timestamps > '$XPUSHARE_REMOTE_SCHED_FILE' 2>&1 & echo \$!"
    escaped_cmd=$(printf '%q' "$remote_cmd")
    pid=$(eval "$ssh_cmd \"bash -lc $escaped_cmd\"" 2>/dev/null | tr -d '\r\n' || true)

    if [ -n "$pid" ]; then
      XPUSHARE_REMOTE_SCHED_SSH_CMD="$ssh_cmd"
      XPUSHARE_REMOTE_SCHED_NODE_ALIAS="$alias"
      XPUSHARE_REMOTE_SCHED_PID="$pid"
      XPUSHARE_REMOTE_SCHED_ACTIVE=1
      xp_case_note "remote scheduler logger started node_alias=$alias pid=$pid file=$XPUSHARE_REMOTE_SCHED_FILE"
      return 0
    fi
  done

  XPUSHARE_REMOTE_SCHED_ACTIVE=0
  XPUSHARE_REMOTE_SCHED_SSH_CMD=""
  XPUSHARE_REMOTE_SCHED_NODE_ALIAS=""
  XPUSHARE_REMOTE_SCHED_PID=""
  return 1
}

xp_stop_remote_scheduler_logger() {
  local outfile="$1"
  local scp_target scp_host scp_port

  if [ "$XPUSHARE_REMOTE_SCHED_ACTIVE" != "1" ] || [ -z "$XPUSHARE_REMOTE_SCHED_SSH_CMD" ]; then
    return 1
  fi

  if [ -n "$XPUSHARE_REMOTE_SCHED_PID" ]; then
    eval "$XPUSHARE_REMOTE_SCHED_SSH_CMD \"kill $XPUSHARE_REMOTE_SCHED_PID >/dev/null 2>&1 || true\"" >/dev/null 2>&1 || true
    xp_safe_sleep 1
  fi

  if command -v scp >/dev/null 2>&1 && scp_target=$(xp_remote_scheduler_parse_ssh_for_scp "$XPUSHARE_REMOTE_SCHED_SSH_CMD"); then
    scp_host="${scp_target%|*}"
    scp_port="${scp_target#*|}"
    if scp -q -o StrictHostKeyChecking=no -P "$scp_port" \
      "$scp_host:$XPUSHARE_REMOTE_SCHED_FILE" "$outfile" >/dev/null 2>&1; then
      xp_case_note "fetched remote scheduler log by scp from $scp_host"
    else
      eval "$XPUSHARE_REMOTE_SCHED_SSH_CMD \"cat '$XPUSHARE_REMOTE_SCHED_FILE'\"" > "$outfile" 2>/dev/null || true
      xp_case_note "scp failed, fallback to ssh cat for scheduler log"
    fi
  else
    eval "$XPUSHARE_REMOTE_SCHED_SSH_CMD \"cat '$XPUSHARE_REMOTE_SCHED_FILE'\"" > "$outfile" 2>/dev/null || true
    xp_case_note "scp parse unavailable, fetched scheduler log by ssh cat"
  fi

  XPUSHARE_REMOTE_SCHED_ACTIVE=0
  XPUSHARE_REMOTE_SCHED_SSH_CMD=""
  XPUSHARE_REMOTE_SCHED_NODE_ALIAS=""
  XPUSHARE_REMOTE_SCHED_PID=""
  return 0
}

xp_capture_scheduler_logs() {
  local outfile="$1"
  if [ "$XPUSHARE_REMOTE_SCHED_ACTIVE" = "1" ]; then
    xp_stop_remote_scheduler_logger "$outfile" || true
    if [ -s "$outfile" ]; then
      return 0
    fi
  fi

  if [ -n "$XPUSHARE_CASE_START_RFC3339" ]; then
    kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" logs -l name=nvshare-scheduler \
      --timestamps --since-time="$XPUSHARE_CASE_START_RFC3339" > "$outfile" 2>&1 || true
    return 0
  fi

  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" logs -l name=nvshare-scheduler --timestamps > "$outfile" 2>&1 || true
}

xp_capture_device_plugin_logs() {
  local outfile="$1"
  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" logs -l name=nvshare-device-plugin --timestamps > "$outfile" 2>&1 || true
}

xp_capture_scheduler_proc_stats() {
  local outfile="$1"
  local pod
  pod=$(xp_scheduler_pod)
  if [ -z "$pod" ]; then
    echo "scheduler pod not found" > "$outfile"
    return 1
  fi

  {
    echo "# scheduler pod: $pod"
    kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" exec "$pod" -- sh -c 'cat /proc/1/status; echo "FD_COUNT=$(ls /proc/1/fd | wc -l)"' 2>&1
  } > "$outfile" || true
}

xp_scheduler_pod_ip() {
  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" get pod -l name=nvshare-scheduler \
    -o jsonpath='{range .items[*]}{.status.phase}{"|"}{.status.podIP}{"\n"}{end}' 2>/dev/null | \
    awk -F'|' '$1=="Running" && $2!="" {print $2; exit}'
}

xp_pick_cluster_node_ssh() {
  local alias ssh_cmd

  for alias in node1 node2; do
    ssh_cmd=$(xp_resolve_ssh_cmd "$XPUSHARE_CLUSTER" "$alias")
    if [ -n "$ssh_cmd" ]; then
      echo "$alias|$ssh_cmd"
      return 0
    fi
  done

  return 1
}

xp_capture_metrics_snapshot_remote() {
  local outfile="$1"
  local scheduler_ip picked alias ssh_cmd url

  scheduler_ip=$(xp_scheduler_pod_ip)
  if [ -z "$scheduler_ip" ]; then
    return 1
  fi

  picked=$(xp_pick_cluster_node_ssh || true)
  if [ -z "$picked" ]; then
    return 1
  fi
  alias="${picked%%|*}"
  ssh_cmd="${picked#*|}"
  url="http://$scheduler_ip:$XPUSHARE_METRICS_PORT/metrics"

  if eval "$ssh_cmd \"curl -fsS -m 10 '$url'\"" > "$outfile" 2>/dev/null; then
    xp_case_note "metrics snapshot via remote node=$alias url=$url"
    return 0
  fi

  return 1
}

xp_capture_metrics_health_remote() {
  local outfile="$1"
  local scheduler_ip picked alias ssh_cmd url

  scheduler_ip=$(xp_scheduler_pod_ip)
  if [ -z "$scheduler_ip" ]; then
    return 1
  fi

  picked=$(xp_pick_cluster_node_ssh || true)
  if [ -z "$picked" ]; then
    return 1
  fi
  alias="${picked%%|*}"
  ssh_cmd="${picked#*|}"
  url="http://$scheduler_ip:$XPUSHARE_METRICS_PORT/healthz"

  if eval "$ssh_cmd \"curl -sS -m 10 -o - -w '\\nHTTP_CODE=%{http_code}\\n' '$url'\"" > "$outfile" 2>/dev/null; then
    xp_case_note "metrics health via remote node=$alias url=$url"
    return 0
  fi

  return 1
}

xp_capture_metrics_snapshot() {
  local outfile="$1"
  local pod pf_pid

  if xp_capture_metrics_snapshot_remote "$outfile"; then
    return 0
  fi

  pod=$(xp_scheduler_pod)
  if [ -z "$pod" ]; then
    echo "# scheduler pod not found" > "$outfile"
    return 1
  fi

  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" port-forward "pod/$pod" \
    "$XPUSHARE_METRICS_LOCAL_PORT:$XPUSHARE_METRICS_PORT" > "$XPUSHARE_CASE_LOG_DIR/port-forward.log" 2>&1 &
  pf_pid=$!
  sleep 2

  if ! curl -fsS "http://127.0.0.1:$XPUSHARE_METRICS_LOCAL_PORT/metrics" > "$outfile" 2>/dev/null; then
    echo "# failed to capture metrics from scheduler pod $pod" > "$outfile"
    kill "$pf_pid" >/dev/null 2>&1 || true
    wait "$pf_pid" 2>/dev/null || true
    return 1
  fi

  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
  return 0
}

xp_capture_metrics_snapshot_with_suffix() {
  local suffix="$1"
  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_${suffix}.txt"
}

xp_capture_metrics_repeated() {
  local outfile="$1"
  local duration_sec="$2"
  local interval_sec="$3"
  local end_ts now idx tmpfile

  : > "$outfile"
  end_ts=$(( $(date +%s) + duration_sec ))
  idx=0
  tmpfile="/tmp/xpushare_metrics_${XPUSHARE_RUN_ID}_${XPUSHARE_CASE_ID}.tmp"

  while true; do
    now=$(date +%s)
    if [ "$now" -ge "$end_ts" ]; then
      break
    fi

    idx=$((idx + 1))
    {
      echo "# sample=$idx ts=$(xp_now)"
      xp_capture_metrics_snapshot "$tmpfile" >/dev/null 2>&1 || true
      if [ -f "$tmpfile" ]; then
        cat "$tmpfile"
      fi
      echo
    } >> "$outfile"

    sleep "$interval_sec"
  done

  rm -f "$tmpfile"
}

xp_capture_metrics_health() {
  local outfile="$1"
  local pod pf_pid code body_file

  if xp_capture_metrics_health_remote "$outfile"; then
    return 0
  fi

  pod=$(xp_scheduler_pod)
  if [ -z "$pod" ]; then
    echo "scheduler pod not found" > "$outfile"
    return 1
  fi

  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" port-forward "pod/$pod" \
    "$XPUSHARE_METRICS_LOCAL_PORT:$XPUSHARE_METRICS_PORT" > "$XPUSHARE_CASE_LOG_DIR/port-forward-health.log" 2>&1 &
  pf_pid=$!
  sleep 2

  body_file="${outfile}.body"
  code=$(curl -sS -m 10 -o "$body_file" -w "%{http_code}" \
    "http://127.0.0.1:$XPUSHARE_METRICS_LOCAL_PORT/healthz" 2>/dev/null || echo "000")
  {
    cat "$body_file" 2>/dev/null || true
    echo
    echo "HTTP_CODE=$code"
  } > "$outfile"
  rm -f "$body_file"

  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
}

xp_capture_pod_logs_by_label() {
  local app_label="$1"
  local outdir="$2"
  local pods pod

  mkdir -p "$outdir"
  pods=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  if [ -z "$pods" ]; then
    xp_log_warn "no pods found for label app=$app_label"
    return 0
  fi

  echo "$pods" | while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" logs "$pod" --timestamps > "$outdir/$pod.log" 2>&1 || true
  done
}

xp_wait_for_pod_exists() {
  local pod_name="$1"
  local timeout_sec="$2"
  local start now

  start=$(date +%s)
  while true; do
    if kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod "$pod_name" >/dev/null 2>&1; then
      return 0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      xp_log_warn "timeout waiting pod created: $pod_name"
      return 1
    fi
    sleep 1
  done
}

xp_wait_for_pod_deleted() {
  local pod_name="$1"
  local timeout_sec="$2"
  local start now

  start=$(date +%s)
  while true; do
    if ! kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod "$pod_name" >/dev/null 2>&1; then
      return 0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      xp_log_warn "timeout waiting pod deleted: $pod_name"
      return 1
    fi
    sleep 1
  done
}

xp_wait_for_label_count() {
  local app_label="$1"
  local expected="$2"
  local timeout_sec="$3"
  local start now count

  start=$(date +%s)
  while true; do
    count=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)
    if [ "$count" -ge "$expected" ]; then
      return 0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      xp_log_warn "timeout waiting pod count app=$app_label expected=$expected current=$count"
      return 1
    fi
    sleep 1
  done
}

xp_cleanup_app() {
  local app_label="$1"
  local pods pod

  pods=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  if [ -z "$pods" ]; then
    return 0
  fi

  kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" delete pod -l "app=$app_label" \
    --ignore-not-found=true --wait=false >/dev/null 2>&1 || true

  while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    xp_wait_for_pod_deleted "$pod" 180 || true
  done <<< "$pods"
}

xp_list_all_test_pods() {
  kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
    awk '/^(xpf-|xpc-|xpp-|xpm-|xps-)/ {print $1}'
}

xp_cleanup_all_test_pods() {
  local pods pod delete_timeout
  local -i count failed

  pods=$(xp_list_all_test_pods)
  if [ -z "$pods" ]; then
    xp_log_info "pre-run cleanup: no existing xpushare test pods found"
    return 0
  fi

  delete_timeout="$XP_TEST_POD_DELETE_TIMEOUT_SEC"
  count=$(echo "$pods" | grep -c . || true)
  failed=0
  xp_log_info "pre-run cleanup: deleting $count existing xpushare test pods"

  while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" delete pod "$pod" \
      --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  done <<< "$pods"

  while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    if xp_wait_for_pod_deleted "$pod" "$delete_timeout"; then
      continue
    fi

    xp_log_warn "pre-run cleanup: force deleting pod $pod"
    kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" delete pod "$pod" \
      --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1 || true
    if ! xp_wait_for_pod_deleted "$pod" 60; then
      xp_log_error "pre-run cleanup: failed to delete pod $pod"
      failed=1
    fi
  done <<< "$pods"

  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  return 0
}

xp_wait_for_pod_phase() {
  local pod_name="$1"
  local expected_phase="$2"
  local timeout_sec="$3"
  local start now phase

  start=$(date +%s)
  while true; do
    phase=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$phase" = "$expected_phase" ]; then
      return 0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      xp_log_warn "timeout waiting pod $pod_name phase=$expected_phase (current=$phase)"
      return 1
    fi
    sleep 2
  done
}

xp_wait_for_pod_terminal() {
  local pod_name="$1"
  local timeout_sec="$2"
  local start now phase

  start=$(date +%s)
  while true; do
    phase=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in
      Succeeded|Failed)
        echo "$phase"
        return 0
        ;;
      "")
        ;;
      *)
        ;;
    esac

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      echo "Timeout"
      return 1
    fi
    sleep 3
  done
}

xp_wait_for_label_terminal() {
  local app_label="$1"
  local timeout_sec="$2"
  local start now phases pending

  start=$(date +%s)
  while true; do
    phases=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
    if [ -z "$phases" ]; then
      now=$(date +%s)
      if [ $((now - start)) -ge "$timeout_sec" ]; then
        xp_log_warn "timeout waiting pods to appear for app=$app_label"
        return 1
      fi
      sleep 2
      continue
    fi

    pending=$(echo "$phases" | grep -Ev '^(Succeeded|Failed)$' | grep -c . || true)
    if [ "$pending" -eq 0 ]; then
      return 0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      xp_log_warn "timeout waiting pods terminal for app=$app_label"
      return 1
    fi
    sleep 5
  done
}

xp_pod_phase() {
  local pod_name="$1"
  kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

xp_extract_runtime_seconds() {
  local pod_log_file="$1"
  sed -n 's/^.*--- \([0-9][0-9.]*\) seconds ---.*$/\1/p' "$pod_log_file" | tail -n 1
}

xp_workload_image() {
  local workload="$1"
  case "$workload" in
    w1) echo "$XP_IMAGE_PYTORCH_ADD" ;;
    w2) echo "$XP_IMAGE_PYTORCH_ADD_SMALL" ;;
    w3) echo "$XP_IMAGE_PYTORCH_ADD_IDLE_SMALL" ;;
    w4|w5) echo "$XP_IMAGE_PYTORCH_ADD_SMALL" ;;
    *) echo "$XP_IMAGE_PYTORCH_ADD_SMALL" ;;
  esac
}

xp_workload_command_block() {
  local workload="$1"
  local matrix_n

  case "$workload" in
    w4)
      if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
        matrix_n="$XP_W4_MATRIX_N_C2"
      else
        matrix_n="$XP_W4_MATRIX_N_C1"
      fi
      cat <<CMD
    command:
    - python3
    - -u
    - -c
    - |
      import time
      import torch
      start=time.time()
      n=$matrix_n
      dev=torch.cuda.current_device()
      x=torch.ones([n, n], dtype=torch.float32).to(dev)
      y=torch.ones([n, n], dtype=torch.float32).to(dev)
      z=torch.add(x, y)
      torch.cuda.synchronize()
      print('PASS')
      print('--- %s seconds ---' % (time.time()-start))
CMD
      ;;
    w5)
      cat <<CMD
    command:
    - python3
    - -u
    - -c
    - |
      import time
      import torch
      duration=int($XP_W5_DURATION_SEC)
      n=14000
      dev=torch.cuda.current_device()
      x=torch.ones([n, n], dtype=torch.float32).to(dev)
      y=torch.ones([n, n], dtype=torch.float32).to(dev)
      t0=time.time()
      last=t0
      it=0
      while True:
          z=torch.add(x, y)
          it+=1
          now=time.time()
          if now-last>=10:
              print('[NVSHARE][QUOTA_PROBE] elapsed=%.1fs it=%d it_per_sec=%.2f' % (now-t0, it, it/(now-t0)), flush=True)
              last=now
          if now-t0>=duration:
              break
      torch.cuda.synchronize()
      print('PASS')
      print('--- %s seconds ---' % (time.time()-t0))
CMD
      ;;
    *)
      echo ""
      ;;
  esac
}

xp_apply_workload_pod() {
  local pod_name="$1"
  local app_label="$2"
  local workload="$3"
  local core_limit="$4"
  local memory_limit_annotation="$5"
  local memory_limit_env="$6"
  local oversub="$7"

  local image
  local command_block
  image=$(xp_workload_image "$workload")
  command_block=$(xp_workload_command_block "$workload")

  {
    cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  labels:
    app: $app_label
YAML

    if [ -n "$core_limit" ] || [ -n "$memory_limit_annotation" ]; then
      echo "  annotations:"
      if [ -n "$core_limit" ]; then
        echo "    nvshare.com/gpu-core-limit: \"$core_limit\""
      fi
      if [ -n "$memory_limit_annotation" ]; then
        echo "    nvshare.com/gpu-memory-limit: \"$memory_limit_annotation\""
      fi
    fi

    cat <<YAML
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: $image
YAML

    if [ -n "$command_block" ]; then
      echo "$command_block"
    fi

    cat <<YAML
    env:
    - name: NVSHARE_DEBUG
      value: "1"
YAML

    if [ "$oversub" = "1" ]; then
      cat <<YAML
    - name: NVSHARE_ENABLE_SINGLE_OVERSUB
      value: "1"
YAML
    fi

    if [ -n "$memory_limit_env" ]; then
      cat <<YAML
    - name: NVSHARE_GPU_MEMORY_LIMIT
      value: "$memory_limit_env"
YAML
    fi

    cat <<YAML
    resources:
      limits:
        nvshare.com/gpu: 1
YAML
  } | kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" apply -f -

  xp_wait_for_pod_exists "$pod_name" 60
}

xp_apply_workload_group() {
  local app_label="$1"
  local count="$2"
  local workload="$3"
  local core_limit="$4"
  local memory_limit_annotation="$5"
  local memory_limit_env="$6"
  local oversub="$7"

  local i pod
  for i in $(seq 1 "$count"); do
    pod="$app_label-$i"
    xp_apply_workload_pod "$pod" "$app_label" "$workload" "$core_limit" "$memory_limit_annotation" "$memory_limit_env" "$oversub"
  done

  xp_wait_for_label_count "$app_label" "$count" 90
}

xp_get_pod_gpu_uuid() {
  local pod_name="$1"
  kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" exec "$pod_name" -- sh -c 'printenv NVIDIA_VISIBLE_DEVICES' 2>/dev/null || true
}

xp_compare_two_pods_gpu() {
  local pod_a="$1"
  local pod_b="$2"
  local uuid_a uuid_b

  uuid_a=$(xp_get_pod_gpu_uuid "$pod_a")
  uuid_b=$(xp_get_pod_gpu_uuid "$pod_b")

  echo "pod_a=$pod_a uuid=$uuid_a" > "$XPUSHARE_CASE_LOG_DIR/gpu_mapping.txt"
  echo "pod_b=$pod_b uuid=$uuid_b" >> "$XPUSHARE_CASE_LOG_DIR/gpu_mapping.txt"

  if [ -n "$uuid_a" ] && [ "$uuid_a" = "$uuid_b" ]; then
    return 0
  fi
  return 1
}

xp_update_annotation() {
  local pod_name="$1"
  local key="$2"
  local value="$3"

  if [ -n "$value" ]; then
    kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" annotate pod "$pod_name" "$key=$value" --overwrite
  else
    kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" annotate pod "$pod_name" "$key-"
  fi
}

xp_assert_log_contains() {
  local file="$1"
  local pattern="$2"
  grep -Eq "$pattern" "$file"
}

xp_record_cluster_snapshot() {
  local out="$1"
  {
    echo "# time=$(xp_now)"
    kubectl get nodes -o wide
    echo
    kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" get pods -o wide
    echo
    kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pods -o wide
  } > "$out" 2>&1 || true
}

xp_resolve_ssh_cmd() {
  local cluster="$1"
  local node_alias="$2"

  case "$cluster:$node_alias" in
    c1:node1) echo "$XPUSHARE_C1_NODE1_SSH" ;;
    c1:node2) echo "$XPUSHARE_C1_NODE2_SSH" ;;
    c2:node1) echo "$XPUSHARE_C2_NODE1_SSH" ;;
    c2:node2) echo "$XPUSHARE_C2_NODE2_SSH" ;;
    *) echo "" ;;
  esac
}

xp_gpu_node_exec() {
  local cluster="$1"
  local node_alias="$2"
  local cmd="$3"
  local ssh_cmd

  ssh_cmd=$(xp_resolve_ssh_cmd "$cluster" "$node_alias")
  if [ -z "$ssh_cmd" ]; then
    xp_log_warn "SSH placeholder not set for $cluster/$node_alias, skip remote command"
    return 2
  fi

  eval "$ssh_cmd \"$cmd\""
}

xp_capture_remote_nvidia_smi() {
  local outfile_prefix="$1"
  local node

  for node in node1 node2; do
    if xp_gpu_node_exec "$XPUSHARE_CLUSTER" "$node" "nvidia-smi" > "${outfile_prefix}_${node}_nvidia_smi.txt" 2>&1; then
      xp_log_info "captured nvidia-smi for $XPUSHARE_CLUSTER/$node"
    else
      xp_log_warn "failed to capture nvidia-smi for $XPUSHARE_CLUSTER/$node"
    fi

    if xp_gpu_node_exec "$XPUSHARE_CLUSTER" "$node" "nvidia-smi dmon -s u -d 1 -c 10" > "${outfile_prefix}_${node}_dmon.txt" 2>&1; then
      xp_log_info "captured dmon for $XPUSHARE_CLUSTER/$node"
    else
      xp_log_warn "failed to capture dmon for $XPUSHARE_CLUSTER/$node"
    fi
  done
}

xp_collect_common_artifacts() {
  local app_label="$1"

  xp_record_cluster_snapshot "$XPUSHARE_CASE_LOG_DIR/cluster_snapshot.txt"
  xp_capture_scheduler_logs "$XPUSHARE_CASE_LOG_DIR/scheduler.log"
  xp_capture_device_plugin_logs "$XPUSHARE_CASE_LOG_DIR/device-plugin.log"
  xp_capture_scheduler_proc_stats "$XPUSHARE_CASE_LOG_DIR/scheduler_proc.txt"
  xp_capture_metrics_health "$XPUSHARE_CASE_LOG_DIR/metrics_health.txt"
  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics.txt" || true
  xp_capture_pod_logs_by_label "$app_label" "$XPUSHARE_CASE_LOG_DIR/pods"
  xp_capture_remote_nvidia_smi "$XPUSHARE_CASE_LOG_DIR/remote"
}

xp_check_all_pod_logs_for_pass() {
  local app_label="$1"
  local pods pod

  pods=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [ -z "$pods" ]; then
    return 1
  fi

  while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    if ! kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" logs "$pod" 2>/dev/null | grep -q "PASS"; then
      return 1
    fi
  done <<< "$pods"

  return 0
}

xp_count_running_scheduler() {
  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" get pod -l name=nvshare-scheduler \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c '^Running$' || true
}

xp_metric_exists_in_file() {
  local metric_name="$1"
  local metric_file="$2"
  grep -Eq "^${metric_name}([ {].*)?$" "$metric_file"
}

xp_metric_sum_in_file() {
  local metric_name="$1"
  local metric_file="$2"
  local label_filter="${3:-}"

  if [ -n "$label_filter" ]; then
    awk -v metric="$metric_name" -v label="$label_filter" '
      $0 ~ ("^" metric "([ {].*)?$") && $0 ~ label {sum += $NF}
      END {printf "%.6f\n", sum+0}
    ' "$metric_file"
    return
  fi

  awk -v metric="$metric_name" '
    $0 ~ ("^" metric "([ {].*)?$") {sum += $NF}
    END {printf "%.6f\n", sum+0}
  ' "$metric_file"
}

xp_wait_metric_condition() {
  local timeout_sec="$1"
  local interval_sec="$2"
  local predicate_cmd="$3"
  local start now

  start=$(date +%s)
  while true; do
    if eval "$predicate_cmd"; then
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      return 1
    fi
    sleep "$interval_sec"
  done
}

xp_http_code_from_file() {
  local file="$1"
  sed -n 's/^HTTP_CODE=\([0-9][0-9][0-9]\).*/\1/p' "$file" | tail -n 1
}

xp_safe_sleep() {
  local sec="$1"
  [ "$sec" -gt 0 ] && sleep "$sec"
}
