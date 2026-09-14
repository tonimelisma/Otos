#!/usr/bin/env bash
set -euo pipefail

# Installs the exact SwiftFormat and SwiftLint the Brewfile pins, from their GitHub
# release binaries, and puts them first on the runner's PATH. `brew bundle` cannot
# do this: it accepts whatever version the runner image already ships, which is
# how a macOS image update turned `main` red without a source change. The version
# is read from the Brewfile so the pin keeps one home; `script/lint.sh` then
# re-asserts it before linting.
#
# Runner-only: locally, `brew bundle` plus the assertion in `script/lint.sh` is the
# path. Requires `GITHUB_PATH` (set by GitHub Actions).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${RUNNER_TEMP:-/tmp}/otos-lint-tools"

pinned_version() {
  local tool="$1"
  sed -nE "s/^brew \"${tool}\", version: \"([^\"]+)\".*/\\1/p" "$ROOT_DIR/Brewfile"
}

install_zip() {
  local tool="$1"
  local url="$2"
  local binary="$3"
  local archive="$TOOLS_DIR/$tool.zip"
  curl -fsSL --retry 3 -o "$archive" "$url"
  unzip -oq "$archive" "$binary" -d "$TOOLS_DIR"
  chmod +x "$TOOLS_DIR/$binary"
  rm -f "$archive"
}

if [[ -z "${GITHUB_PATH:-}" ]]; then
  echo "script/ci-install-lint-tools.sh is for GitHub Actions runners; locally run: brew bundle" >&2
  exit 1
fi

mkdir -p "$TOOLS_DIR"
swiftformat_version="$(pinned_version swiftformat)"
swiftlint_version="$(pinned_version swiftlint)"
[[ -n "$swiftformat_version" && -n "$swiftlint_version" ]] || {
  echo "op=lint.toolVersion tool=unknown expected=unpinned — the Brewfile must pin swiftformat and swiftlint" >&2
  exit 1
}

install_zip swiftformat \
  "https://github.com/nicklockwood/SwiftFormat/releases/download/${swiftformat_version}/swiftformat.zip" \
  swiftformat
install_zip swiftlint \
  "https://github.com/realm/SwiftLint/releases/download/${swiftlint_version}/portable_swiftlint.zip" \
  swiftlint

echo "$TOOLS_DIR" >> "$GITHUB_PATH"
echo "op=ci.lintTools phase=installed dir=$TOOLS_DIR swiftformat=$("$TOOLS_DIR/swiftformat" --version) swiftlint=$("$TOOLS_DIR/swiftlint" version)"
