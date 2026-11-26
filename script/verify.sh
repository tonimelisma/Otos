#!/usr/bin/env bash
# The one required local check: requirements authority + static gates + build + test.
#
# Every stage runs to completion and reports independently. An earlier stage must
# never *hide* a later one: before 2026-08-21 the static gates were `wait`ed under
# `set -e`, so a SwiftFormat wrap-the-if nit aborted the script before
# `script/test.sh` ever ran, and the exit code could not distinguish a formatting
# miss from five failing tests. Two PRs merged green on that reading.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failed_stages=()

record() {
  local name="$1" status="$2"
  if [[ "$status" != "0" ]]; then
    failed_stages+=("$name")
  fi
}

"$ROOT_DIR/script/requirements-authority-check.sh"
record "requirements-authority-check" "$?"

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
  record "requirements-authority-check#self-test" "$?"
fi

# Each guard's `self-test` proves it can detect a seeded violation, so it
# *deliberately* prints its own `FAIL:` line against a bad oracle. Emitting that
# leaves ~8 expected `FAIL:` lines in the log for a reader to tell apart from a
# real one. Capture it and replay it only when the self-test itself fails.
run_guard_self_test() {
  local script="$1" output status
  output="$("$script" self-test 2>&1)"
  status=$?
  if [[ "$status" != "0" ]]; then
    printf '%s\n' "$output" >&2
  else
    printf '%s\n' "$output" | grep -v '^FAIL:' || true
  fi
  return "$status"
}

# Guards and lint share nothing with xcodebuild - run them
# while build-for-testing compiles instead of after it. The subshell's exit
# status is collected below rather than aborting the script.
# The unchecked-Sendable, doc-citation and design-system checks run once, in
# script/check.sh's fast gates through ci-text-hygiene.sh; only the design-system
# guard's self-test runs here, beside the other guards'.
run_static_gates() {
  local status=0
  for guard_script in \
    guard-unsandboxed.sh guard-single-main-window.sh guard-view-passivity.sh \
    guard-no-audio.sh guard-no-writes-into-media.sh guard-smoke-run-busy.sh \
    guard-presentation-yield.sh; do
    "$ROOT_DIR/script/$guard_script" || status=1
    run_guard_self_test "$ROOT_DIR/script/$guard_script" || status=1
  done
  run_guard_self_test "$ROOT_DIR/script/guard-design-system.sh" || status=1
  "$ROOT_DIR/script/lint.sh" swiftlint || status=1
  return "$status"
}

run_static_gates &
static_gates_pid=$!

# The static tier (script/check.sh decides it from the diff, ADR 0044) changed nothing the
# build or the tests read, so it runs the gates alone and says so.
if [[ "${OTOS_CHECK_TIER:-full}" == "static" ]]; then
  echo "op=verify.stage stage=build phase=skipped reason=staticTier"
  echo "op=verify.stage stage=test phase=skipped reason=staticTier"
  wait "$static_gates_pid"
  record "static-gates" "$?"
  if [[ "${#failed_stages[@]}" -gt 0 ]]; then
    echo "verify: FAILED stages: ${failed_stages[*]}" >&2
    exit 1
  fi
  echo "verify: all stages passed (static tier: no build, no tests)"
  exit 0
fi

"$ROOT_DIR/script/build.sh"
build_status=$?
record "build" "$build_status"

wait "$static_gates_pid"
record "static-gates" "$?"

# test-without-building has nothing to run against if the build failed; skipping
# it is reported as its own stage rather than passing silently.
if [[ "$build_status" == "0" ]]; then
  "$ROOT_DIR/script/test.sh"
  record "test" "$?"
else
  echo "verify: skipping script/test.sh because script/build.sh failed" >&2
  failed_stages+=("test(skipped:build-failed)")
fi

if [[ "${#failed_stages[@]}" -gt 0 ]]; then
  echo "verify: FAILED stages: ${failed_stages[*]}" >&2
  exit 1
fi
echo "verify: all stages passed"
