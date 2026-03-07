#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

RUN_ID=""
LOG_ROOT=""
OUTPUT_FILE=""

usage() {
  cat <<USAGE
Usage:
  bash tests/xpushare/generate-report.sh [options]

Options:
  --run-id <id>       Run id (e.g. 20260306-120000)
  --log-root <dir>    Explicit log root (e.g. .tmplog/<id>/xpushare)
  --output <file>     Output markdown path (default: <log-root>/run-report.md)
  -h, --help          Show help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    --log-root)
      LOG_ROOT="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="${2:-}"
      shift 2
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

latest_run_id() {
  local latest_summary
  latest_summary=$(ls -1dt "$PROJECT_ROOT/.tmplog"/*/xpushare/run-summary.tsv "$PROJECT_ROOT/.tmplog"/xpushare-*/run-summary.tsv 2>/dev/null | head -n 1 || true)
  if [ -z "$latest_summary" ]; then
    echo ""
    return 0
  fi

  if [[ "$latest_summary" == */xpushare-*/run-summary.tsv ]]; then
    basename "$(dirname "$latest_summary")" | sed 's/^xpushare-//'
    return 0
  fi

  basename "$(dirname "$(dirname "$latest_summary")")"
}

resolve_log_root_by_run_id() {
  local run_id="$1"
  if [ -d "$PROJECT_ROOT/.tmplog/$run_id/xpushare" ]; then
    echo "$PROJECT_ROOT/.tmplog/$run_id/xpushare"
    return 0
  fi
  if [ -d "$PROJECT_ROOT/.tmplog/xpushare-$run_id" ]; then
    echo "$PROJECT_ROOT/.tmplog/xpushare-$run_id"
    return 0
  fi
  return 1
}

kv_from_file() {
  local file="$1"
  local key="$2"
  if [ ! -f "$file" ]; then
    echo ""
    return 0
  fi
  awk -F= -v k="$key" '$1==k{v=substr($0, index($0,"=")+1)} END{print v}' "$file"
}

md_escape() {
  local s="${1:-}"
  printf '%s' "$s" | sed 's/|/\\|/g'
}

case_status() {
  local cluster="$1"
  local suite="$2"
  local case_id="$3"
  awk -F'\t' -v c="$cluster" -v s="$suite" -v id="$case_id" 'NR>1 && $1==c && $2==s && $3==id{print $4; exit}' "$CASE_SUMMARY_FILE"
}

if [ -z "$LOG_ROOT" ]; then
  if [ -z "$RUN_ID" ]; then
    RUN_ID=$(latest_run_id)
  fi
  if [ -z "$RUN_ID" ]; then
    echo "No run-id found and --log-root not provided" >&2
    exit 1
  fi
  LOG_ROOT=$(resolve_log_root_by_run_id "$RUN_ID" || true)
  if [ -z "$LOG_ROOT" ]; then
    echo "Cannot resolve log root for run-id: $RUN_ID" >&2
    exit 1
  fi
fi

if [ -z "$RUN_ID" ]; then
  if [[ "$LOG_ROOT" == */.tmplog/*/xpushare ]]; then
    RUN_ID=$(basename "$(dirname "$LOG_ROOT")")
  elif [[ "$LOG_ROOT" == */.tmplog/xpushare-* ]]; then
    RUN_ID=$(basename "$LOG_ROOT" | sed 's/^xpushare-//')
  else
    RUN_ID="unknown"
  fi
fi

RUN_SUMMARY_FILE="$LOG_ROOT/run-summary.tsv"
CASE_SUMMARY_FILE="$LOG_ROOT/case-summary.tsv"
if [ ! -f "$RUN_SUMMARY_FILE" ] || [ ! -f "$CASE_SUMMARY_FILE" ]; then
  echo "Missing summary files under log root: $LOG_ROOT" >&2
  exit 1
fi

if [ -z "$OUTPUT_FILE" ]; then
  OUTPUT_FILE="$LOG_ROOT/run-report.md"
fi
mkdir -p "$(dirname "$OUTPUT_FILE")"

TOTAL_CASES=$(awk -F'\t' 'NR>1{c++} END{print c+0}' "$CASE_SUMMARY_FILE")
PASS_CASES=$(awk -F'\t' 'NR>1 && $4=="PASS"{c++} END{print c+0}' "$CASE_SUMMARY_FILE")
FAIL_CASES=$(awk -F'\t' 'NR>1 && $4=="FAIL"{c++} END{print c+0}' "$CASE_SUMMARY_FILE")
SKIP_CASES=$(awk -F'\t' 'NR>1 && $4=="SKIP"{c++} END{print c+0}' "$CASE_SUMMARY_FILE")

TOTAL_SUITES=$(awk -F'\t' 'NR>1{c++} END{print c+0}' "$RUN_SUMMARY_FILE")
PASS_SUITES=$(awk -F'\t' 'NR>1 && $4=="PASS"{c++} END{print c+0}' "$RUN_SUMMARY_FILE")
FAIL_SUITES=$(awk -F'\t' 'NR>1 && $4=="FAIL"{c++} END{print c+0}' "$RUN_SUMMARY_FILE")
SKIP_SUITES=$(awk -F'\t' 'NR>1 && $4=="SKIP"{c++} END{print c+0}' "$RUN_SUMMARY_FILE")

REQUIRED_SUITES="functional combination performance metrics stability"

{
  echo "# XPUSHARE 回归测试报告"
  echo
  echo "## 1. 执行概览"
  echo
  echo "- run_id: \`$RUN_ID\`"
  echo "- log_root: \`$LOG_ROOT\`"
  echo "- generated_at: \`$(date '+%Y-%m-%d %H:%M:%S')\`"
  echo "- suite_result: total=$TOTAL_SUITES pass=$PASS_SUITES fail=$FAIL_SUITES skip=$SKIP_SUITES"
  echo "- case_result: total=$TOTAL_CASES pass=$PASS_CASES fail=$FAIL_CASES skip=$SKIP_CASES"
  echo
  echo "## 2. Suite 结果"
  echo
  echo "| Cluster | Suite | Selector | Status |"
  echo "|---|---|---|---|"
  awk -F'\t' 'NR>1{printf "| %s | %s | %s | %s |\n",$1,$2,$3,$4}' "$RUN_SUMMARY_FILE"
  echo
  echo "## 3. Case 统计"
  echo
  echo "| Cluster | Suite | PASS | FAIL | SKIP | TOTAL | PASS Rate |"
  echo "|---|---|---:|---:|---:|---:|---:|"
  awk -F'\t' '
    NR>1{
      k=$1 FS $2;
      total[k]++;
      if($4=="PASS") pass[k]++;
      else if($4=="FAIL") fail[k]++;
      else if($4=="SKIP") skip[k]++;
    }
    END{
      for(k in total){
        split(k,a,FS);
        p=pass[k]+0; f=fail[k]+0; s=skip[k]+0; t=total[k]+0;
        r=(t>0)?(100.0*p/t):0.0;
        printf "| %s | %s | %d | %d | %d | %d | %.2f%% |\n",a[1],a[2],p,f,s,t,r;
      }
    }
  ' "$CASE_SUMMARY_FILE" | sort
  echo
  echo "## 4. FAIL/SKIP 用例明细"
  echo
  echo "| Cluster | Suite | Case | Status | Summary | Case Log Dir |"
  echo "|---|---|---|---|---|---|"
  awk -F'\t' 'NR>1 && ($4=="FAIL" || $4=="SKIP"){printf "| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6}' "$CASE_SUMMARY_FILE"
  echo
  echo "## 5. 覆盖性检查（发布前）"
  echo
  echo "要求每个集群至少覆盖：functional/combination/performance/metrics/stability。"
  echo
  echo "| Cluster | Required Suite | Covered | Status |"
  echo "|---|---|---|---|"

  GAP_COUNT=0
  for cluster in $(awk -F'\t' 'NR>1{print $1}' "$CASE_SUMMARY_FILE" | sort -u); do
    for suite in $REQUIRED_SUITES; do
      covered=$(awk -F'\t' -v c="$cluster" -v s="$suite" 'NR>1 && $1==c && $2==s{n++} END{print n+0}' "$CASE_SUMMARY_FILE")
      if [ "$covered" -gt 0 ]; then
        echo "| $cluster | $suite | $covered | PASS |"
      else
        echo "| $cluster | $suite | 0 | FAIL |"
        GAP_COUNT=$((GAP_COUNT + 1))
      fi
    done
  done
  echo
  echo "## 6. 关键性能结果摘录"
  echo
  echo "| Cluster | PERF-001 baseline(s) | PERF-011 q25/q50/q75 vs base | PERF-002 overhead(%) | PERF-003 placement/quota | PERF-004 placement/quota | PERF-004 q30/q60 vs base | PERF-007 latency(s) | PERF-008 status | PERF-009 status | PERF-010 status |"
  echo "|---|---:|---|---:|---|---|---|---:|---|---|---|"

  for cluster in $(awk -F'\t' 'NR>1{print $1}' "$CASE_SUMMARY_FILE" | sort -u); do
    perf_root="$LOG_ROOT/$cluster/performance"
    perf001_file="$perf_root/PERF-001/metrics.env"
    perf011_file="$perf_root/PERF-011/metrics.env"
    perf002_file="$perf_root/PERF-002/metrics.env"
    perf003_file="$perf_root/PERF-003/metrics.env"
    perf004_file="$perf_root/PERF-004/metrics.env"
    perf007_file="$perf_root/PERF-007/metrics.env"

    baseline=$(kv_from_file "$perf001_file" "baseline_runtime_sec")
    p11r25=$(kv_from_file "$perf011_file" "single_quota_ratio25_vs_base")
    p11r50=$(kv_from_file "$perf011_file" "single_quota_ratio50_vs_base")
    p11r75=$(kv_from_file "$perf011_file" "single_quota_ratio75_vs_base")
    overhead=$(kv_from_file "$perf002_file" "metrics_overhead_pct")
    p3p=$(kv_from_file "$perf003_file" "perf003_placement_status")
    p3q=$(kv_from_file "$perf003_file" "perf003_quota_effect_status")
    p4p=$(kv_from_file "$perf004_file" "perf004_placement_status")
    p4q=$(kv_from_file "$perf004_file" "perf004_quota_effect_status")
    p4r30=$(kv_from_file "$perf004_file" "mixed_ratio30_vs_base")
    p4r60=$(kv_from_file "$perf004_file" "mixed_ratio60_vs_base")
    p7lat=$(kv_from_file "$perf007_file" "dynamic_compute_metric_latency_sec")

    [ -z "$baseline" ] && baseline="NA"
    [ -z "$p11r25" ] && p11r25="NA"
    [ -z "$p11r50" ] && p11r50="NA"
    [ -z "$p11r75" ] && p11r75="NA"
    [ -z "$overhead" ] && overhead="NA"
    [ -z "$p3p" ] && p3p="NA"
    [ -z "$p3q" ] && p3q="NA"
    [ -z "$p4p" ] && p4p="NA"
    [ -z "$p4q" ] && p4q="NA"
    [ -z "$p4r30" ] && p4r30="NA"
    [ -z "$p4r60" ] && p4r60="NA"
    [ -z "$p7lat" ] && p7lat="NA"

    p8s=$(case_status "$cluster" "performance" "PERF-008")
    p9s=$(case_status "$cluster" "performance" "PERF-009")
    p10s=$(case_status "$cluster" "performance" "PERF-010")
    [ -z "$p8s" ] && p8s="NA"
    [ -z "$p9s" ] && p9s="NA"
    [ -z "$p10s" ] && p10s="NA"

    echo "| $cluster | $baseline | $p11r25/$p11r50/$p11r75 | $overhead | $p3p/$p3q | $p4p/$p4q | $p4r30/$p4r60 | $p7lat | $p8s | $p9s | $p10s |"
  done
  echo
  echo "## 7. 发布建议结论"
  echo

  READY="YES"
  REASON="all required suites covered and no FAIL case"
  if [ "$FAIL_CASES" -gt 0 ]; then
    READY="NO"
    REASON="case failures detected"
  elif [ "$GAP_COUNT" -gt 0 ]; then
    READY="NO"
    REASON="required suite coverage gaps detected"
  fi

  echo "- release_ready: **$READY**"
  echo "- reason: $REASON"
} > "$OUTPUT_FILE"

echo "$OUTPUT_FILE"
