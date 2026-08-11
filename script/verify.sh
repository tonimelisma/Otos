#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/script/requirements-authority-check.sh"
"$ROOT_DIR/script/requirements-authority-check.sh" self-test
"$ROOT_DIR/script/check-no-unchecked-sendable.sh"
"$ROOT_DIR/script/check-doc-citations.sh"
"$ROOT_DIR/script/lint.sh"
"$ROOT_DIR/script/build.sh"
"$ROOT_DIR/script/check-production-data-untouched.sh" --before
# Ensure --after runs even if test.sh fails (set -e would otherwise skip it).
set +e
"$ROOT_DIR/script/test.sh"
test_status=$?
set -e
"$ROOT_DIR/script/check-production-data-untouched.sh" --after
exit $test_status
