#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"

source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/run-context.sh"
otos_require_full_xcode

# Killing every instance made the PID lookup below unambiguous by destroying the
# alternative — including a session the user was running. Refuse instead.
otos_refuse_if_running "$APP_NAME"

/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Otos.xcodeproj" \
  -scheme Otos \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Built app bundle not found at $APP_BUNDLE" >&2
  exit 1
fi

open_app() {
  if [[ -n "${OTOS_SMOKE_SELECT_ROOT:-}" ]]; then
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 &
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

# The oldest instance is not the one just launched: naming a capture after it
# labels the file with a PID that emitted none of its lines.
wait_for_app_pid() {
  otos_newly_launched_pid "$APP_NAME" "${1:-}"
}

stream_logs() {
  local predicate="$1"
  local before
  before="$(otos_running_pids "$APP_NAME")"
  open_app
  local app_pid
  app_pid="$(wait_for_app_pid "$before")"
  local output_file
  output_file="$(otos_log_file "$ROOT_DIR" run prod "$app_pid")"
  echo "Capturing unified logs for pid=$app_pid to $output_file"
  /usr/bin/log stream \
    --style compact \
    --level info \
    --signpost \
    --predicate "$predicate" \
    | tee "$output_file"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    stream_logs "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stream_logs "subsystem == \"$SUBSYSTEM\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    echo "Log-stream modes capture timestamped files under logs/." >&2
    exit 2
    ;;
esac
