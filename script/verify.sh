#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/script/requirements-authority-check.sh"
"$ROOT_DIR/script/requirements-authority-check.sh" self-test
"$ROOT_DIR/script/check-no-unchecked-sendable.sh"
for guard_script in \
  guard-unsandboxed.sh guard-single-main-window.sh guard-view-passivity.sh \
  guard-no-audio.sh guard-no-writes-into-media.sh guard-smoke-run-busy.sh \
  guard-design-system.sh; do
  "$ROOT_DIR/script/$guard_script"
  "$ROOT_DIR/script/$guard_script" self-test
done
"$ROOT_DIR/script/check-doc-citations.sh"
"$ROOT_DIR/script/lint.sh"
"$ROOT_DIR/script/build.sh"
"$ROOT_DIR/script/test.sh"
