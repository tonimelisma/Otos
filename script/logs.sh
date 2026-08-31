#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"
LOG_PROCESS="${OTOS_LOG_PROCESS:-$APP_NAME}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"

usage() {
  cat <<'EOF'
Usage:
  script/logs.sh stream [Category] [--process <name>] [--pid <pid>]
  script/logs.sh show --last <duration> [Category] [--process <name>] [--pid <pid>]
  script/logs.sh capture --last <duration> [Category] [--process <name>] [--pid <pid>]

stream   Live unified log + signpost capture (tee'd under logs/).
show     Post-hoc `log show` as ndjson (default --info --debug) for agent jq.
capture  Snapshot the unified log for a past window into logs/, without
         requiring a `stream` to have been running beforehand. macOS unified-
         log retention is finite (ADR 0015) — run this promptly after a run
         you need to keep.

Category is an optional OtosLog category (App, UI, Catalog, …).
The process defaults to Otos; use --process xctest (or OTOS_LOG_PROCESS)
to inspect test-emitted diagnostics.

--pid (or OTOS_LOG_PID) scopes the capture to one running instance. Every Otos
process writes to the same system log, so without it a capture taken while two
instances are alive interleaves them and cannot be attributed. Capture filenames
carry the pid when one is given.
Duration examples: 5m, 1h, 30s.
EOF
}

# Every Otos instance writes to the one system log, so a capture filtered only by
# process name interleaves them. That is not academic: with two app launches and a
# test run alive at once, a reader cannot tell which instance emitted a line, and a
# watcher pointed at "the log" silently reads whichever run wrote last. `--pid`
# scopes a capture to a single running instance; the OS already stamps the PID, so
# this costs nothing at runtime.
predicate_for() {
  local category="${1:-}"
  local predicate
  predicate="$(printf 'process == "%s" AND subsystem == "%s"' "$LOG_PROCESS" "$SUBSYSTEM")"
  if [[ -n "$category" ]]; then
    predicate="$predicate$(printf ' AND category == "%s"' "$category")"
  fi
  if [[ -n "${LOG_PID:-}" ]]; then
    predicate="$predicate$(printf ' AND processID == %s' "$LOG_PID")"
  fi
  printf '%s' "$predicate"
}

# One parser for every subcommand. `show`/`capture` and `stream` previously had two
# near-identical argument loops, so a flag added to one simply did not exist in the
# other: `--pid` reached only `stream`, both post-hoc readers answered it with a
# usage message, and `capture` kept naming its file after the capturing shell. One
# parser makes that divergence unrepresentable.
parse_log_args() {
  PARSED_LAST=""
  PARSED_CATEGORY=""
  LOG_PROCESS="${OTOS_LOG_PROCESS:-$APP_NAME}"
  LOG_PID="${OTOS_LOG_PID:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --last)
        shift
        PARSED_LAST="${1:-}"
        [[ -n "$PARSED_LAST" ]] || { echo "Missing --last duration" >&2; exit 2; }
        shift
        ;;
      --pid)
        shift
        LOG_PID="${1:-}"
        [[ "$LOG_PID" =~ ^[0-9]+$ ]] || { echo "--pid needs a numeric process id" >&2; exit 2; }
        shift
        ;;
      --process)
        shift
        LOG_PROCESS="${1:-}"
        [[ -n "$LOG_PROCESS" ]] || { echo "Missing --process name" >&2; exit 2; }
        shift
        ;;
      -*)
        echo "Unknown option: $1" >&2
        usage
        exit 2
        ;;
      *)
        PARSED_CATEGORY="$1"
        shift
        ;;
    esac
  done
}

cmd_stream() {
  parse_log_args "$@"
  [[ -z "$PARSED_LAST" ]] || { echo "stream is live; --last belongs to show/capture" >&2; exit 2; }
  local category="$PARSED_CATEGORY"
  local predicate
  predicate="$(predicate_for "$category")"
  local output_file
  output_file="$(otos_log_file "$ROOT_DIR" run prod ${LOG_PID:-$$})"
  echo "Capturing unified logs to $output_file"
  /usr/bin/log stream \
    --style compact \
    --level info \
    --signpost \
    --predicate "$predicate" \
    | tee "$output_file"
}

cmd_show() {
  parse_log_args "$@"
  PARSED_LAST="${PARSED_LAST:-10m}"
  local predicate
  predicate="$(predicate_for "$PARSED_CATEGORY")"
  /usr/bin/log show \
    --last "$PARSED_LAST" \
    --style ndjson \
    --info \
    --debug \
    --predicate "$predicate"
}

cmd_capture() {
  parse_log_args "$@"
  PARSED_LAST="${PARSED_LAST:-10m}"
  local predicate
  predicate="$(predicate_for "$PARSED_CATEGORY")"
  local output_file
  output_file="$(otos_log_file "$ROOT_DIR" capture prod ${LOG_PID:-$$})"
  /usr/bin/log show \
    --last "$PARSED_LAST" \
    --style compact \
    --info \
    --debug \
    --signpost \
    --predicate "$predicate" \
    > "$output_file"
  echo "Captured unified logs (last $PARSED_LAST) to $output_file"
}

main() {
  local action="${1:-}"
  case "$action" in
    stream)
      shift
      cmd_stream "$@"
      ;;
    show)
      shift
      cmd_show "$@"
      ;;
    capture)
      shift
      cmd_capture "$@"
      ;;
    -h|--help|help|"")
      usage
      [[ -n "$action" ]] || exit 2
      ;;
    *)
      # Back-compat: `script/logs.sh [Category]` → stream
      cmd_stream "$@"
      ;;
  esac
}

main "$@"
