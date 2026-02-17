#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CONFIG_FILE=""
TARGET_CLUSTER="all"
TARGET_SUITE="all"
TARGET_CASE=""
RUN_ID_OVERRIDE=""
RESUME_MODE="0"
RESUME_INCLUDE_NEW_CLUSTERS="${XPUSHARE_RESUME_INCLUDE_NEW_CLUSTERS:-0}"

usage() {
  cat <<USAGE
Usage:
  bash tests/xpushare/run-matrix.sh [options]

Options:
  --config <file>         Load env config file (default: none)
  --cluster <c1|c2|all>   Target cluster (default: all)
  --suite <name|all>      Suite: functional|combination|performance|metrics|stability|smoke|all
  --case <CASE_ID>        Run one case directly (e.g. FUNC-003, MET-005)
  --run-id <id>           Override run id for log directory naming
  --resume                Resume unfinished run (skip already PASS cases)
  -h, --help              Show this help

Examples:
  bash tests/xpushare/run-matrix.sh --cluster c1 --suite functional
  bash tests/xpushare/run-matrix.sh --cluster c1 --suite smoke
  bash tests/xpushare/run-matrix.sh --cluster c2 --case MET-002
  bash tests/xpushare/run-matrix.sh --config tests/xpushare/config.env --cluster all --suite all
  bash tests/xpushare/run-matrix.sh --resume --run-id 20260214-220000 --cluster c1 --suite all
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --cluster)
      TARGET_CLUSTER="${2:-}"
      shift 2
      ;;
    --suite)
      TARGET_SUITE="${2:-}"
      shift 2
      ;;
    --case)
      TARGET_CASE="${2:-}"
      shift 2
      ;;
    --run-id)
      RUN_ID_OVERRIDE="${2:-}"
      shift 2
      ;;
    --resume)
      RESUME_MODE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/suites/functional.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/suites/combination.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/suites/performance.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/suites/metrics.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/suites/stability.sh"

xp_matrix_resolve_log_root_by_run_id() {
  local run_id="$1"

  if [ -d "$PROJECT_ROOT/.tmplog/xpushare-$run_id" ]; then
    echo "$PROJECT_ROOT/.tmplog/xpushare-$run_id"
    return
  fi

  echo "$PROJECT_ROOT/.tmplog/$run_id/xpushare"
}

xp_matrix_latest_run_id_from_summary() {
  local latest_summary
  latest_summary=$(ls -1dt "$PROJECT_ROOT/.tmplog"/*/xpushare/run-summary.tsv "$PROJECT_ROOT/.tmplog"/xpushare-*/run-summary.tsv 2>/dev/null | head -n 1 || true)
  if [ -z "$latest_summary" ]; then
    echo ""
    return
  fi

  if [[ "$latest_summary" == */xpushare-*/run-summary.tsv ]]; then
    basename "$(dirname "$latest_summary")" | sed 's/^xpushare-//'
    return
  fi

  basename "$(dirname "$(dirname "$latest_summary")")"
}

xp_matrix_latest_run_id() {
  local by_summary by_dir
  by_summary=$(xp_matrix_latest_run_id_from_summary)
  if [ -n "$by_summary" ]; then
    echo "$by_summary"
    return
  fi

  by_dir=$(
    {
      ls -1dt "$PROJECT_ROOT/.tmplog"/*/xpushare 2>/dev/null || true
      ls -1dt "$PROJECT_ROOT/.tmplog"/xpushare-* 2>/dev/null || true
    } | head -n 1
  )
  if [ -z "$by_dir" ]; then
    echo ""
    return
  fi

  if [[ "$by_dir" == */xpushare-* ]]; then
    basename "$by_dir" | sed 's/^xpushare-//'
    return
  fi
  echo "$(basename "$(dirname "$by_dir")")"
}

if [ "$RESUME_MODE" = "1" ] && [ -z "$RUN_ID_OVERRIDE" ]; then
  RUN_ID_OVERRIDE=$(xp_matrix_latest_run_id)
  if [ -n "$RUN_ID_OVERRIDE" ]; then
    echo "[XPUSHARE][INFO] resume mode: use latest run-id $RUN_ID_OVERRIDE"
  else
    echo "[XPUSHARE][WARN] resume mode requested but no previous run found, creating new run-id"
  fi
fi

if [ -n "$RUN_ID_OVERRIDE" ]; then
  XPUSHARE_RUN_ID="$RUN_ID_OVERRIDE"
fi
XPUSHARE_LOG_ROOT=$(xp_matrix_resolve_log_root_by_run_id "$XPUSHARE_RUN_ID")
XPUSHARE_RESUME_MODE="$RESUME_MODE"

xp_require_tools
xp_load_config_file "$CONFIG_FILE"

xp_matrix_case_suite() {
  local case_id="$1"
  case "$case_id" in
    FUNC-*) echo "functional" ;;
    COMBO-*) echo "combination" ;;
    PERF-*) echo "performance" ;;
    MET-*) echo "metrics" ;;
    STAB-*|LEAK-*|FAIL-*) echo "stability" ;;
    *) echo "" ;;
  esac
}

xp_matrix_run_case() {
  local case_id="$1"
  local suite

  suite=$(xp_matrix_case_suite "$case_id")
  if [ -z "$suite" ]; then
    xp_log_error "cannot infer suite from case id: $case_id"
    return 1
  fi

  case "$suite" in
    functional) xp_run_functional_case "$case_id" ;;
    combination) xp_run_combination_case "$case_id" ;;
    performance) xp_run_performance_case "$case_id" ;;
    metrics) xp_run_metrics_case "$case_id" ;;
    stability) xp_run_stability_case "$case_id" ;;
    *)
      xp_log_error "unknown suite for case $case_id: $suite"
      return 1
      ;;
  esac
}

xp_run_smoke_suite() {
  local smoke_cases case_id case_suite fail_count

  smoke_cases="${XP_SMOKE_CASES:-FUNC-001 FUNC-007 COMBO-003 MET-001}"
  fail_count=0

  for case_id in $smoke_cases; do
    case_suite=$(xp_matrix_case_suite "$case_id")
    if [ -z "$case_suite" ]; then
      xp_log_error "invalid smoke case id: $case_id"
      fail_count=$((fail_count + 1))
      continue
    fi

    if xp_case_should_skip "$case_suite" "$case_id"; then
      continue
    fi

    if ! xp_matrix_run_case "$case_id"; then
      fail_count=$((fail_count + 1))
    fi
  done

  [ "$fail_count" -eq 0 ]
}

xp_matrix_run_suite() {
  local suite="$1"
  local filter="${2:-all}"

  case "$suite" in
    functional) xp_run_functional_suite "$filter" ;;
    combination) xp_run_combination_suite "$filter" ;;
    performance) xp_run_performance_suite "$filter" ;;
    metrics) xp_run_metrics_suite "$filter" ;;
    stability) xp_run_stability_suite "$filter" ;;
    smoke) xp_run_smoke_suite ;;
    *)
      xp_log_error "unknown suite: $suite"
      return 1
      ;;
  esac
}

xp_matrix_target_suites() {
  local suite="$1"

  case "$suite" in
    functional|combination|performance|metrics|stability|smoke)
      echo "$suite"
      ;;
    all)
      echo "functional combination performance metrics stability"
      ;;
    *)
      echo ""
      ;;
  esac
}

xp_matrix_target_clusters() {
  local cluster="$1"

  case "$cluster" in
    c1|cluster1) echo "c1" ;;
    c2|cluster2) echo "c2" ;;
    all) echo "c1 c2" ;;
    *) echo "" ;;
  esac
}

xp_matrix_resume_cluster_has_history() {
  local cluster_name="$1"
  local case_summary="$2"

  if [ ! -f "$case_summary" ]; then
    return 1
  fi

  awk -F'\t' -v c="$cluster_name" 'NR>1 && $1==c {found=1; exit} END{exit !found}' "$case_summary"
}

CASE_SUITE=""
if [ -n "$TARGET_CASE" ]; then
  CASE_SUITE=$(xp_matrix_case_suite "$TARGET_CASE")
  if [ -z "$CASE_SUITE" ]; then
    xp_log_error "cannot infer suite from case id: $TARGET_CASE"
    exit 1
  fi
fi

SUITES="$(xp_matrix_target_suites "$TARGET_SUITE")"
if [ -z "$SUITES" ]; then
  xp_log_error "invalid suite: $TARGET_SUITE"
  exit 1
fi

CLUSTERS="$(xp_matrix_target_clusters "$TARGET_CLUSTER")"
if [ -z "$CLUSTERS" ]; then
  xp_log_error "invalid cluster: $TARGET_CLUSTER"
  exit 1
fi

if [ -n "$TARGET_CASE" ]; then
  SUITES="$CASE_SUITE"
fi

mkdir -p "$XPUSHARE_LOG_ROOT"
RUN_SUMMARY_FILE="$XPUSHARE_LOG_ROOT/run-summary.tsv"
RUN_CASE_SUMMARY_FILE="$XPUSHARE_LOG_ROOT/case-summary.tsv"

if [ ! -f "$RUN_SUMMARY_FILE" ] || [ "$RESUME_MODE" != "1" ]; then
  echo -e "cluster\tsuite\tselector\tstatus" > "$RUN_SUMMARY_FILE"
fi
if [ ! -f "$RUN_CASE_SUMMARY_FILE" ] || [ "$RESUME_MODE" != "1" ]; then
  echo -e "cluster\tsuite\tcase_id\tstatus\tsummary\tcase_log_dir" > "$RUN_CASE_SUMMARY_FILE"
fi
XPUSHARE_RUN_CASE_SUMMARY_FILE="$RUN_CASE_SUMMARY_FILE"

xp_log_info "run_id=$XPUSHARE_RUN_ID"
xp_log_info "log_root=$XPUSHARE_LOG_ROOT"
xp_log_info "resume_mode=$RESUME_MODE"
xp_log_info "resume_include_new_clusters=$RESUME_INCLUDE_NEW_CLUSTERS"
xp_log_info "clusters=$CLUSTERS suites=$SUITES case=${TARGET_CASE:-all}"

fail_count=0

for cluster in $CLUSTERS; do
  xp_select_cluster "$cluster"
  xp_init_run_dirs

  if [ "$RESUME_MODE" = "1" ] && [ "$RESUME_INCLUDE_NEW_CLUSTERS" != "1" ]; then
    if ! xp_matrix_resume_cluster_has_history "$XPUSHARE_CLUSTER_NAME" "$RUN_CASE_SUMMARY_FILE"; then
      xp_log_info "resume mode: skip cluster $XPUSHARE_CLUSTER_NAME (no historical cases in run-id $XPUSHARE_RUN_ID)"
      echo -e "${XPUSHARE_CLUSTER_NAME}\tresume\tno-history\tSKIP" >> "$RUN_SUMMARY_FILE"
      continue
    fi
  fi

  if ! xp_assert_scheduler_ready; then
    xp_log_error "scheduler is not ready on $XPUSHARE_CLUSTER_NAME"
    echo -e "${XPUSHARE_CLUSTER_NAME}\tprecheck\tready\tFAIL" >> "$RUN_SUMMARY_FILE"
    fail_count=$((fail_count + 1))
    continue
  fi

  if ! xp_cleanup_all_test_pods; then
    xp_log_error "pre-run stale pod cleanup failed on $XPUSHARE_CLUSTER_NAME"
    echo -e "${XPUSHARE_CLUSTER_NAME}\tprecheck\tcleanup\tFAIL" >> "$RUN_SUMMARY_FILE"
    fail_count=$((fail_count + 1))
    continue
  fi

  if [ -n "$TARGET_CASE" ]; then
    selector="$TARGET_CASE"
    if xp_matrix_run_suite "$CASE_SUITE" "$TARGET_CASE"; then
      echo -e "${XPUSHARE_CLUSTER_NAME}\t${CASE_SUITE}\t${selector}\tPASS" >> "$RUN_SUMMARY_FILE"
    else
      echo -e "${XPUSHARE_CLUSTER_NAME}\t${CASE_SUITE}\t${selector}\tFAIL" >> "$RUN_SUMMARY_FILE"
      fail_count=$((fail_count + 1))
    fi
    continue
  fi

  for suite in $SUITES; do
    if [ "$suite" = "stability" ] && [ "${XP_SKIP_STABILITY:-0}" = "1" ]; then
      xp_log_warn "skip stability suite because XP_SKIP_STABILITY=1"
      echo -e "${XPUSHARE_CLUSTER_NAME}\t${suite}\tall\tSKIP" >> "$RUN_SUMMARY_FILE"
      continue
    fi

    selector="all"
    if xp_matrix_run_suite "$suite" "$selector"; then
      echo -e "${XPUSHARE_CLUSTER_NAME}\t${suite}\t${selector}\tPASS" >> "$RUN_SUMMARY_FILE"
    else
      echo -e "${XPUSHARE_CLUSTER_NAME}\t${suite}\t${selector}\tFAIL" >> "$RUN_SUMMARY_FILE"
      fail_count=$((fail_count + 1))
    fi
  done
done

xp_log_info "run summary saved: $RUN_SUMMARY_FILE"
if [ "$fail_count" -gt 0 ]; then
  xp_log_error "test matrix completed with failures: $fail_count"
  exit 1
fi

xp_log_info "test matrix completed successfully"
exit 0
