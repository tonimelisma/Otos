#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"

# This used to `pkill -x "$APP_NAME"` so that the PID lookup below could not be
# ambiguous — resolving the question by destroying the alternative, including a
# session the user was running. Refuse instead.
otos_refuse_if_running "$APP_NAME"

BEFORE_PIDS="$(otos_running_pids "$APP_NAME")"
"$ROOT_DIR/script/build_and_run.sh" run
APP_PID="$(otos_newly_launched_pid "$APP_NAME" "$BEFORE_PIDS")"

OUTPUT_FILE="$(otos_log_file "$ROOT_DIR" run prod "$APP_PID")"
echo "Capturing unified logs for pid=$APP_PID to $OUTPUT_FILE"
echo "Stop with Ctrl+C when the session is complete."

/usr/bin/log stream \
  --style compact \
  --level info \
  --signpost \
  --predicate "process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\"" \
  | tee "$OUTPUT_FILE"
