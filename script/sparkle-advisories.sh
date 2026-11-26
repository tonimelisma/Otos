#!/usr/bin/env bash
# Fails when the Sparkle version Otos pins has known advisories in the OSV database
# (ADR 0059): script/release.sh runs it before it builds, so no build with a vulnerable
# updater is published. The version is the one `Package.resolved` pins.
#   script/sparkle-advisories.sh           ask OSV about the pinned version
#   script/sparkle-advisories.sh version   print the pinned version (script/release-test.sh)
# The OSV API is asked with no credential; a failed request fails the check, so an
# unanswered question never reads as "no advisories".
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED="${OTOS_PACKAGE_RESOLVED:-$ROOT_DIR/Otos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved}"

VERSION="$(/usr/bin/python3 -I -c '
import json, sys
pins = [p for p in json.load(open(sys.argv[1]))["pins"] if p.get("identity") == "sparkle"]
if len(pins) != 1 or not pins[0].get("state", {}).get("version"):
    sys.exit("sparkle-advisories: Package.resolved pins no Sparkle version")
print(pins[0]["state"]["version"])
' "$RESOLVED")"

if [[ "${1:-}" == version ]]; then
  echo "$VERSION"
  exit 0
fi

BODY="$(printf '{"package":{"name":"github.com/sparkle-project/Sparkle","ecosystem":"SwiftURL"},"version":"%s"}' "$VERSION")"
if ! RESULT="$(curl -fsS --max-time 30 -X POST https://api.osv.dev/v1/query -H 'Content-Type: application/json' -d "$BODY")"; then
  echo "op=sparkle.advisories phase=failed version=$VERSION reason=osvUnreachable" >&2
  exit 1
fi
if [[ "$(printf '%s' "$RESULT" | tr -d '[:space:]')" != "{}" ]]; then
  echo "op=sparkle.advisories phase=found version=$VERSION" >&2
  printf '%s\n' "$RESULT" >&2
  exit 1
fi
echo "op=sparkle.advisories phase=none version=$VERSION"
