#!/usr/bin/env bash
# Builds, signs and publishes the checked-out main commit as an update of the installed app
# (ADR 0059): `.github/workflows/release.yml` runs it on GitHub's xcode-27 runner once that
# commit's CI passed. It publishes to GitHub, so it is never run on the Mac.
#
# A release is made only when the app changed since the newest release: something under Otos/,
# OtosKit/, Otos.xcodeproj/ or Config/. It is `v<x.y.z>`, the next version of the project's
# MARKETING_VERSION series (script/release-version.sh), with CFBundleVersion the commit count,
# the number Sparkle compares. It holds the disk image a person installs from (`Otos.dmg`), the
# app's Sparkle archive, its symbols and the feed that names it (`script/appcast.sh`). It is
# refused while the pinned Sparkle has known advisories (`script/sparkle-advisories.sh`). It is
# marked latest, so https://github.com/tonimelisma/Otos/releases/latest/download/appcast.xml is
# always the newest build's feed. Only the newest three releases are kept.
#
# The environment the workflow gives it:
#   OTOS_DEVELOPMENT_TEAM   the team ID; never in the repository
#   OTOS_SIGNING_IDENTITY   the SHA-1 of the owner's Apple Development identity, in
#   OTOS_SIGNING_KEYCHAIN   the keychain the workflow imported it into for this run
#   SPARKLE_PRIVATE_KEY     Otos's EdDSA update key, handed to sign_update on standard input
#   GH_TOKEN, GITHUB_REPOSITORY
# The certificate is the one the Mac's own installs sign with, so an update keeps the
# installed app's privacy permissions and Keychain items.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/installed-build.sh"

: "${OTOS_DEVELOPMENT_TEAM:?the team ID is needed}"
: "${OTOS_SIGNING_IDENTITY:?the signing identity is needed}"
: "${OTOS_SIGNING_KEYCHAIN:?the signing keychain is needed}"
: "${SPARKLE_PRIVATE_KEY:?the update key is needed}"
: "${GITHUB_REPOSITORY:?the repository is needed}"
KEEP=3

otos_require_full_xcode
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo "op=release phase=failed reason=dirtyTree" >&2
  exit 1
fi
SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
APP_PATHS=(Otos OtosKit Otos.xcodeproj Config)

# The newest release, and whether this commit changes the app it holds. The release workflow
# runs one at a time, so no other release is made while this one decides.
releases="$(gh release list --repo "$GITHUB_REPOSITORY" --limit 200 --json tagName,isLatest,createdAt)"
latest="$(printf '%s' "$releases" | jq -r '.[] | select(.isLatest) | .tagName')"
if [[ -n "$latest" ]]; then
  git -C "$ROOT_DIR" fetch -q origin "+refs/tags/$latest:refs/tags/$latest"
  released="$(git -C "$ROOT_DIR" rev-parse "$latest^{commit}")"
  if git -C "$ROOT_DIR" merge-base --is-ancestor "$SHA" "$released"; then
    echo "op=release phase=skipped commit=$SHA latest=$latest reason=notNewer"
    exit 0
  fi
  if git -C "$ROOT_DIR" diff --quiet "$released" "$SHA" -- "${APP_PATHS[@]}"; then
    echo "op=release phase=skipped commit=$SHA latest=$latest reason=appUnchanged"
    exit 0
  fi
fi

# The version: the next of the project's MARKETING_VERSION series after the newest `v<x.y.z>`.
series="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' "$ROOT_DIR/Otos.xcodeproj/project.pbxproj" | sort -u)"
[[ "$(printf '%s\n' "$series" | grep -c .)" == 1 ]] || {
  echo "op=release phase=failed reason=marketingVersionsDiffer values=\"$(printf '%s' "$series" | tr '\n' ' ')\"" >&2
  exit 1
}
newest_version="$(printf '%s' "$releases" | jq -r '.[].tagName' | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | sort -V | tail -1)"
VERSION="$("$ROOT_DIR/script/release-version.sh" "$series" "$newest_version")"
TAG="v$VERSION"

# No build with an updater that has known advisories is published.
"$ROOT_DIR/script/sparkle-advisories.sh"

DERIVED="$ROOT_DIR/build/ReleaseDerivedData"

release_notes() {
  cat << NOTES
Otos $VERSION, build $BUILD of main ($SHA). An installed Otos updates itself to it within the hour (ADR 0059).

To install by hand: download **Otos.dmg** below, open it, and drag Otos to Applications. It needs macOS 27 or later.

Otos is signed for development, not notarized by Apple. The first time you open it, macOS says it can’t check Otos: click **Done**, open **System Settings → Privacy & Security**, click **Open Anyway** next to Otos, and confirm. After that it opens like any app, and updates itself.
NOTES
}
APP="$(otos_installed_build_app "$DERIVED")"
otos_build_installed_app "$ROOT_DIR" "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$OTOS_SIGNING_IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER= \
  OTHER_CODE_SIGN_FLAGS="--keychain=$OTOS_SIGNING_KEYCHAIN" \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  MARKETING_VERSION="$VERSION"
otos_check_installed_build "$APP"
key="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2> /dev/null || true)"
[[ -n "$key" ]] || {
  echo "op=release phase=failed reason=noUpdateKey detail=\"OTOS_SPARKLE_PUBLIC_ED_KEY is empty: installed copies could not check this build's signature\"" >&2
  exit 1
}
short="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[[ "$short" == "$VERSION" ]] || { echo "op=release phase=failed reason=versionNotStamped built=$short expected=$VERSION" >&2; exit 1; }

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
archive="$out/Otos-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$archive"
# The symbols of every image the build made: lldb reads them by UUID
# (`script/installed-symbols.sh` fetches the installed build's).
mkdir "$out/symbols"
for dsym in "$DERIVED/Build/Products/Debug"/*.dSYM; do
  if [[ -d "$dsym" ]]; then
    ditto "$dsym" "$out/symbols/$(basename "$dsym")"
  fi
done
symbols="$out/Otos-$VERSION.dSYM.zip"
ditto -c -k --keepParent "$out/symbols" "$symbols"

# The disk image a person installs from: Otos beside a link to Applications, to drag one onto
# the other, compressed read-only and signed with the app's own certificate, as latchkey's is.
# `releases/latest/download/Otos.dmg` is always the newest build's.
mkdir "$out/image"
ditto "$APP" "$out/image/Otos.app"
ln -s /Applications "$out/image/Applications"
image="$out/Otos.dmg"
hdiutil create -quiet -volname "Otos" -srcfolder "$out/image" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$image"
/usr/bin/codesign --sign "$OTOS_SIGNING_IDENTITY" --keychain "$OTOS_SIGNING_KEYCHAIN" --timestamp=none "$image"
/usr/bin/codesign --verify "$image"
hdiutil verify -quiet "$image"

# The update key goes in on standard input, never to a file.
sign_update="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
signed="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$archive")"
signature="$(printf '%s' "$signed" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[[ -n "$signature" ]] || { echo "op=release phase=failed reason=noSignature" >&2; exit 1; }
length="$(stat -f %z "$archive")"
url="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/Otos-$VERSION.zip"
"$ROOT_DIR/script/appcast.sh" "$BUILD" "$VERSION" "$url" "$length" "$signature" > "$out/appcast.xml"

# The archive as it ships, unpacked and launched on a library of generated media: a build
# that cannot reach its first grid and draw its window is not published (plan 0118, step 2).
# The captures stay in build/release-captures, which the Release workflow keeps.
mkdir "$out/launch"
ditto -x -k "$archive" "$out/launch"
if ! "$ROOT_DIR/script/app-capture.sh" "$out/launch/Otos.app" "$ROOT_DIR/build/release-captures" 60; then
  echo "op=release phase=failed reason=launchCheck detail=\"the archive as it ships did not reach its first grid and draw its window\"" >&2
  exit 1
fi

gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --target "$SHA" --latest \
  --title "Otos $VERSION" \
  --notes "$(release_notes)" \
  "$image" "$archive" "$symbols" "$out/appcast.xml"
echo "op=release phase=published version=$VERSION build=$BUILD tag=$TAG commit=$SHA"

# Older releases go, their tags with them: all but the newest three, by when they were made.
gh release list --repo "$GITHUB_REPOSITORY" --limit 200 --json tagName,createdAt \
  --jq 'sort_by(.createdAt) | reverse | .[].tagName' | tail -n +"$((KEEP + 1))" | while read -r old; do
  [[ "$old" =~ ^(v[0-9]+\.[0-9]+\.[0-9]+|build-[0-9]+)$ ]] || continue
  gh release delete "$old" --repo "$GITHUB_REPOSITORY" --yes --cleanup-tag
  echo "op=release phase=pruned tag=$old"
done
