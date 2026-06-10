#!/usr/bin/env bash
set -euo pipefail

OTOS_EXPECTED_XCODE="/Applications/Xcode-beta.app/Contents/Developer"
OTOS_PROJECT_NAME="Otos"

otos_project_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

otos_require_full_xcode() {
  local selected
  selected="$(/usr/bin/xcode-select -p 2>/dev/null || true)"

  if [[ -z "$selected" || "$selected" == "/Library/Developer/CommandLineTools" || ! -x "$selected/usr/bin/xcodebuild" ]]; then
    cat >&2 <<EOF
Full Xcode is required for Otos.

Current developer directory:
  ${selected:-<none>}

Fix:
  sudo xcode-select --switch $OTOS_EXPECTED_XCODE
EOF
    exit 66
  fi

  if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    cat >&2 <<EOF
xcodebuild is not usable from the selected developer directory:
  $selected

Fix:
  sudo xcode-select --switch $OTOS_EXPECTED_XCODE
EOF
    exit 66
  fi
}
