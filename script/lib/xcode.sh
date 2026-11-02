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

# The build settings the verification build (script/build.sh) and the benchmark
# build (script/bench.sh) both pass. They build into the same build/DerivedData,
# so they must agree: any difference makes each one rebuild everything the other
# built. ADR 0044 holds the measurements behind each setting.
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
}
