#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"
CATEGORY="${1:-}"

if [[ -n "$CATEGORY" ]]; then
  PREDICATE="process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\" AND category == \"$CATEGORY\""
else
  PREDICATE="process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\""
fi

/usr/bin/log stream \
  --style compact \
  --level info \
  --signpost \
  --predicate "$PREDICATE"
