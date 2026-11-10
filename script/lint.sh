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
