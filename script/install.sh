#!/usr/bin/env bash
# Builds the Debug app with the product identity and installs it at
# /Applications/Otos.app (ADR 0030). Debug, because the installed app must stay
# debuggable: it keeps get-task-allow (lldb / xctrace can attach) and every
# `#if DEBUG` diagnostic. A plain build, not `xcodebuild archive` — archiving is a
# distribution build and strips get-task-allow even when an entitlements file
# sets it explicitly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/operational-busy.sh"

BUNDLE_ID="net.melisma.Otos"
INSTALLED_APP="/Applications/Otos.app"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/Otos"
CATALOG_DB="$HOME/Library/Application Support/$BUNDLE_ID/Catalog/catalog.sqlite"
# Its own DerivedData: the installed binary's debug map points at these object
# files, so they must survive until the next install replaces both — and dev
# builds in build/DerivedData use different settings.
DERIVED_DATA="$ROOT_DIR/build/InstallDerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/Otos.app"

otos_require_full_xcode

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo "Refusing to install from a dirty tree: the installed app must be one commit." >&2
  exit 1
fi
REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"

if [[ -e "$INSTALLED_APP" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace $INSTALLED_APP: its bundle id is '${existing_id:-unknown}', not $BUNDLE_ID." >&2
    exit 1
  fi
fi

# OTOS_BUNDLE_ID_SUFFIX empty = the product identity (dev builds use .dev).
# Xcode 27 enables code coverage for Debug by default; an instrumented binary
# writes default.profraw into its working directory on every quit.
/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Otos.xcodeproj" \
  -scheme Otos \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  OTOS_BUNDLE_ID_SUFFIX= \
  ENABLE_CODE_COVERAGE=NO \
  ENABLE_DEBUG_DYLIB=NO \
  CURRENT_PROJECT_VERSION="$(git -C "$ROOT_DIR" rev-list --count HEAD)" \
  build

built_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$BUILT_APP/Contents/Info.plist")"
[[ "$built_id" == "$BUNDLE_ID" ]] || { echo "Built bundle id is $built_id, expected $BUNDLE_ID" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$BUILT_APP"
/usr/bin/codesign -d --entitlements - --xml "$BUILT_APP" 2>/dev/null | grep -q "get-task-allow" \
  || { echo "Built app lacks get-task-allow; debugger and Instruments could not attach." >&2; exit 1; }

was_running=0
if pgrep -fx "$INSTALLED_EXECUTABLE" >/dev/null; then
  if active_root="$(has_active_operational_work "$CATALOG_DB")"; then
    echo "Not installing: the installed Otos has an import or reorganization in flight (root=$active_root)." >&2
    echo "op=install phase=pending revision=$REVISION reason=busy"
    exit 1
  fi
  was_running=1
  # A normal Quit (same as ⌘Q), never a kill: the app gets its own termination
  # path, including device-staging cleanup.
  /usr/bin/osascript -e "tell application \"$INSTALLED_APP\" to quit" >/dev/null
  # `caffeinate -w` returns when that process exits — the kernel reports the exit, so
  # nothing here guesses how long termination takes.
  for pid in $(pgrep -fx "$INSTALLED_EXECUTABLE" || true); do
    /usr/bin/caffeinate -w "$pid"
  done
fi

# Swap by rename so /Applications never holds a half-copied bundle. The built
# bundle is moved, not copied: /Applications/Otos.app must be the only bundle on
# disk with the product identity, or LaunchServices can launch the other one by
# bundle id (Dock, Spotlight, a card-insert handler) against the same catalog.
# lldb is unaffected — the debug map points at object files, not the bundle.
incoming="/Applications/.Otos.app.incoming.$$"
previous="/Applications/.Otos.app.previous.$$"
mv "$BUILT_APP" "$incoming"
if [[ -e "$INSTALLED_APP" ]]; then
  mv "$INSTALLED_APP" "$previous"
fi
mv "$incoming" "$INSTALLED_APP"
rm -rf "$previous"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$INSTALLED_APP"

# Registrations left by builds from before ADR 0030 still carry the product
# identity. On 2026-10-01 a Sep 22 Xcode build launched beside the installed
# app and its import hit `database is locked` on the shared catalog. Unregister
# every other path with the product identity; this touches only the
# LaunchServices database, never a bundle.
unregistered=0
while IFS= read -r stray; do
  [[ -n "$stray" && "$stray" != "$INSTALLED_APP" ]] || continue
  "$LSREGISTER" -u "$stray" 2>/dev/null || true
  unregistered=$((unregistered + 1))
done < <("$LSREGISTER" -dump 2>/dev/null | awk -v id="$BUNDLE_ID" '
  /^path:/ { sub(/^path:[ \t]*/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
  /^identifier:/ && $2 == id { print path }
' | sort -u)

if [[ "$was_running" == 1 ]]; then
  /usr/bin/open -g "$INSTALLED_APP"
fi

echo "op=install phase=finish revision=$REVISION path=$INSTALLED_APP relaunched=$was_running unregisteredStrays=$unregistered"
