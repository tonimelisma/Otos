#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"

otos_require_full_xcode

/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Otos.xcodeproj" \
  -scheme Otos \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$ROOT_DIR/build/DerivedData" \
  build
