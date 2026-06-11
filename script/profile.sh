#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"

APP_NAME="Otos"
TEMPLATE="${1:-SwiftUI}"
DURATION="${2:-10s}"
OUTPUT_DIR="$ROOT_DIR/build/Profiles"

otos_require_full_xcode

if [[ "$TEMPLATE" == "list" || "$TEMPLATE" == "--list" ]]; then
  /usr/bin/xcrun xctrace list templates
  exit 0
fi

mkdir -p "$OUTPUT_DIR"

"$ROOT_DIR/script/build_and_run.sh" --verify

SAFE_TEMPLATE="$(printf "%s" "$TEMPLATE" | tr -c "[:alnum:]" "-")"
OUTPUT="$OUTPUT_DIR/${SAFE_TEMPLATE}-$(date +%Y%m%d-%H%M%S).trace"

/usr/bin/xcrun xctrace record \
  --template "$TEMPLATE" \
  --attach "$APP_NAME" \
  --time-limit "$DURATION" \
  --output "$OUTPUT" \
  --no-prompt

echo "$OUTPUT"
