#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/run-context.sh"

otos_require_full_xcode

LOG_FILE="$(otos_log_file "$ROOT_DIR" test test)"
echo "Capturing test output to $LOG_FILE"

# OTOS_SCALE_TEST gates the on-disk ~25k-asset projection scale test — it is
# materially slower than the default suite, so it stays skipped
# unless requested. xcodebuild does not forward shell environment variables to a
# UI-hosted XCTest bundle; the Otos.xcscheme's LaunchAction EnvironmentVariables
# entry substitutes `$(OTOS_SCALE_TEST)`, which only resolves when passed as a
# trailing build-setting-style argument here, not as an inherited env var.
#
# macOS ships bash 3.2, where `"${ARR[@]}"` on a zero-element array is an unbound
# -variable error under `set -u` — branch on the two invocations rather than rely
# on an always-safe empty-array expansion idiom.
if [[ -n "${OTOS_SCALE_TEST:-}" ]]; then
  echo "OTOS_SCALE_TEST set: including the on-disk projection scale test."
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/Otos.xcodeproj" \
    -scheme Otos \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    test "OTOS_SCALE_TEST=$OTOS_SCALE_TEST" | tee "$LOG_FILE"
else
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/Otos.xcodeproj" \
    -scheme Otos \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    test | tee "$LOG_FILE"
fi
