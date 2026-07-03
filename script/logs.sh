#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"
CATEGORY="${1:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"

if [[ -n "$CATEGORY" ]]; then
  PREDICATE="process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\" AND category == \"$CATEGORY\""
else
  PREDICATE="process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\""
fi

OUTPUT_FILE="$(otos_log_file "$ROOT_DIR" run prod)"
echo "Capturing unified logs to $OUTPUT_FILE"

/usr/bin/log stream \
  --style compact \
  --level info \
  --signpost \
  --predicate "$PREDICATE" \
  | tee "$OUTPUT_FILE"
