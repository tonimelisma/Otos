#!/usr/bin/env bash
# THE single entry point for verifying a change. Do not invoke script/verify.sh,
# script/test.sh or script/build.sh directly — script/hooks/guard-long-checks.sh
# denies that and points here.
#
# Why one script: the pieces have to run in a particular order (seconds-long gates
# before the multi-minute build, so a formatting nit never costs a full cycle), and
# the long ones have to be supervised rather than awaited. A hung process never
# completes, so it never reports, and an agent waiting on completion waits forever —
# once for 9 h 40 m. This script therefore prints a heartbeat every 60 s carrying
# elapsed time and the running test count, so a stall is visible by reading one file
# and never has to be inferred.
#
# It does not kill anything. A wall-clock limit would destroy a legitimately slow run
# and hide the defect; a suite that hangs has a defect, and the heartbeat is what
# surfaces it (AGENTS.md, "Supervising long checks").
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEARTBEAT_SECONDS="${OTOS_CHECK_HEARTBEAT_SECONDS:-60}"
STARTED_AT="$(date +%s)"

# Killing this script must not strand its children. Terminating the parent alone
# leaves `test.sh` and `xcodebuild` orphaned at PPID 1, and an orphan competing
# against the same build/DerivedData is itself a cause of the suite deadlock this
# heartbeat exists to surface.
cleanup_children() {
  local child
  for child in $(pgrep -P $$ 2>/dev/null); do
    pkill -TERM -P "$child" 2>/dev/null || true
    kill -TERM "$child" 2>/dev/null || true
  done
  pkill -TERM -f "Xcode/Agents/xctest" 2>/dev/null || true
}
trap 'cleanup_children; exit 130' INT TERM

banner() {
  cat <<'MSG'
────────────────────────────────────────────────────────────────────────
script/check.sh — run this with run_in_background: true, then CHECK ON IT
EVERY 60 SECONDS by reading the tail of this log.

Each heartbeat line reads:
    op=check.heartbeat elapsed=MM:SS stage=<stage> tests=<count>

  • tests= climbing            → healthy, keep working, look again in 60 s
  • tests= unchanged 3x        → HUNG. Do not wait it out.
                                 sample <xctest pid>, and diff this log's
                                 test-name list against a complete run's to
                                 find which tests never reported.
  • no heartbeat at all        → the script itself died; read the tail.

Normal total is about 7 minutes: ~4 to build, ~3 for ~810 tests.
Verification evidence counts ONLY from a run that measured the final tree —
edit anything, even a comment, and this result no longer proves it.
────────────────────────────────────────────────────────────────────────
MSG
}

banner

# ── Stage 1: the seconds-long gates, first, so a nit never costs a build ──────
echo "op=check.stage phase=start stage=fast-gates"
fast_failed=0
if ! swiftformat --lint "$ROOT_DIR" 2>&1 | tail -3; then fast_failed=1; fi
if swiftformat --lint "$ROOT_DIR" 2>&1 | grep -q "require formatting"; then
  if ! swiftformat --lint "$ROOT_DIR" 2>&1 | grep -q "^0/"; then
    echo "op=check.stage phase=fail stage=fast-gates reason=formatting" >&2
    echo "Run: swiftformat . — then re-run script/check.sh" >&2
    fast_failed=1
  fi
fi
if [[ "$fast_failed" != "0" ]]; then
  echo "check: FAILED at fast-gates (cost you seconds, not a build)" >&2
  exit 1
fi
echo "op=check.stage phase=pass stage=fast-gates"

# ── Stage 2: the real check, with a heartbeat so a stall is self-evident ─────
echo "op=check.stage phase=start stage=verify"
VERIFY_LOG="$(mktemp)"
"$ROOT_DIR/script/verify.sh" > "$VERIFY_LOG" 2>&1 &
verify_pid=$!

started_at="$(date +%s)"
while kill -0 "$verify_pid" 2>/dev/null; do
  sleep "$HEARTBEAT_SECONDS"
  kill -0 "$verify_pid" 2>/dev/null || break
  elapsed=$(( $(date +%s) - started_at ))
  # Only a log created *after* this run started. `ls -t | head -1` picks the
  # previous run's finished log while this one is still building, reporting a
  # frozen count from old work — which reads exactly like the hang this heartbeat
  # is here to detect.
  newest_test_log="$(find "$ROOT_DIR/logs" -name '*test*.log' -newermt "@$STARTED_AT" 2>/dev/null | head -1)"
  if [[ -n "$newest_test_log" ]]; then
    stage="testing"
    tests="$(grep -c 'passed on' "$newest_test_log" 2>/dev/null || echo 0)"
  else
    stage="building"
    tests="n/a"
  fi
  printf 'op=check.heartbeat elapsed=%02d:%02d stage=%s tests=%s\n' \
    $((elapsed / 60)) $((elapsed % 60)) "$stage" "$tests"
done

wait "$verify_pid"
verify_status=$?
cat "$VERIFY_LOG"
rm -f "$VERIFY_LOG"

if [[ "$verify_status" == "0" ]]; then
  echo "check: PASSED — evidence is valid only for the tree as it stands right now"
else
  echo "check: FAILED — read the stage line above; do not re-run until it is fixed" >&2
fi
exit "$verify_status"
