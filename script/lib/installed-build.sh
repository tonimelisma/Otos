#!/usr/bin/env bash
# The installed app's build (ADR 0030): one recipe for script/install.sh, which builds and
# installs on the Mac, and script/release.sh, which builds each green main commit on CI for
# Sparkle (ADR 0059). Sourced.
#
# The Debug configuration compiled with -O, with the product identity: Debug keeps
# get-task-allow (lldb and xctrace attach) and every `#if DEBUG` diagnostic; -O makes the
# window's own Swift work about ten times faster than unoptimized (ADR 0030). A plain build,
# not `xcodebuild archive`, which strips get-task-allow. CFBundleVersion is the commit
# count, which grows with every commit on main: Sparkle compares it.

# Builds the installed app of the checkout at <root> into <derived data>; extra xcodebuild
# build settings follow (release.sh's signing and dSYM). Prints nothing of its own; the app
# is at "$(otos_installed_build_app <derived data>)".
otos_build_installed_app() {
  local root="$1" derived="$2"
  shift 2
  # OTOS_BUNDLE_ID_SUFFIX empty = the product identity (dev builds use .dev). Xcode 27
  # enables code coverage for Debug by default; an instrumented binary writes
  # default.profraw into its working directory on every quit.
  xcodebuild \
    -project "$root/Otos.xcodeproj" \
    -scheme Otos \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$derived" \
    OTOS_BUNDLE_ID_SUFFIX= \
    ENABLE_CODE_COVERAGE=NO \
    ENABLE_DEBUG_DYLIB=NO \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    CURRENT_PROJECT_VERSION="$(git -C "$root" rev-list --count HEAD)" \
    "$@" \
    build
}

otos_installed_build_app() {
  echo "$1/Build/Products/Debug/Otos.app"
}

# The checks every installed build passes before it is installed or published: the product
# identity, a valid signature over everything in the bundle, and get-task-allow.
otos_check_installed_build() {
  local app="$1" built_id
  built_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")"
  [[ "$built_id" == "net.melisma.Otos" ]] || { echo "Built bundle id is $built_id, expected net.melisma.Otos" >&2; return 1; }
  /usr/bin/codesign --verify --deep --strict "$app" || return 1
  /usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "get-task-allow" \
    || { echo "Built app lacks get-task-allow; debugger and Instruments could not attach." >&2; return 1; }
}
