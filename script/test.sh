#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/run-context.sh"

otos_require_full_xcode

LOG_FILE="$(otos_log_file "$ROOT_DIR" test test)"
echo "Capturing test output to $LOG_FILE"

/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Otos.xcodeproj" \
  -scheme Otos \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$ROOT_DIR/build/DerivedData" \
  test | tee "$LOG_FILE"
