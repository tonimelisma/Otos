#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The pinned binaries, by absolute path, never from PATH: `script/lint-tools.sh`
# owns the versions and fetches what is missing, so every machine lints with the
# same rules the tree was written for.
SWIFTFORMAT="$("$ROOT_DIR/script/lint-tools.sh" swiftformat)"
SWIFTLINT="$("$ROOT_DIR/script/lint-tools.sh" swiftlint)"
echo "op=lint.toolVersion tool=swiftformat version=$("$SWIFTFORMAT" --version)"
echo "op=lint.toolVersion tool=swiftlint version=$("$SWIFTLINT" version)"

"$SWIFTFORMAT" --lint "$ROOT_DIR"
# No --strict: warnings (e.g. the soft size limits) are informational and must not
# fail the build; swiftlint still exits non-zero on any error-severity violation.
"$SWIFTLINT" lint --config "$ROOT_DIR/.swiftlint.yml"

# The pinned Linux SwiftLint is the static build, which cannot load SourceKit
# (script/lint-tools.sh), so in a cloud session or the Ubuntu CI job it skips every enabled
# rule that needs it: `statement_position`, and all of `custom_rules`, since some of them
# match by syntax kind. SwiftLint says so only on an uncached run, so one file is linted
# uncached to read which rules it skipped, and the run names them: a pass there is partial.
# The macOS build-and-test CI job checks them (AGENTS.md, "Cloud Sessions").
skipped="$("$SWIFTLINT" lint --no-cache --quiet --config "$ROOT_DIR/.swiftlint.yml" "$ROOT_DIR/OtosKit/OtosApp.swift" 2>&1 >/dev/null \
  | sed -n "s/.*Skipping enabled rule '\([^']*\)' because it requires SourceKit.*/\1/p" | sort -u | paste -sd, -)" || true
if [[ -n "$skipped" ]]; then
  echo "op=lint.partial reason=noSourceKit skippedRules=$skipped checkedBy=macOSBuildAndTestJob"
fi
