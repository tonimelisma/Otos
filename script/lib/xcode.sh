#!/usr/bin/env bash
set -euo pipefail

OTOS_EXPECTED_XCODE="/Applications/Xcode-beta.app/Contents/Developer"
OTOS_PROJECT_NAME="Otos"

# The Apple team that signs Otos stays out of this public repository: the project file
# reads $(OTOS_DEVELOPMENT_TEAM), which every build script gets from the environment or,
# on the Mac, from ~/.config/otos/development-team (one line, the team ID). Without it a
# build is signed to run locally only, which is enough for tests but not for an install
# that keeps its macOS permissions.
if [[ -z "${OTOS_DEVELOPMENT_TEAM:-}" && -r "${XDG_CONFIG_HOME:-$HOME/.config}/otos/development-team" ]]; then
  OTOS_DEVELOPMENT_TEAM="$(tr -d '[:space:]' < "${XDG_CONFIG_HOME:-$HOME/.config}/otos/development-team")"
fi
export OTOS_DEVELOPMENT_TEAM="${OTOS_DEVELOPMENT_TEAM:-}"

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

  if ! xcodebuild -version >/dev/null 2>&1; then
    cat >&2 <<EOF
xcodebuild is not usable from the selected developer directory:
  $selected

Fix:
  sudo xcode-select --switch $OTOS_EXPECTED_XCODE
EOF
    exit 66
  fi
}

# Every build into a checkout's build/DerivedData goes through here, so each one first
# takes back the models a previous build shared (otos_unshare_built_models, below) before
# Xcode writes there:
#
#   otos_build_checkout <root> verification <xcodebuild option or action...>
#       The builds whose products a test run loads: script/build.sh and script/bench.sh.
#       They pass otos_build_settings and share the models after.
#   otos_build_checkout <root> debuggable <xcodebuild option or action...>
#       script/build_and_run.sh (and so smoke-run.sh, profile.sh and capture-run.sh): an
#       app to run, debug or profile, built with real source paths and none of the
#       verification settings (ADR 0044). Its models stay as built.
#
# The caller holds the build folder (script/lib/build-folder.sh) and redirects the output.
# Returns xcodebuild's status, or the sharing step's when the build passed. Each step is
# checked by status, because a caller may run this in an `||` list, where errexit is off
# for everything it calls.
otos_build_checkout() {
  local root="$1" kind="$2"
  shift 2
  local settings=()
  case "$kind" in
    verification)
      otos_build_settings "$root" || return
      settings=("${OTOS_BUILD_SETTINGS[@]}")
      ;;
    debuggable) ;;
    *)
      echo "op=build phase=refused reason=unknownBuildKind kind=$kind" >&2
      return 2
      ;;
  esac
  otos_unshare_built_models "$root/build/DerivedData"
  # ${settings[@]+...}: bash 3.2 under `set -u` calls an empty array unbound.
  xcodebuild \
    -project "$root/Otos.xcodeproj" \
    -scheme Otos \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$root/build/DerivedData" \
    "$@" ${settings[@]+"${settings[@]}"} || return
  if [[ "$kind" == "verification" ]]; then
    otos_share_built_models "$root"
  fi
}

# The build settings every verification build passes (otos_build_checkout). They build
# into the same build/DerivedData, so any difference between two of them makes each one
# rebuild everything the other built. ADR 0044 holds the measurements behind each setting.
#
# Compilation caching stores every compile job's output in one content-addressed
# store shared by all worktrees, so a fresh worktree's first build replays what
# any other worktree already compiled instead of compiling it again. Prefix
# mapping makes those cache keys independent of where the worktree lives: the
# worktree root becomes /^worktree in every compile job, including the package
# targets, whose own project directory (mapped by the *_PROJECT_PREFIX_MAPPING
# settings) does not contain the compiler's working directory. The store is the
# one Xcode's own builds use with the default DerivedData; concurrent builds share
# it by design, and Xcode prunes it. The *_OTHER_PREFIX_MAPPINGS values are
# space-separated lists, so a checkout path holding a space would silently split
# into a wrong mapping; it is refused instead.
#
# Code coverage is on by default for Debug test builds in Xcode 27 and nothing
# reads it; index-while-building feeds only an IDE, and these builds have none.
otos_build_settings() {
  local root="$1"
  if [[ "$root" == *" "* ]]; then
    echo "op=build.settings phase=refused reason=spaceInCheckoutPath root=$root" >&2
    exit 1
  fi
  OTOS_BUILD_SETTINGS=(
    COMPILATION_CACHE_ENABLE_CACHING=YES
    "COMPILATION_CACHE_CAS_PATH=$HOME/Library/Developer/Xcode/DerivedData/CompilationCache.noindex"
    SWIFT_ENABLE_PREFIX_MAPPING=YES
    SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES
    "SWIFT_OTHER_PREFIX_MAPPINGS=$root=/^worktree"
    CLANG_ENABLE_PREFIX_MAPPING=YES
    CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES
    "CLANG_OTHER_PREFIX_MAPPINGS=$root=/^worktree"
    ENABLE_CODE_COVERAGE=NO
    COMPILER_INDEX_STORE_ENABLE=NO
  )
  otos_seed_source_packages "$root"
}

# Core ML compiles a model on its first load into the loading process's Caches, keyed by
# the model's path exactly as given (ADR 0044 §11): the same bytes at another path compile
# again. Every checkout builds its models into its own DerivedData, and every test process
# shares the test runner's one Caches folder, so each checkout added a compiled copy of each
# model there until macOS pruned it, Vision's own models with it. After a build this moves
# each model of the framework the tests load to `$OTOS_SHARED_MODELS/<source hash>/<name>`
# and leaves a symlink, which `BundledModel` resolves, so every checkout loads one path per
# model version. The name is the hash of the source package's files and the Xcode build,
# not of the compiled model: coremlc writes a different `coremldata.bin` each time it
# compiles the same package. A copy is an APFS clone made in a staging folder, read-only,
# and published by rename(2), which refuses an existing target: of two builds sharing one
# model at once, one publishes and the other uses what it published. The app bundle's copy
# is left as built.
OTOS_SHARED_MODELS="$HOME/Library/Developer/Otos/SharedModels"

# Before a build the links are removed again: the models are Xcode's outputs, and it would
# compile into a link, that is into the shared copy. Compiling all five again costs about
# 6 s of the build.
otos_unshare_built_models() {
  local resources="$1/Build/Products/Debug/OtosKit.framework/Versions/A/Resources"
  local model
  for model in "$resources"/*.mlmodelc; do
    [[ -L "$model" ]] && rm "$model"
  done
  return 0
}

otos_share_built_models() {
  local root="$1"
  local resources="$root/build/DerivedData/Build/Products/Debug/OtosKit.framework/Versions/A/Resources"
  local xcode model name source hash shared staging
  xcode="$(xcodebuild -version | tr '\n' ' ')"
  mkdir -p "$OTOS_SHARED_MODELS"
  for model in "$resources"/*.mlmodelc; do
    [[ -d "$model" && ! -L "$model" ]] || continue
    name="$(basename "$model")"
    source="$root/OtosKit/Resources/${name%.mlmodelc}.mlpackage"
    if [[ ! -d "$source" ]]; then
      echo "op=build.models phase=failed model=$name reason=noSourcePackage source=$source" >&2
      return 1
    fi
    hash="$( { echo "$xcode"; cd "$source" && /usr/bin/find . -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 /usr/bin/shasum -a 256; } | /usr/bin/shasum -a 256 | cut -c1-16)"
    shared="$OTOS_SHARED_MODELS/$hash/$name"
    if [[ ! -d "$shared" ]]; then
      staging="$(mktemp -d "$OTOS_SHARED_MODELS/.staging.XXXXXX")"
      /bin/cp -cR "$model" "$staging/$name"
      # Read-only, so a build that tried to write a model through its symlink would fail
      # instead of changing the copy every checkout loads.
      /bin/chmod -R a-w "$staging/$name"
      /usr/bin/python3 -I -c 'import os, sys
try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError:
    pass' "$staging" "$OTOS_SHARED_MODELS/$hash"
      rm -rf "$staging"
    fi
    if [[ ! -d "$shared" ]]; then
      echo "op=build.models phase=failed model=$name reason=notPublished shared=$shared" >&2
      return 1
    fi
    rm -rf "$model"
    ln -s "$shared" "$model"
    echo "op=build.models phase=shared model=$name hash=$hash"
  done
}

# A new worktree's first build resolves the Swift packages into its own DerivedData, and
# GRDB's SQLite submodule clones over HTTPS, which has hung for minutes (2026-11-12). The
# primary checkout already holds a resolved copy; a worktree that has none starts from it,
# and xcodebuild then resolves the pins against that copy without the network. Each
# worktree keeps its own copy, so no two builds share one package folder.
otos_seed_source_packages() {
  local root="$1" primary packages source
  packages="$root/build/DerivedData/SourcePackages"
  [[ -d "$packages/checkouts" ]] && return
  primary="$(dirname "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)")"
  source="$primary/build/DerivedData/SourcePackages"
  [[ "$primary" != "$root" && -d "$source/checkouts" ]] || return 0
  mkdir -p "$root/build/DerivedData"
  /usr/bin/ditto "$source" "$packages" || return
  echo "op=build.packages phase=seeded from=$source"
}
