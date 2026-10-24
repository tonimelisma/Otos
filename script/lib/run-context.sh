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

# The PID absent from the pre-launch snapshot is the one this run produced. Callers
# look only after the launch has been reported — `open` returns once the process
# exists, and `build_and_run.sh --verify` returns once the app has logged its session
# start — so one look answers it.
otos_newly_launched_pid() {
  local app_name="${1:-Otos}"
  local before="${2:-}"
  local candidate
  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if ! grep -qx "$candidate" <<<"$before"; then
      echo "$candidate"
      return 0
    fi
  done < <(otos_running_pids "$app_name")
  echo "No newly launched $app_name: the launch was reported but no new process exists" >&2
  exit 1
}

# A live `log stream` on file descriptor 3. `otos_log_stream_open` returns once the
# stream has printed its header, so a line logged after it returns is not missed;
# `otos_log_stream_await` reads lines until one matches.
otos_log_stream_open() {
  local predicate="$1"
  local fifo
  fifo="$(mktemp -u)"
  mkfifo "$fifo"
  /usr/bin/log stream --style compact --level info --predicate "$predicate" > "$fifo" 2>&1 &
  OTOS_LOG_STREAM_PID="$!"
  exec 3<"$fifo"
  rm -f "$fifo"
  local header
  IFS= read -r header <&3
}

# Prints the first line matching the extended regex and returns 0; returns 1 if the
# stream goes quiet for the given number of seconds first.
otos_log_stream_await() {
  local pattern="$1" quiet_seconds="$2" line
  # time: deadline — the app may never log the line (it crashed, or never reached it)
  while IFS= read -r -t "$quiet_seconds" line <&3; do
    if [[ "$line" =~ $pattern ]]; then
      echo "$line"
      return 0
    fi
  done
  return 1
}

otos_log_stream_close() {
  if [[ -n "${OTOS_LOG_STREAM_PID:-}" ]]; then
    kill "$OTOS_LOG_STREAM_PID" >/dev/null 2>&1 || true
    wait "$OTOS_LOG_STREAM_PID" >/dev/null 2>&1 || true
    OTOS_LOG_STREAM_PID=""
  fi
  exec 3<&- 2>/dev/null || true
}
