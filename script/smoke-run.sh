#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"
LOG_DIR="$(otos_logs_dir "$ROOT_DIR")"
CATALOG_DB="$HOME/Library/Application Support/$SUBSYSTEM/Catalog/catalog.sqlite"

MODE="${1:---jank}"
if [[ "$MODE" == "--help" || "$MODE" == "help" ]]; then
  cat >&2 <<'USAGE'
usage: script/smoke-run.sh [--jank|--verify] <library-root>

The root must already be registered in the catalog. A smoke run selects an
existing root; it never adds, removes, or otherwise changes what libraries
exist (plan 0066 Stage 6). There is no default: a machine's registered roots
are never guessable, so pass the root explicitly, every time.

Environment:
  OTOS_SMOKE_SELECT_ROOT       an already-registered root, if not an argument
  OTOS_SMOKE_SETTLE_SECONDS    seconds to wait before jank scrolling (default: 10)
  OTOS_SMOKE_SCROLL_CYCLES     down/up scroll cycles (default: 6)
  OTOS_SMOKE_SCROLL_DELTA      pixel delta per scroll event (default: 900)
  OTOS_SMOKE_SCROLL_PAUSE      seconds between scroll events (default: 0.25)
USAGE
  exit 0
fi
ROOT_ARG=""
case "$MODE" in
  --jank|jank|--verify|verify)
    ROOT_ARG="${2:-}"
    ;;
  *)
    ROOT_ARG="$MODE"
    MODE="--jank"
    ;;
esac

SMOKE_ROOT="${ROOT_ARG:-${OTOS_SMOKE_SELECT_ROOT:-}}"
SETTLE_SECONDS="${OTOS_SMOKE_SETTLE_SECONDS:-10}"
SCROLL_CYCLES="${OTOS_SMOKE_SCROLL_CYCLES:-6}"
SCROLL_DELTA="${OTOS_SMOKE_SCROLL_DELTA:-900}"
SCROLL_PAUSE="${OTOS_SMOKE_SCROLL_PAUSE:-0.25}"
LOG_PID=""
LOG_FILE=""
QUIT_ON_EXIT=0
# The PID this run's own launch produced — the only PID `quit_app`'s fallback
# may kill. A second overlapping run's Otos process must never be affected by
# this run's cleanup (plan 0065 Stage 5).
APP_PID=""

usage() {
  cat >&2 <<'USAGE'
usage: script/smoke-run.sh [--jank|--verify] <library-root>

The root must already be registered in the catalog. A smoke run selects an
existing root; it never adds, removes, or otherwise changes what libraries
exist (plan 0066 Stage 6). There is no default: a machine's registered roots
are never guessable, so pass the root explicitly, every time.

Environment:
  OTOS_SMOKE_SELECT_ROOT       an already-registered root, if not an argument
  OTOS_SMOKE_SETTLE_SECONDS    seconds to wait before jank scrolling (default: 10)
  OTOS_SMOKE_SCROLL_CYCLES     down/up scroll cycles (default: 6)
  OTOS_SMOKE_SCROLL_DELTA      pixel delta per scroll event (default: 900)
  OTOS_SMOKE_SCROLL_PAUSE      seconds between scroll events (default: 0.25)
USAGE
}

registered_roots_message() {
  if [[ -f "$CATALOG_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local roots
    roots="$(sqlite3 -readonly "$CATALOG_DB" "SELECT path FROM library_root ORDER BY path;" 2>/dev/null || true)"
    if [[ -n "$roots" ]]; then
      printf 'Already-registered roots (pick one, or a path outside all of them):\n%s\n' "$roots"
      return
    fi
  fi
  echo "No registered roots found (catalog not yet created, or empty)."
}

quit_app() {
  /usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if [[ -z "$APP_PID" ]] || ! kill -0 "$APP_PID" >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done
  # Fallback: kill only the PID this run launched. Never `pkill -x "$APP_NAME"`
  # — that matches any process with this name, including a second overlapping
  # run's still-capturing app instance (observed during plan 0065's review; it
  # silently truncated a session to a log that looked complete).
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
}

# Plan 0066 Stage 6b: check if an import is currently executing by reading the
# app's own liveness signal. The coordinator logs op=import.activity
# phase=started|finished per source; we consider an import active if a
# started line exists without a later finished for the same rootPath.
is_import_active() {
  local predicate="subsystem == \"$SUBSYSTEM\" AND eventMessage CONTAINS \"op=import.activity\""
  local logs
  logs="$(/usr/bin/log show --last 5m --style ndjson --info --predicate "$predicate" 2>/dev/null || true)"
  if [[ -z "$logs" ]]; then
    return 1
  fi
  # Collect started and finished rootPaths, then see if any started is not finished
  # Simple: if there is a started without a subsequent finished for that root, active.
  # For the script's purpose, any started in last 5m without a finished after it counts.
  local started_roots finished_roots
  started_roots="$(echo "$logs" | grep 'phase=started' | sed -n 's/.*rootPath=\([^ ]*\).*/\1/p' | sort -u || true)"
  finished_roots="$(echo "$logs" | grep 'phase=finished' | sed -n 's/.*rootPath=\([^ ]*\).*/\1/p' | sort -u || true)"
  if [[ -z "$started_roots" ]]; then
    return 1
  fi
  # If any started root not in finished, or started timestamp after last finished, active.
  # Simpler: compare counts — if started lines exist and the last activity line is started, active.
  local last_phase
  last_phase="$(echo "$logs" | grep -E 'phase=(started|finished)' | tail -n 1 | sed -n 's/.*phase=\([^ ]*\).*/\1/p' || true)"
  if [[ "$last_phase" == "started" ]]; then
    # Report the rootPath of that last started
    local last_root
    last_root="$(echo "$logs" | grep 'phase=started' | tail -n 1 | sed -n 's/.*rootPath=\([^ ]*\).*/\1/p' || true)"
    if [[ -n "$last_root" ]]; then
      echo "$last_root"
    else
      echo "unknown"
    fi
    return 0
  fi
  return 1
}

cleanup() {
  if [[ -n "$LOG_PID" ]]; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$QUIT_ON_EXIT" == 1 ]]; then
    local active_root
    if active_root="$(is_import_active)"; then
      echo "Smoke run leaving app running: import still active for root=$active_root" >&2
      echo "An import was in flight; not quitting the app to avoid mid-copy termination (plan 0066 Stage 6b)." >&2
      return
    fi
    quit_app
  fi
}
trap cleanup EXIT

wait_for_app_pid() {
  local app_pid=""
  for _ in $(seq 1 50); do
    app_pid="$(pgrep -x "$APP_NAME" | head -n 1 || true)"
    if [[ -n "$app_pid" ]]; then
      echo "$app_pid"
      return
    fi
    sleep 0.1
  done
  echo "Timed out waiting for $APP_NAME to launch" >&2
  exit 1
}

start_log_capture() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="$(otos_log_file "$ROOT_DIR" run prod)"
  /usr/bin/log stream \
    --style compact \
    --level info \
    --signpost \
    --predicate "process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\"" \
    > "$LOG_FILE" 2>&1 &
  LOG_PID="$!"
  echo "$LOG_FILE"
}

run_selected_launch() {
  export OTOS_SMOKE_SELECT_ROOT="$SMOKE_ROOT"
  "$ROOT_DIR/script/build_and_run.sh" --verify >&2
  APP_PID="$(wait_for_app_pid)"
  echo "$APP_PID"
}


# A smoke run proves it scoped the window to the requested root, not that it
# registered one — registering is exactly what Stage 6 removed. `outcome=selected`
# is logged only after the root appeared among the Store's own published roots.
verify_selection_applied() {
  local app_pid="$1"
  local predicate="processID == $app_pid AND subsystem == \"$SUBSYSTEM\" AND eventMessage CONTAINS \"op=smoke.select\""
  for _ in $(seq 1 50); do
    if /usr/bin/log show --last 2m --style ndjson --info --predicate "$predicate" 2>/dev/null \
      | grep -E 'op=smoke\.select.*phase=finish.*outcome=selected' >/dev/null; then
      echo "Smoke selection verified via unified log pid=$app_pid"
      return
    fi
    if /usr/bin/log show --last 2m --style ndjson --info --predicate "$predicate" 2>/dev/null \
      | grep -E 'op=smoke\.select.*outcome=notRegistered' >/dev/null; then
      echo "Root is not registered in the catalog: $SMOKE_ROOT" >&2
      echo "A smoke run never adds a root — pass one that already exists." >&2
      echo >&2
      registered_roots_message >&2
      exit 1
    fi
    sleep 0.1
  done

  echo "Smoke launch did not log op=smoke.select phase=finish for root=$SMOKE_ROOT pid=$app_pid" >&2
  /usr/bin/log show --last 2m --style ndjson --info --predicate "processID == $app_pid AND subsystem == \"$SUBSYSTEM\"" 2>/dev/null | tail -n 40 >&2 || true
  exit 1
}


run_verify() {
  QUIT_ON_EXIT=1
  local app_pid
  app_pid="$(run_selected_launch)"
  sleep "${OTOS_SMOKE_VERIFY_SECONDS:-3}"
  verify_selection_applied "$app_pid"
  echo "Smoke launch succeeded, window scoped to root=$SMOKE_ROOT"
}

run_jank() {
  # Plan 0066 Stage 6b: refuse to start when an import is already active
  local active_root
  if active_root="$(is_import_active)"; then
    echo "Cannot start smoke run: import already active for root=$active_root" >&2
    echo "Finish or cancel the import before running --jank (plan 0066 Stage 6b)." >&2
    exit 1
  fi
  QUIT_ON_EXIT=1
  start_log_capture
  echo "Capturing smoke logs to $LOG_FILE"

  local app_pid
  app_pid="$(run_selected_launch)"
  echo "App launched pid=$app_pid selecting root=$SMOKE_ROOT"
  echo "Waiting ${SETTLE_SECONDS}s before scrolling"

  /usr/bin/xcrun swift "$ROOT_DIR/script/smoke-scroll.swift" \
    --app "$APP_NAME" \
    --settle "$SETTLE_SECONDS" \
    --cycles "$SCROLL_CYCLES" \
    --delta "$SCROLL_DELTA" \
    --pause "$SCROLL_PAUSE"

  sleep 1
  # If an import became active during the smoke run, leave the app alive
  if active_root="$(is_import_active)"; then
    echo "Smoke run completed but import is now active for root=$active_root — leaving app running." >&2
    echo "Import was started during the smoke run; not quitting to avoid termination (plan 0066 Stage 6b)." >&2
    QUIT_ON_EXIT=0
    echo "smoke log: $LOG_FILE"
    echo "Post-hoc logs: script/logs.sh show --last 10m"
    exit 1
  fi
  echo "smoke log: $LOG_FILE"
  echo "Post-hoc logs: script/logs.sh show --last 10m"
}

if [[ "$MODE" != "--jank" && "$MODE" != "jank" && "$MODE" != "--verify" && "$MODE" != "verify" ]]; then
  usage
  exit 2
fi

if [[ -z "$SMOKE_ROOT" ]]; then
  echo "No library root given — there is no default (plan 0065 Stage 5)." >&2
  echo "Pass a root path as an argument, or set OTOS_SMOKE_SELECT_ROOT." >&2
  echo >&2
  registered_roots_message >&2
  exit 1
fi

if [[ ! -d "$SMOKE_ROOT" ]]; then
  echo "Smoke library root is not a directory: $SMOKE_ROOT" >&2
  echo "Pass a root path or set OTOS_SMOKE_SELECT_ROOT." >&2
  echo >&2
  registered_roots_message >&2
  exit 1
fi
SMOKE_ROOT="$(cd "$SMOKE_ROOT" && pwd -P)"

case "$MODE" in
  --verify|verify)
    run_verify
    ;;
  --jank|jank)
    run_jank
    ;;
esac
