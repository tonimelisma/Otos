#!/usr/bin/env bash
set -euo pipefail

otos_session_id() {
  local pid="${1:-$$}"
  date -u +"%Y%m%dT%H%M%SZ-p${pid}"
}

otos_logs_dir() {
  local root_dir="$1"
  echo "$root_dir/logs"
}

otos_log_file() {
  local root_dir="$1"
  local prefix="$2"
  local run_kind="$3"
  local pid="${4:-$$}"
  local log_dir
  log_dir="$(otos_logs_dir "$root_dir")"
  mkdir -p "$log_dir"
  echo "$log_dir/${prefix}-$(otos_session_id "$pid")-${run_kind}.log"
}
