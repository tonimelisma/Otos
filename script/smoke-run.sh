#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"
source "$ROOT_DIR/script/lib/operational-busy.sh"
LOG_DIR="$(otos_logs_dir "$ROOT_DIR")"
CATALOG_DB="$HOME/Library/Application Support/$SUBSYSTEM/Catalog/catalog.sqlite"

MODE="${1:---jank}"
if [[ "$MODE" == "--help" || "$MODE" == "help" ]]; then
  cat >&2 <<'USAGE'
usage: script/smoke-run.sh [--jank|--verify] <library-root>

The root must already be registered in the catalog. A smoke run selects an
existing root; it never adds, removes, or otherwise changes what libraries
exist (ADR 0020). There is no default: a machine's registered roots
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
# this run's cleanup (ADR 0020).
APP_PID=""

usage() {
  cat >&2 <<'USAGE'
usage: script/smoke-run.sh [--jank|--verify] <library-root>

The root must already be registered in the catalog. A smoke run selects an
existing root; it never adds, removes, or otherwise changes what libraries
exist (ADR 0020). There is no default: a machine's registered roots
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
  # run's still-capturing app instance (observed in review; it
  # silently truncated a session to a log that looked complete).
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
}

# Durable operational truth: any row in `active_file_operation` (import) or
# `active_reorganization_component` (reorganization) proves work is in flight.
# The Store's `hasActiveOperationalWork()` is the authoritative reader; this
# shell copy is the same predicate via `sqlite3 -readonly` under WAL so it
# never blocks the writer. Pessimistic: any sqlite error (SQLITE_BUSY,
# SQLITE_CORRUPT, missing table) is treated as busy — the only safe direction.
# `is_import_active` is kept as a compatibility alias; new code calls
# `has_active_operational_work`.
cleanup() {
  if [[ -n "$LOG_PID" ]]; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$QUIT_ON_EXIT" == 1 ]]; then
    local active_root
    if active_root="$(has_active_operational_work "$CATALOG_DB")"; then
      echo "Smoke run leaving app running: operational work still active (import or reorganization) for root=$active_root" >&2
      echo "An import or reorganization was in flight; not quitting the app to avoid mid-operation termination (ARC-002A)." >&2
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
# registered one — registering is exactly what the smoke seam forbids (ADR 0020).
# `outcome=selected` is logged only after the root appeared among the Store's own
# published roots.
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
  check_provider_readiness
  QUIT_ON_EXIT=1
  local app_pid
  app_pid="$(run_selected_launch)"
  sleep "${OTOS_SMOKE_VERIFY_SECONDS:-3}"
  verify_selection_applied "$app_pid"
  echo "Smoke launch succeeded, window scoped to root=$SMOKE_ROOT"
}

check_provider_readiness() {
  # A capture that silently measures a dead provider is worse than no capture.
  # Do a real open()+read(4096) on one file under SMOKE_ROOT; if it times out with ETIMEDOUT,
  # refuse to start or loudly annotate. Process presence (pgrep OneDrive) is not readiness.
  local sample
  sample="$(find "$SMOKE_ROOT" -type f \( -name "*.jpg" -o -name "*.heic" -o -name "*.png" -o -name "*.mp4" -o -name "*.mov" \) -print -quit 2>/dev/null || true)"
  if [[ -z "$sample" ]]; then
    echo "Warning: no sample file found under $SMOKE_ROOT to probe provider readiness; proceeding." >&2
    return 0
  fi
  if ! python3 -c "
import os, sys
p = sys.argv[1]
try:
    with open(p, 'rb') as f:
        f.read(4096)
    sys.exit(0)
except OSError as e:
    # ETIMEDOUT is 60 on macOS, 110 on Linux; check both
    if e.errno in (60, 110) or 'timed out' in str(e).lower() or 'ETIMEDOUT' in str(e):
        print(f'Provider not serving: open+read failed for {p}: {e} (errno {e.errno})', file=sys.stderr)
        sys.exit(2)
    print(f'Probe read failed for {p}: {e} (errno {getattr(e, "errno", "?")})', file=sys.stderr)
    sys.exit(1)
" "$sample"; then
    local rc=$?
    if [[ $rc -eq 2 ]]; then
      echo "Provider readiness check failed: $SMOKE_ROOT's File Provider is not serving reads (ETIMEDOUT)." >&2
      echo "Re-auth OneDrive / wait for the provider to finish initialising, then re-run. A dead-provider capture would look like data." >&2
      exit 2
    fi
    echo "Provider probe failed for $sample (exit $rc); proceeding but capture may be invalid." >&2
  fi
}

run_jank() {
  # ARC-002A: refuse to start when any operational journal is active
  local active_root
  if active_root="$(has_active_operational_work "$CATALOG_DB")"; then
    echo "Cannot start smoke run: operational work already active for root=$active_root" >&2
    echo "Finish or cancel the import/reorganization before running --jank (ARC-002A)." >&2
    exit 1
  fi
  check_provider_readiness
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
  # If operational work became active during the smoke run, leave the app alive
  if active_root="$(has_active_operational_work "$CATALOG_DB")"; then
    echo "Smoke run completed but operational work is now active for root=$active_root — leaving app running." >&2
    echo "Work was started during the smoke run; not quitting to avoid termination (ARC-002A)." >&2
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
  echo "No library root given — there is no default (ADR 0020)." >&2
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
