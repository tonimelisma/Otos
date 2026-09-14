#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Tool versions have one home: the Brewfile pins. `brew bundle` does not enforce a
# formula's version — it reports "Using swiftformat" for whatever is already on the
# machine — so a runner image that ships a different SwiftFormat lints against
# different rules than the one the tree was written for, and the first sign is a
# red `main` on a doc-only merge. Refusing to lint with the wrong version makes the
# drift the reported fault, in one greppable line, instead of whichever rule
# happened to differ.
pinned_version() {
  local tool="$1"
  sed -nE "s/^brew \"${tool}\", version: \"([^\"]+)\".*/\\1/p" "$ROOT_DIR/Brewfile"
}

require_tool() {
  local tool="$1"
  local found="$2"
  local expected
  expected="$(pinned_version "$tool")"
  if [[ -z "$expected" ]]; then
    echo "op=lint.toolVersion tool=$tool expected=unpinned — add a version to the Brewfile" >&2
    exit 1
  fi
  if [[ "$found" != "$expected" ]]; then
    echo "op=lint.toolVersion tool=$tool expected=$expected found=$found — install the pinned version (brew bundle, or script/ci-install-lint-tools.sh on a runner)" >&2
    exit 1
  fi
  echo "op=lint.toolVersion tool=$tool version=$found"
}

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "swiftformat is required. Install tools with: brew bundle" >&2
  exit 127
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint is required. Install tools with: brew bundle" >&2
  exit 127
fi

require_tool swiftformat "$(swiftformat --version)"
require_tool swiftlint "$(swiftlint version)"

swiftformat --lint "$ROOT_DIR"
# No --strict: warnings (e.g. the soft size limits) are informational and must not
# fail the build; swiftlint still exits non-zero on any error-severity violation.
swiftlint lint --config "$ROOT_DIR/.swiftlint.yml"
