#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/build/Logs"
TIMESTAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"

mkdir -p "$LOG_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/script/build_and_run.sh" run

for _ in $(seq 1 50); do
  APP_PID="$(pgrep -x "$APP_NAME" | head -n 1 || true)"
  if [[ -n "$APP_PID" ]]; then
    break
  fi
  sleep 0.1
done

if [[ -z "${APP_PID:-}" ]]; then
  echo "Timed out waiting for $APP_NAME to launch" >&2
  exit 1
fi

OUTPUT_FILE="$LOG_DIR/run-${TIMESTAMP}-${APP_PID}.log"
echo "Capturing unified logs for pid=$APP_PID to $OUTPUT_FILE"
echo "Stop with Ctrl+C when the session is complete."

/usr/bin/log stream \
  --style compact \
  --level info \
  --signpost \
  --predicate "process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\"" \
  | tee "$OUTPUT_FILE"
