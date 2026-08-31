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

# --- Instance identity -------------------------------------------------------
# Every Otos process writes to the one system log under the one process name, so
# "which instance?" must have a single answer in this repo. It previously had
# three: two scripts picked `pgrep -x | head -n 1` (the *lowest* PID — the oldest
# instance, the opposite of the one just launched) and a third simply `pkill`ed
# every instance to make the question moot, which is how a review once found a
# live session truncated to a log that still looked complete.

otos_running_pids() {
  pgrep -x "${1:-Otos}" 2>/dev/null || true
}

# Refuse rather than adopt or kill. A run that did not launch the app cannot
# attribute its log lines, cannot say which instance `osascript ... to quit`
# quits, and must never terminate an app the user started.
otos_refuse_if_running() {
  local app_name="${1:-Otos}"
  local existing
  existing="$(otos_running_pids "$app_name")"
  [[ -n "$existing" ]] || return 0
  echo "Cannot start: $app_name is already running (pid $(tr "\n" " " <<<"$existing" | sed "s/ $//"))." >&2
  echo "Quit it first. Its log lines are indistinguishable from this run's, and this run must never terminate an app it did not launch." >&2
  exit 1
}

# The PID absent from the pre-launch snapshot is the one this run produced.
otos_newly_launched_pid() {
  local app_name="${1:-Otos}"
  local before="${2:-}"
  local candidate
  for _ in $(seq 1 50); do
    while read -r candidate; do
      [[ -n "$candidate" ]] || continue
      if ! grep -qx "$candidate" <<<"$before"; then
        echo "$candidate"
        return 0
      fi
    done < <(otos_running_pids "$app_name")
    sleep 0.1
  done
  echo "Timed out waiting for a newly launched $app_name" >&2
  exit 1
}
