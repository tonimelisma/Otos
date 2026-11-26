#!/usr/bin/env bash
# Builds the Debug app, compiled with -O, with the product identity and installs it at
# /Applications/Otos.app (ADR 0030). Debug, because the installed app must stay
# debuggable: it keeps get-task-allow (lldb / xctrace can attach) and every
# `#if DEBUG` diagnostic. A plain build, not `xcodebuild archive` — archiving is a
# distribution build and strips get-task-allow even when an entitlements file
# sets it explicitly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/installed-app.sh"
source "$ROOT_DIR/script/lib/build-folder.sh"
source "$ROOT_DIR/script/lib/installed-build.sh"

BUNDLE_ID="net.melisma.Otos"
INSTALLED_APP="$OTOS_INSTALLED_APP"
# Its own DerivedData: the installed binary's debug map points at these object
# files, so they must survive until the next install replaces both — and dev
# builds in build/DerivedData use different settings.
DERIVED_DATA="$ROOT_DIR/build/InstallDerivedData"
BUILT_APP="$(otos_installed_build_app "$DERIVED_DATA")"

otos_require_full_xcode
# One install at a time: a second waits for the first, then builds its own HEAD.
otos_hold_build_folder "$DERIVED_DATA" install

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo "Refusing to install from a dirty tree: the installed app must be one commit." >&2
  exit 1
fi
REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
TREE="$(otos_tree_identity "$ROOT_DIR")"

if [[ -e "$INSTALLED_APP" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace $INSTALLED_APP: its bundle id is '${existing_id:-unknown}', not $BUNDLE_ID." >&2
    exit 1
  fi
fi

otos_build_installed_app "$ROOT_DIR" "$DERIVED_DATA"

# A pull during the build leaves a binary that is neither commit; never install it.
if [[ "$(otos_tree_identity "$ROOT_DIR")" != "$TREE" ]]; then
  echo "op=install phase=failed revision=$REVISION reason=treeChangedDuringBuild" >&2
  exit 1
fi

otos_check_installed_build "$BUILT_APP"

quit_status=0
otos_quit_installed_app || quit_status=$?
if [[ "$quit_status" == 1 ]]; then
  echo "Not installing: the installed Otos has an import or reorganization in flight (root=$OTOS_INSTALLED_BUSY_ROOT)." >&2
  echo "op=install phase=pending revision=$REVISION reason=busy"
  exit 1
elif [[ "$quit_status" != 0 ]]; then
  echo "op=install phase=failed revision=$REVISION reason=quitFailed" >&2
  exit 1
fi
was_running="$OTOS_INSTALLED_WAS_RUNNING"

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

otos_reopen_installed_app

echo "op=install phase=finish revision=$REVISION path=$INSTALLED_APP relaunched=$was_running unregisteredStrays=$unregistered"
