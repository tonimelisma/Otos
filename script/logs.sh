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
  script/logs.sh stream [Category] [--process <name>]
  script/logs.sh show --last <duration> [Category] [--process <name>]
  script/logs.sh capture --last <duration> [Category] [--process <name>]

stream   Live unified log + signpost capture (tee'd under logs/).
show     Post-hoc `log show` as ndjson (default --info --debug) for agent jq.
capture  Snapshot the unified log for a past window into logs/, without
         requiring a `stream` to have been running beforehand. macOS unified-
         log retention is finite (ADR 0015) — run this promptly after a run
         you need to keep.

Category is an optional OtosLog category (App, UI, Catalog, …).
The process defaults to Otos; use --process xctest (or OTOS_LOG_PROCESS)
to inspect test-emitted diagnostics.
Duration examples: 5m, 1h, 30s.
EOF
}

predicate_for() {
  local category="${1:-}"
  if [[ -n "$category" ]]; then
    printf 'process == "%s" AND subsystem == "%s" AND category == "%s"' \
      "$LOG_PROCESS" "$SUBSYSTEM" "$category"
  else
    printf 'process == "%s" AND subsystem == "%s"' "$LOG_PROCESS" "$SUBSYSTEM"
  fi
}

parse_process_and_category() {
  PARSED_CATEGORY=""
  LOG_PROCESS="${OTOS_LOG_PROCESS:-$APP_NAME}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
  parse_process_and_category "$@"
  local category="$PARSED_CATEGORY"
  local predicate
  predicate="$(predicate_for "$category")"
  local output_file
  output_file="$(otos_log_file "$ROOT_DIR" run prod)"
  echo "Capturing unified logs to $output_file"
  /usr/bin/log stream \
    --style compact \
    --level info \
    --signpost \
    --predicate "$predicate" \
    | tee "$output_file"
}

parse_last_and_category() {
  # Sets globals PARSED_LAST and PARSED_CATEGORY from `--last <duration>
  # [Category]` style args shared by `show` and `capture`.
  PARSED_LAST=""
  PARSED_CATEGORY=""
  LOG_PROCESS="${OTOS_LOG_PROCESS:-$APP_NAME}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --last)
        shift
        PARSED_LAST="${1:-}"
        [[ -n "$PARSED_LAST" ]] || { echo "Missing --last duration" >&2; exit 2; }
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
  if [[ -z "$PARSED_LAST" ]]; then
    PARSED_LAST="10m"
  fi
}

cmd_show() {
  parse_last_and_category "$@"
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
  parse_last_and_category "$@"
  local predicate
  predicate="$(predicate_for "$PARSED_CATEGORY")"
  local output_file
  output_file="$(otos_log_file "$ROOT_DIR" capture prod)"
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
