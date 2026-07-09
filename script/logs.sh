#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"

usage() {
  cat <<'EOF'
Usage:
  script/logs.sh stream [Category]
  script/logs.sh show --last <duration> [Category]

stream  Live unified log + signpost capture (tee'd under logs/).
show    Post-hoc `log show` as ndjson (default --info --debug) for agent jq.

Category is an optional OtosLog category (App, UI, Catalog, …).
Duration examples: 5m, 1h, 30s.
EOF
}

predicate_for() {
  local category="${1:-}"
  if [[ -n "$category" ]]; then
    printf 'process == "%s" AND subsystem == "%s" AND category == "%s"' \
      "$APP_NAME" "$SUBSYSTEM" "$category"
  else
    printf 'process == "%s" AND subsystem == "%s"' "$APP_NAME" "$SUBSYSTEM"
  fi
}

cmd_stream() {
  local category="${1:-}"
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

cmd_show() {
  local last=""
  local category=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --last)
        shift
        last="${1:-}"
        [[ -n "$last" ]] || { echo "Missing --last duration" >&2; exit 2; }
        shift
        ;;
      -*)
        echo "Unknown option: $1" >&2
        usage
        exit 2
        ;;
      *)
        category="$1"
        shift
        ;;
    esac
  done
  if [[ -z "$last" ]]; then
    last="10m"
  fi
  local predicate
  predicate="$(predicate_for "$category")"
  /usr/bin/log show \
    --last "$last" \
    --style ndjson \
    --info \
    --debug \
    --predicate "$predicate"
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
