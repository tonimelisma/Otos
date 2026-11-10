#!/usr/bin/env bash
set -euo pipefail

# Prints the absolute path of the pinned SwiftFormat or SwiftLint binary, fetching
# it first if this machine does not have it yet:
#
#   script/lint-tools.sh swiftformat
#   script/lint-tools.sh swiftlint
#
# This file is the one home for the lint tools' versions. Neither Homebrew nor a
# runner image can pin them: `brew bundle` accepts whatever version is installed,
# a runner image update turned `main` red without a source change, and Homebrew
# upgrades past a pin. So the scripts that lint (`script/lint.sh`,
# `script/check.sh`) call this and run the binary at the path it prints. They never
# take the tool from PATH, so the same bytes lint on every machine.
#
# Each binary comes from its project's GitHub release, is accepted only if the
# archive matches the SHA-256 recorded here, and is kept in a per-user cache keyed
# by version. Several worktrees run checks at once, so the first fetch unpacks into
# a private directory and renames it into place. The rename is atomic: a reader sees
# either no tool directory or a complete one, and losing the race just discards a
# duplicate download.

SWIFTFORMAT_VERSION="0.62.1"
SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip"
SWIFTFORMAT_SHA256="7cb1cb1fae04932047c7015441c543848e8e60e1572d808d080e0a1f1661114a"

SWIFTLINT_VERSION="0.65.0"
SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
SWIFTLINT_SHA256="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6"

CACHE_ROOT="${OTOS_LINT_TOOLS_CACHE:-$HOME/Library/Caches/net.melisma.Otos.lint-tools}"

tool="${1:-}"
case "$tool" in
  swiftformat) version="$SWIFTFORMAT_VERSION" url="$SWIFTFORMAT_URL" sha256="$SWIFTFORMAT_SHA256" ;;
  swiftlint) version="$SWIFTLINT_VERSION" url="$SWIFTLINT_URL" sha256="$SWIFTLINT_SHA256" ;;
  *)
    echo "usage: script/lint-tools.sh swiftformat|swiftlint" >&2
    exit 2
    ;;
esac

tool_dir="$CACHE_ROOT/$tool-$version"
binary="$tool_dir/$tool"
if [[ -x "$binary" ]]; then
  echo "$binary"
  exit 0
fi

mkdir -p "$CACHE_ROOT"
staging="$(mktemp -d "$CACHE_ROOT/.$tool-$version.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
curl -fsSL --retry 3 -o "$staging/archive.zip" "$url"
actual="$(shasum -a 256 "$staging/archive.zip" | cut -d' ' -f1)"
if [[ "$actual" != "$sha256" ]]; then
  echo "op=lint.tools phase=checksumMismatch tool=$tool version=$version expected=$sha256 actual=$actual url=$url" >&2
  exit 1
fi
unzip -oq "$staging/archive.zip" "$tool" -d "$staging"
rm "$staging/archive.zip"
chmod +x "$staging/$tool"
# rename(2), not `mv`: `mv` onto an existing directory moves the source inside it,
# whereas rename fails with ENOTEMPTY when another run got there first.
if perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$staging" "$tool_dir"; then
  echo "op=lint.tools phase=installed tool=$tool version=$version dir=$tool_dir" >&2
elif [[ ! -x "$binary" ]]; then
  echo "op=lint.tools phase=installFailed tool=$tool version=$version dir=$tool_dir" >&2
  exit 1
fi
echo "$binary"
