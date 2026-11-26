#!/usr/bin/env bash
# Fetches the symbols of the build installed at /Applications/Otos.app (ADR 0059): every
# build Sparkle installs was made on CI, whose release `v<x.y.z>` carries them. lldb and
# Instruments read a dSYM by its UUID; Spotlight finds one in build/InstalledSymbols/, so
# `lldb -p "$(pgrep -x Otos)"` symbolicates once this has run. An install made on this Mac
# (script/install.sh) needs none: its debug map points at build/InstallDerivedData.
#   script/installed-symbols.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/Otos.app"
[[ -d "$APP" ]] || { echo "op=symbols phase=failed reason=noInstalledApp" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DEST="$ROOT_DIR/build/InstalledSymbols/$VERSION"
if [[ -d "$DEST" ]]; then
  echo "op=symbols phase=present version=$VERSION path=$DEST"
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh release download "v$VERSION" --repo tonimelisma/Otos --pattern "Otos-$VERSION.dSYM.zip" --dir "$work" || {
  echo "op=symbols phase=failed version=$VERSION reason=noRelease detail=\"v$VERSION is not published: an install made on this Mac, or a release already pruned\"" >&2
  exit 1
}
mkdir -p "$DEST"
ditto -x -k "$work/Otos-$VERSION.dSYM.zip" "$DEST"
echo "op=symbols phase=fetched version=$VERSION path=$DEST"
