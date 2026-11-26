#!/usr/bin/env bash
set -euo pipefail

# Prints the absolute path of the pinned SwiftFormat or SwiftLint binary, fetching
# it first if this machine does not have it yet:
#
#   script/lint-tools.sh swiftformat
#   script/lint-tools.sh swiftlint
#   script/lint-tools.sh cache-dir     the folder holding the tools and their lint caches
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

# Each tool has one version and one archive per platform: the macOS build for the Mac,
# the Linux builds for a Claude Code cloud session's x86_64 VM (AGENTS.md, "Cloud
# Sessions") and for an arm64 Linux container on the Mac, which runs them natively.
# `member` is the binary's name inside the archive.
SWIFTFORMAT_VERSION="0.62.1"
SWIFTLINT_VERSION="0.65.0"
platform="$(uname -s)-$(uname -m)"
CACHE_ROOT="${OTOS_LINT_TOOLS_CACHE:-$HOME/Library/Caches/net.melisma.Otos.lint-tools}"

# `script/lint-tools.sh swiftformat-lint <path>...`: the pinned SwiftFormat's lint of the paths,
# one file at a time, the one way `script/lint.sh` and `script/check.sh` run it.
# SwiftFormat abandons a rule that runs past 1 s + tokens/1000 of wall-clock time, and its
# CLI formats every file at once: on a 4-core CI runner the files starved each other, and a
# file whose rules take 5 s in all failed with `docComments rule timed out`. `--verbose` is
# the CLI's only serial mode; one file at a time, a rule's time is its own. Its per-file
# lines are dropped; findings and the summary pass through
# (docs/research/2026-11-25-swiftformat-rule-timeouts.md).
# Its cache lives beside the tools, so CI keeps it with them: a file whose bytes, the
# options and SwiftFormat's version are all unchanged is skipped. Without it a runner that
# starts empty linted every file, 64 s of a CI run (ADR 0044).
if [[ "${1:-}" == swiftformat-lint ]]; then
  binary="$("$0" swiftformat)"
  shift
  [[ $# -gt 0 ]] || { echo "usage: script/lint-tools.sh swiftformat-lint <path>..." >&2; exit 2; }
  "$binary" --lint --verbose --cache "$CACHE_ROOT/swiftformat-lint.cache" "$@" 2>&1 \
    | { grep -vE '^(Linting|Skipping|Reading config file at) |^-- (ignored|no changes( \(cached\))?)$|^Running SwiftFormat\.\.\.$|^\(lint mode' || true; }
  exit "${PIPESTATUS[0]}"
fi

tool="${1:-}"
case "$tool:$platform" in
  swiftformat:Darwin-*)
    version="$SWIFTFORMAT_VERSION" member=swiftformat
    url="https://github.com/nicklockwood/SwiftFormat/releases/download/${version}/swiftformat.zip"
    sha256="7cb1cb1fae04932047c7015441c543848e8e60e1572d808d080e0a1f1661114a" ;;
  swiftformat:Linux-x86_64)
    version="$SWIFTFORMAT_VERSION" member=swiftformat_linux
    url="https://github.com/nicklockwood/SwiftFormat/releases/download/${version}/swiftformat_linux.zip"
    sha256="61ff55f3581e2144a4ad114831167102c38be853df75c1477d20b40a8e8120aa" ;;
  swiftformat:Linux-aarch64)
    version="$SWIFTFORMAT_VERSION" member=swiftformat_linux_aarch64
    url="https://github.com/nicklockwood/SwiftFormat/releases/download/${version}/swiftformat_linux_aarch64.zip"
    sha256="374b1975082970ac17c9b307639dbc0a148656434cd612cff06957e279020f34" ;;
  swiftlint:Darwin-*)
    version="$SWIFTLINT_VERSION" member=swiftlint
    url="https://github.com/realm/SwiftLint/releases/download/${version}/portable_swiftlint.zip"
    sha256="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6" ;;
  swiftlint:Linux-x86_64)
    # The static build: the other binary in a Linux archive needs a Swift runtime the VM lacks.
    version="$SWIFTLINT_VERSION" member=swiftlint-static
    url="https://github.com/realm/SwiftLint/releases/download/${version}/swiftlint_linux_amd64.zip"
    sha256="79306a34e5c7cc55a220cd108cbb861dcad5f10138dcdf261e2624ae8b0a486b" ;;
  swiftlint:Linux-aarch64)
    version="$SWIFTLINT_VERSION" member=swiftlint-static
    url="https://github.com/realm/SwiftLint/releases/download/${version}/swiftlint_linux_arm64.zip"
    sha256="12d3b84bc5b69ae13a99a5a5c79904f9ce25867f099f6368d0037854f9ee6c26" ;;
  cache-dir:*)
    echo "$CACHE_ROOT"
    exit 0 ;;
  swiftformat:* | swiftlint:*)
    echo "op=lint.tools phase=unsupportedPlatform tool=$tool platform=$platform" >&2
    exit 1 ;;
  *)
    echo "usage: script/lint-tools.sh swiftformat|swiftlint" >&2
    exit 2 ;;
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
unzip -oq "$staging/archive.zip" "$member" -d "$staging"
rm "$staging/archive.zip"
[[ "$member" == "$tool" ]] || mv "$staging/$member" "$staging/$tool"
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
