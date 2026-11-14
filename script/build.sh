#!/usr/bin/env bash
# build-for-testing (not plain build) so script/test.sh's test-without-building
# has products to run against without xcodebuild compiling everything twice.
# It still produces Otos.app, since the Otos.xcscheme's BuildActionEntry has
# buildForTesting=YES for it - callers that only want the app (build_and_run.sh,
# smoke-run.sh) are unaffected.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/build-folder.sh"

otos_require_full_xcode
otos_hold_build_folder "$ROOT_DIR/build/DerivedData" build
otos_build_checkout "$ROOT_DIR" verification -showBuildTimingSummary build-for-testing
