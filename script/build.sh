#!/usr/bin/env bash
# build-for-testing (not plain build) so script/test.sh's test-without-building
# has products to run against without xcodebuild compiling everything twice.
# It still produces Otos.app, since the Otos.xcscheme's BuildActionEntry has
# buildForTesting=YES for it - callers that only want the app (build_and_run.sh,
# smoke-run.sh) are unaffected.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"

otos_require_full_xcode
otos_build_settings "$ROOT_DIR"

/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Otos.xcodeproj" \
  -scheme Otos \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$ROOT_DIR/build/DerivedData" \
  -showBuildTimingSummary \
  build-for-testing "${OTOS_BUILD_SETTINGS[@]}"
