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

# `--only <Suite>` (repeatable) runs every gate and the full build but only the
# named test suites: feedback while iterating on one area. It is never
# verification evidence — the final tree still needs a run with no arguments.
OTOS_ONLY_TESTING=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      [[ -n "${2:-}" ]] || { echo "usage: script/check.sh [--only <TestSuite>]..." >&2; exit 2; }
      OTOS_ONLY_TESTING="${OTOS_ONLY_TESTING:+$OTOS_ONLY_TESTING }OtosTests/${2#OtosTests/}"
      shift 2
      ;;
    *)
      echo "usage: script/check.sh [--only <TestSuite>]..." >&2
      exit 2
      ;;
  esac
done
export OTOS_ONLY_TESTING

# Killing this script must not strand its children. Terminating the parent alone
# leaves `test.sh` and `xcodebuild` orphaned at PPID 1, and an orphan competing
# against the same build/DerivedData is itself a cause of the suite deadlock this
# heartbeat exists to surface.
#
# Everything this script acts on is found by walking its *own* process tree.
# `xctest` is a child of `xcodebuild`, so the walk reaches it. A machine-wide
# `pgrep -f xctest` instead adopts another worktree's run: it counted that run's
# CPU as this run's liveness, sampled the wrong test host, and killed it on exit.
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

# This run's processes whose command line matches an extended regex, one per line.
own_pids_matching() {
  local pid
  for pid in $(descendants $$); do
    ps -o command= -p "$pid" 2>/dev/null | grep -qE "$1" && echo "$pid"
  done
}

cleanup_children() {
  local pids
  pids="$(descendants $$)"
  # shellcheck disable=SC2086
  [[ -n "$pids" ]] && kill -TERM $pids 2>/dev/null
  return 0
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
                                 xcrun swift-inspect dump-concurrency <xctest
                                 pid> names the parked test and the await it
                                 is parked in (it can take ~40 s).
  • no heartbeat at all        → the script itself died; read the tail.

A deadlock detector runs inside this script. It watches CPU *consumed* by the test
host: a blocked process burns none while its wall clock advances, a slow one burns
plenty. Only when CPU has not moved for OTOS_CHECK_STALL_SECONDS (default 420) does
it sample the parked threads, dump the parked tests' async backtraces, kill its
children and exit non-zero. A quiet log is never enough — one long test can log
nothing while working, and killing on silence is a timeout, not detection.

Normal total is about 2 minutes: under 1 to build from the shared compilation
cache, about 1 to run the suite. A build the cache cannot serve (new toolchain or
build settings) costs a clean build, a few minutes.
Verification evidence counts ONLY from a run that measured the final tree —
edit anything, even a comment, and this result no longer proves it.
────────────────────────────────────────────────────────────────────────
MSG
}

banner
# The tree this run measures, read before any gate does. Another session can pull into
# a shared checkout mid-run; a result that measured two trees proves neither.
source "$ROOT_DIR/script/lib/build-folder.sh"
MEASURED_TREE="$(otos_tree_identity "$ROOT_DIR")" || { echo "check: FAILED — could not read the tree identity" >&2; exit 1; }
echo "op=check.tree phase=start tree=$MEASURED_TREE"
if [[ -n "$OTOS_ONLY_TESTING" ]]; then
  echo "op=check.scope tests=\"$OTOS_ONLY_TESTING\" evidence=no — a scoped run; the final tree needs script/check.sh with no arguments"
fi

# ── Stage 1: the seconds-long gates, first, so a nit never costs a build ──────
echo "op=check.stage phase=start stage=fast-gates"
fast_failed=0
# The pinned SwiftFormat by path, never from PATH (script/lint-tools.sh owns the pin).
if ! SWIFTFORMAT="$("$ROOT_DIR/script/lint-tools.sh" swiftformat)"; then
  echo "check: FAILED at fast-gates — the pinned SwiftFormat could not be fetched" >&2
  exit 1
fi
# One pass over the tree: its exit status is the verdict, its tail the evidence.
if ! "$SWIFTFORMAT" --lint "$ROOT_DIR" 2>&1 | tail -3; then
  echo "op=check.stage phase=fail stage=fast-gates reason=formatting" >&2
  echo "Run: \"\$(script/lint-tools.sh swiftformat)\" . — then re-run script/check.sh" >&2
  fast_failed=1
fi
# Every wait on time names why nothing could report the fact instead (ADR 0033).
if ! "$ROOT_DIR/script/time-guard.sh"; then
  echo "op=check.stage phase=fail stage=fast-gates reason=untaggedTime" >&2
  fast_failed=1
fi
if [[ "$fast_failed" != "0" ]]; then
  echo "check: FAILED at fast-gates (cost you seconds, not a build)" >&2
  exit 1
fi
echo "op=check.stage phase=pass stage=fast-gates"

# ── Stage 2: the real check, with a heartbeat so a stall is self-evident ─────
# One run per build folder: a bench or a second check in this checkout waits here, before
# the deadlock detector starts, and says whom it waits for.
otos_hold_build_folder "$ROOT_DIR/build/DerivedData" check || exit 1
echo "op=check.stage phase=start stage=verify"
VERIFY_LOG="$(mktemp)"
"$ROOT_DIR/script/verify.sh" > "$VERIFY_LOG" 2>&1 &
verify_pid=$!

# Deadlock detection, not a timeout. The distinction matters: a log going quiet is
# not evidence of a hang — one long test can log nothing for minutes while working
# perfectly — so killing on "no output for N seconds" is a kill timeout with better
# marketing, and it destroys exactly the slow-but-healthy runs it must not touch.
#
# The signal that actually separates the two is CPU: a blocked process consumes no
# CPU time while its wall clock keeps advancing. A slow one burns CPU throughout.
# So this compares consumed CPU across samples and only acts when it has genuinely
# stopped, then samples the parked threads to say *what* it is blocked on.
STALL_SECONDS="${OTOS_CHECK_STALL_SECONDS:-420}"
# CPU-seconds per wall minute the test host must consume to count as alive. A parked
# poller measured 0.18; one busy core is 60. Anything in between is not a real mode.
MIN_CPU_SECONDS_PER_MINUTE="${OTOS_CHECK_MIN_CPU_PER_MINUTE:-5}"
last_cpu_change_at="$(date +%s)"
cpu_at_mark=0
last_cpu=""

# Total CPU seconds consumed by this run's whole process tree: xcodebuild, the build
# service and every compiler and linker it starts, and the test host. The build's
# CPU is spent in short-lived `swift-frontend` children of `SWBBuildService`, two
# levels below xcodebuild, and `ps -o time=` never includes a process's children.
# Counting xcodebuild and the test host alone therefore read 3 CPU-s across a
# 10-minute build under load and killed it as deadlocked. `ps` also forgets a
# process once it exits, so each process's highest reading is kept in a ledger for
# the run, and the total is the sum over every process this run has seen: it only
# grows, and a compiler that lived between two samples still counts for what the
# sample before its exit saw.
# macOS `ps -o time=` prints [[dd-]hh:]mm:ss.cc — a *fractional* field. Bash
# arithmetic is integer-only, so summing it in the shell failed on every sample
# ("10.09: syntax error"), left this returning a constant, and turned the liveness
# check into a 420 s kill timer that would fire on a healthy run: the precise
# failure mode measuring CPU exists to avoid. The whole sum stays in awk.
CPU_LEDGER="$(mktemp)"
consumed_cpu() {
  local pids
  pids="$(descendants $$ | tr '\n' ',')"
  pids="${pids%,}"
  # The day field is days, not another sexagesimal digit: splitting on [:-] alone
  # would score `2-03:04:05` as 2*60 rather than 2*86400.
  { [[ -n "$pids" ]] && ps -o pid=,time= -p "$pids" 2>/dev/null; } \
    | awk -v ledger="$CPU_LEDGER" '
        function seconds(t,   d, p, q, n, i, s) {
          d = 0
          if (index(t, "-")) { split(t, p, "-"); d = p[1]; t = p[2] }
          n = split(t, q, ":"); s = 0
          for (i = 1; i <= n; i++) s = s * 60 + q[i]
          return d * 86400 + s
        }
        BEGIN { while ((getline line < ledger) > 0) { split(line, f, " "); seen[f[1]] = f[2] } close(ledger) }
        { v = seconds($2); if (v > seen[$1]) seen[$1] = v }
        END {
          printf "" > ledger
          for (p in seen) { total += seen[p]; print p, seen[p] > ledger }
          printf "%d\n", total
        }'
}

# The parked tests, by name, with the await each one is parked in. `sample` shows
# OS threads, and a parked Swift-concurrency test owns none — it is a suspended
# task on an idle pool, so the threads read as nothing. The task's async backtrace
# is where the test function and its `waitUntil` appear, and swift-inspect reads it.
# "Last test to report" is not this: under parallel execution it names whichever
# unrelated test happened to finish last.
#
# The bound below limits only the diagnostic, which runs against a host already
# measured as parked; it never limits test work. It exists so a wedged inspector
# cannot turn the stall report itself into the unbounded wait it is reporting on.
INSPECT_SECONDS="${OTOS_CHECK_INSPECT_SECONDS:-180}"
report_parked_tests() {
  local pid="$1" dump inspect_pid waited=0
  mkdir -p "$ROOT_DIR/logs"
  dump="$ROOT_DIR/logs/check-$(date -u +%Y%m%dT%H%M%SZ)-p$$-concurrency.log"
  xcrun swift-inspect dump-concurrency "$pid" > "$dump" 2>&1 &
  inspect_pid=$!
  while kill -0 "$inspect_pid" 2>/dev/null && (( waited < INSPECT_SECONDS )); do
    # time: deadline — a wedged swift-inspect must not become the hang it reports
    sleep 1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$inspect_pid" 2>/dev/null; then
    kill -TERM "$inspect_pid" 2>/dev/null
    echo "op=check.stall phase=inspect-incomplete pid=$pid waitedSeconds=$waited dump=$dump" >&2
  fi
  wait "$inspect_pid" 2>/dev/null
  echo "--- parked tests in xctest $pid (OtosTests frames, innermost first; full dump: $dump) ---" >&2
  # One `Task N:` heading per task that has OtosTests frames, then those frames.
  # Thunks, partial applies and the macro-generated `$s…` entry points restate
  # the test function they wrap, so they are dropped.
  awk '
    /Task [0-9]+ - flags=/ { match($0, /Task [0-9]+/); task = substr($0, RSTART, RLENGTH); shown = 0; next }
    / in OtosTests$/ && !/resume function:|thunk for|partial apply|implicit closure|\$s[0-9]/ {
      frame = $0; sub(/^.*async backtrace: /, "", frame); sub(/^[ \t]+/, "", frame)
      if (!shown) { print task ":"; shown = 1 }
      print "  " frame; found = 1
    }
    END {
      # Parked with no test task means the host never reached our code — the
      # pre-test stall in docs/research/2026-09-01-xctest-host-stalls-before-running-tests.md.
      if (!found) print "none — no OtosTests task is parked; the host is stalled outside test code"
    }' "$dump" >&2
}

# script/test.sh prints this, then the log path, before xcodebuild starts.
TEST_LOG_ANNOUNCEMENT="Capturing test output to "
# A test case that finished either way. Counting only passes froze tests= at the
# first failure, which reads like the hang the counter exists to reveal.
TEST_FINISHED_PATTERN="' (passed|failed) on '"

started_at="$(date +%s)"
while kill -0 "$verify_pid" 2>/dev/null; do
  # time: schedule — the heartbeat a watcher reads; it ends with the run, never bounds it
  sleep "$HEARTBEAT_SECONDS"
  kill -0 "$verify_pid" 2>/dev/null || break
  elapsed=$(( $(date +%s) - started_at ))
  # The test log is the one test.sh announces on its first line of output, which
  # lands in VERIFY_LOG. Reading the announcement replaces guessing which file in
  # logs/ belongs to this run: by mtime it took the previous run's frozen log, and
  # by `find -newermt "@epoch"` it took nothing at all — BSD find cannot parse that
  # date, the error went to /dev/null, and every heartbeat of a hung test phase
  # read `stage=building tests=n/a`.
  test_log="$(sed -n "s/^${TEST_LOG_ANNOUNCEMENT}//p" "$VERIFY_LOG" 2>/dev/null | head -1)"
  if [[ -n "$test_log" ]]; then
    stage="testing"
    tests="$(grep -cE "$TEST_FINISHED_PATTERN" "$test_log" 2>/dev/null)"
    tests="${tests:-0}"
  else
    stage="building"
    tests="n/a"
  fi
  cpu="$(consumed_cpu)"
  printf 'op=check.heartbeat elapsed=%02d:%02d stage=%s tests=%s cpuSeconds=%s\n' \
    $((elapsed / 60)) $((elapsed % 60)) "$stage" "$tests" "$cpu"

  # Consumed CPU is the liveness signal, but *rate* is the signal — not inequality.
  # A parked test host still burns a trickle: XCTWaiter polls while it waits, so its
  # CPU seconds keep ticking up by ones. Comparing against the previous sample let
  # every one of those ticks reset the window, and a real deadlock ran 17 minutes
  # without ever being detected (CPU 17s -> 19s across 11 minutes, ~0.18 s/min).
  # Real work — one slow test on one core — consumes ~60 s/min, three orders of
  # magnitude above that, so requiring a floor separates parked from slow safely.
  cpu_delta=$(( cpu - cpu_at_mark ))
  since_mark=$(( $(date +%s) - last_cpu_change_at ))
  if (( since_mark > 0 && cpu_delta * 60 >= since_mark * MIN_CPU_SECONDS_PER_MINUTE )); then
    last_cpu="$cpu"
    cpu_at_mark="$cpu"
    last_cpu_change_at="$(date +%s)"
  elif [[ $(( $(date +%s) - last_cpu_change_at )) -ge "$STALL_SECONDS" ]]; then
    echo "op=check.stall phase=detected elapsed=$((elapsed / 60))m stage=$stage tests=$tests cpuSeconds=$cpu blockedFor=$(( ($(date +%s) - last_cpu_change_at) / 60 ))m" >&2
    for xctest_pid in $(own_pids_matching "Xcode/Agents/xctest"); do
      # The excerpt is for reading here; the whole sample is kept because the thread
      # that matters (the main thread draining MainActor jobs, or not) is often not
      # among the matching lines.
      mkdir -p "$ROOT_DIR/logs"
      sample_log="$ROOT_DIR/logs/check-$(date -u +%Y%m%dT%H%M%SZ)-p$$-sample.log"
      sample "$xctest_pid" 2 -mayDie > "$sample_log" 2>/dev/null || true
      echo "--- parked threads of xctest $xctest_pid (full sample: $sample_log) ---" >&2
      grep -m 25 -E "Otos|XCTWaiter|semaphore|Mutex|dispatch" "$sample_log" >&2 || true
      report_parked_tests "$xctest_pid"
    done
    echo "check: DEADLOCKED — consumed under ${MIN_CPU_SECONDS_PER_MINUTE} CPU-s/min for ${STALL_SECONDS}s while still running. Killed so this reports instead of hanging." >&2
    cleanup_children
    cat "$VERIFY_LOG" 2>/dev/null
    rm -f "$VERIFY_LOG" "$CPU_LEDGER"
    exit 1
  fi
done

wait "$verify_pid"
verify_status=$?
cat "$VERIFY_LOG"
rm -f "$VERIFY_LOG" "$CPU_LEDGER"

final_tree="$(otos_tree_identity "$ROOT_DIR")" || final_tree="unreadable"
if [[ "$verify_status" == "0" && "$final_tree" != "$MEASURED_TREE" ]]; then
  echo "op=check.tree phase=changed start=$MEASURED_TREE end=$final_tree" >&2
  echo "check: FAILED — the tree changed during the run, so this result describes neither tree; re-run" >&2
  verify_status=1
elif [[ "$verify_status" == "0" && -n "$OTOS_ONLY_TESTING" ]]; then
  echo "check: PASSED (scoped to $OTOS_ONLY_TESTING) — iteration feedback, NOT verification evidence"
elif [[ "$verify_status" == "0" ]]; then
  echo "check: PASSED — evidence is valid only for the tree as it stands right now"
else
  echo "check: FAILED — read the stage line above; do not re-run until it is fixed" >&2
fi
exit "$verify_status"
