#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/script/requirements-authority-check.sh"

# self-test costs as much as the real run (~15.5s) with identical output
# every time; only worth paying again when the checker itself might have
# changed. requirements-authority-check.sh#self-test - re-run manually after
# editing that script outside a normal branch diff (e.g. a dirty checkout
# with no meaningful base ref).
authority_check_changed=1
if base_ref="$(git -C "$ROOT_DIR" rev-parse --verify origin/main 2>/dev/null)"; then
  if git -C "$ROOT_DIR" diff --quiet "$base_ref" -- script/requirements-authority-check.sh 2>/dev/null; then
    authority_check_changed=0
  fi
fi
if [[ "$authority_check_changed" == "1" ]]; then
  "$ROOT_DIR/script/requirements-authority-check.sh" self-test
fi

# Guards, lint, and doc-citations share nothing with xcodebuild - run them
# while build-for-testing compiles instead of after it.
run_static_gates() {
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
}

run_static_gates &
static_gates_pid=$!

"$ROOT_DIR/script/build.sh"

wait "$static_gates_pid"

"$ROOT_DIR/script/test.sh"
