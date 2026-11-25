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
  • tests= unchanged 3x        → HUNG. Do not wait it out. This script then
                                 prints op=check.hang lines: the test cases
                                 in flight (inFlight, onThread), the main
                                 thread's and each test thread's stack.
                                 mayBeFinished tasks may have returned long
                                 ago: a dump shows a held, finished task as
                                 parked at its last await.
  • no heartbeat at all        → the script itself died; read the tail.

A deadlock detector runs inside this script. It watches CPU *consumed* by the test
host: a blocked process burns none while its wall clock advances, a slow one burns
plenty. Only when CPU has not moved for OTOS_CHECK_STALL_SECONDS (default 420) does
it report the host the same way, kill its
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
# The cores the suite runs on: Swift's cooperative pool is that many threads wide, so a
# test that blocks one costs a larger share of a small runner than of the owner's Mac.
echo "op=check.host cpus=$(sysctl -n hw.activecpu 2> /dev/null || nproc 2> /dev/null || echo unknown) os=$(uname -s)-$(uname -m)"
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
if ! "$ROOT_DIR/script/lint-tools.sh" swiftformat-lint "$ROOT_DIR" 2>&1 | tail -3; then
  echo "op=check.stage phase=fail stage=fast-gates reason=formatting" >&2
  echo "Run: \"\$(script/lint-tools.sh swiftformat)\" . — then re-run script/check.sh" >&2
  fast_failed=1
fi
# Every wait on time names why nothing could report the fact instead (ADR 0033).
if ! "$ROOT_DIR/script/time-guard.sh"; then
  echo "op=check.stage phase=fail stage=fast-gates reason=untaggedTime" >&2
  fast_failed=1
fi
# The app folder holds only the app's three entries; every other file is the framework's
# and lives under OtosKit/ (ADR 0023). Its self-test seeds a stray and a clean folder.
if ! "$ROOT_DIR/script/guard-app-folder.sh" check \
  || ! "$ROOT_DIR/script/guard-app-folder.sh" self-test; then
  echo "op=check.stage phase=fail stage=fast-gates reason=appFolder" >&2
  fast_failed=1
fi
# Every CI job's checks run here too, so a passing check is a passing CI. The text checks
# read a commit, so they read one of the tree as it stands: written from a scratch index
# with untracked files added, which moves nothing in the checkout.
snapshot_dir="$(mktemp -d)"
GIT_INDEX_FILE="$snapshot_dir/index" git -C "$ROOT_DIR" read-tree HEAD
GIT_INDEX_FILE="$snapshot_dir/index" git -C "$ROOT_DIR" add -A
snapshot_tree="$(GIT_INDEX_FILE="$snapshot_dir/index" git -C "$ROOT_DIR" write-tree)"
rm -rf "$snapshot_dir"
snapshot="$(git -C "$ROOT_DIR" commit-tree "$snapshot_tree" -p HEAD -m "check snapshot")"
if ! (cd "$ROOT_DIR" && EVENT_NAME=pull_request BASE_SHA="$(git rev-parse origin/main)" HEAD_SHA="$snapshot" \
  script/ci-text-hygiene.sh check); then
  echo "op=check.stage phase=fail stage=fast-gates reason=textHygiene" >&2
  fast_failed=1
fi
if ! "$ROOT_DIR/script/ci-repo-shape.sh"; then
  echo "op=check.stage phase=fail stage=fast-gates reason=repoShape" >&2
  fast_failed=1
fi
# The scorecard's parser, against synthetic log lines (ADR 0015). The scorecard itself is a
# report and never runs here.
if ! /usr/bin/python3 -I "$ROOT_DIR/script/lib/scorecard_test.py" 2>&1 | tail -3; then
  echo "op=check.stage phase=fail stage=fast-gates reason=scorecardParser" >&2
  fast_failed=1
fi
# The weekly run's status and verdict rules, against stubbed inputs (ADR 0043).
if ! "$ROOT_DIR/script/perf.sh" self-test; then
  echo "op=check.stage phase=fail stage=fast-gates reason=perfRules" >&2
  fast_failed=1
fi
if [[ "$fast_failed" != "0" ]]; then
  echo "check: FAILED at fast-gates (cost you seconds, not a build)" >&2
  exit 1
fi
echo "op=check.stage phase=pass stage=fast-gates"
# What the change can reach decides what proves it (ADR 0044). A tree whose diff from its
# merge base touches only paths the app build and the test suite never read takes the
# static tier: every gate, no build, no tests. Any other path, including one this list
# does not know, takes the full tier, so a path misread costs time, never coverage. A tree
# with no diff takes the full tier too: it is a check of main itself.
check_tier() {
  local base path changed=0
  base="$(git -C "$ROOT_DIR" merge-base origin/main HEAD)"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    changed=1
    case "$path" in
      script/check.sh | script/verify.sh | script/build.sh | script/test.sh | script/lib/*)
        echo full; return ;;
      Otos/* | OtosKit/* | OtosTests/*)
        echo full; return ;;
      docs/* | .github/* | .claude/* | script/* | *.md | .swiftlint.yml | .swiftformat)
        ;;
      *)
        echo full; return ;;
    esac
  # --no-renames lists both sides of a move: with rename detection on (git's default), a
  # file moved out of Otos/ into docs/ lists only its docs/ destination and the tree read
  # as static though the build lost a file.
  done < <(git -C "$ROOT_DIR" diff --no-renames --name-only "$base" "$snapshot")
  if [[ "$changed" == 0 ]]; then echo full; else echo static; fi
}
if [[ -n "$OTOS_ONLY_TESTING" ]]; then
  CHECK_TIER=full
else
  CHECK_TIER="$(check_tier)"
fi
echo "op=check.tier tier=$CHECK_TIER"
# A machine with no Xcode — a Claude Code cloud session's Linux VM — runs every gate but
# can build and test nothing (AGENTS.md, "Cloud Sessions"). A full-tier tree there runs the
# gates the way the static tier does, then fails as incomplete: its build and tests are CI's
# run of this script on GitHub's Xcode 27 runner. A static-tier tree needs neither, so it is verified there in full.
VERIFY_TIER="$CHECK_TIER"
if [[ "$CHECK_TIER" == full ]] && ! command -v xcodebuild > /dev/null 2>&1; then
  VERIFY_TIER=static
  echo "op=check.tier tier=full phase=gatesOnly reason=noXcode host=$(uname -s)-$(uname -m)"
fi
export OTOS_CHECK_TIER="$VERIFY_TIER"

# Performance is measured once a week, by the run the session this line tells starts
# (ADR 0043): it says whether a run is due, running, passed or failed.
"$ROOT_DIR/script/perf.sh" status || true

# ── Stage 2: the real check, with a heartbeat so a stall is self-evident ─────
# One run per build folder: a bench or a second check in this checkout waits here, before
# the deadlock detector starts, and says whom it waits for. The static tier builds nothing,
# so it never touches the folder and never waits for one.
if [[ "$VERIFY_TIER" != "static" ]]; then
  otos_hold_build_folder "$ROOT_DIR/build/DerivedData" check || exit 1
fi
echo "op=check.stage phase=start stage=verify"
VERIFY_LOG="$(mktemp)"
# verify.sh reports its own end: the subshell that runs it writes one line to a pipe this
# script reads the moment verify exits, and exits with verify's status. The heartbeat loop
# below waits on that line, so a finished run is noticed at once rather than at the next
# heartbeat. verify and everything it starts get the pipe closed, so only the subshell
# can write to it.
VERIFY_DONE="$(mktemp -u)"
mkfifo "$VERIFY_DONE" || { echo "check: FAILED — could not make the verify pipe" >&2; exit 1; }
(
  "$ROOT_DIR/script/verify.sh" 9>&- > "$VERIFY_LOG" 2>&1
  status=$?
  echo "exited" >&9
  exit "$status"
) 9> "$VERIFY_DONE" &
verify_pid=$!
exec 9< "$VERIFY_DONE"
rm -f "$VERIFY_DONE"

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

# What a stalled test host is doing, as `op=check.hang` lines. Two tools see two halves,
# and each misleads alone:
#
# - `swift-inspect dump-concurrency` lists every task object still allocated, with the
#   async backtrace of its last suspension. A task that has *finished* but is still held
#   (a handle a leaked owner keeps, a `Task {}` a test stored) is listed the same way, with
#   no mark that it finished, so its stale backtrace reads exactly like a parked one
#   (docs/research/2026-11-16-finished-tasks-in-concurrency-dumps.md). Only tasks under
#   Swift Testing's runner are reported as in flight (`inFlight`); every other task with
#   OtosTests frames is reported as `mayBeFinished`.
# - A test case blocked synchronously (a lock, a semaphore, a `sync` onto a queue) is a
#   *running* task: the dump prints no backtrace for it, only its thread. `sample` holds
#   that thread's stack, so the report prints it (`onThread`, `threadStack role=test`),
#   and the main thread's (`role=main`), which every MainActor test waits on.
#
# "Last test to report" is neither: under parallel execution it names whichever
# unrelated test happened to finish last.
#
# The bound below limits only the diagnostic, which runs against a host already
# measured as stalled; it never limits test work. It exists so a wedged inspector
# cannot turn the stall report itself into the unbounded wait it is reporting on.
INSPECT_SECONDS="${OTOS_CHECK_INSPECT_SECONDS:-180}"

# One thread's stack from a `sample` log: its frames in Otos code, then its innermost
# frames, which name what it is blocked in. `want` is a decimal thread id, or `main`.
print_sampled_thread() {
  local sample_log="$1" want="$2" role="$3"
  awk -v want="$want" -v role="$role" '
    /^ +[0-9]+ Thread_[0-9]+/ {
      if (inside) exit
      if ((want == "main" && /com\.apple\.main-thread/) || (want != "main" && $0 ~ ("Thread_" want "[^0-9]"))) {
        inside = 1; match($0, /Thread_[0-9]+/)
        print "op=check.hang phase=threadStack role=" role " thread=" substr($0, RSTART + 7, RLENGTH - 7)
      }
      next
    }
    inside && (/^ *$/ || /^Total number/) { exit }
    inside {
      f = $0; sub(/^[ +!:|]*[0-9]+ /, "", f); sub(/  \[0x[0-9a-f]+\].*$/, "", f)
      n++; frames[n] = f
      if (f ~ /\(in Otos/) print "  " f
    }
    END {
      if (!inside) { print "op=check.hang phase=threadStack role=" role " thread=" want " detail=notInSample"; exit }
      print "  innermost:"
      for (i = (n > 8 ? n - 7 : 1); i <= n; i++) print "    " frames[i]
    }' "$sample_log"
}

report_hang() {
  local pid="$1" reason="$2" stamp dump sample_log inspect_pid waited=0 threads thread
  mkdir -p "$ROOT_DIR/logs"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-p$$"
  dump="$ROOT_DIR/logs/check-$stamp-concurrency.log"
  sample_log="$ROOT_DIR/logs/check-$stamp-sample.log"
  echo "op=check.hang phase=report reason=$reason pid=$pid sample=$sample_log dump=$dump" >&2
  sample "$pid" 2 -mayDie > "$sample_log" 2>/dev/null || true
  xcrun swift-inspect dump-concurrency "$pid" > "$dump" 2>&1 &
  inspect_pid=$!
  while kill -0 "$inspect_pid" 2>/dev/null && (( waited < INSPECT_SECONDS )); do
    # time: deadline — a wedged swift-inspect must not become the hang it reports
    sleep 1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$inspect_pid" 2>/dev/null; then
    kill -TERM "$inspect_pid" 2>/dev/null
    echo "op=check.hang phase=inspectIncomplete pid=$pid waitedSeconds=$waited" >&2
  fi
  wait "$inspect_pid" 2>/dev/null
  # Top-level tasks are indented six spaces; a child is drawn under its parent as `--Task`.
  # The top-level task running `Runner._runAllTests` holds every test case in flight.
  # Thunks, partial applies and the macro-generated `$s…` entry points restate the test
  # function they wrap, so they are dropped. Prints the hex ids of threads that run a test.
  threads="$(awk '
    function flush(   i, t) {
      runner = (block ~ /Runner\._runAllTests/)
      for (i = 1; i <= nlines; i++) {
        t = lines[i]
        if (t ~ /Task [0-9]+ - flags=/) {
          match(t, /Task [0-9]+/); task = substr(t, RSTART + 5, RLENGTH - 5)
          running = (t ~ /\|running/); shown = 0
          continue
        }
        if (runner && running && t ~ /current task on thread 0x/) {
          sub(/^.*current task on thread 0x/, "", t)
          print "op=check.hang phase=onThread task=" task " thread=0x" t > "/dev/stderr"
          print t; found = 1
          continue
        }
        if (t ~ / in OtosTests$/ && t !~ /resume function:|thunk for|partial apply|implicit closure|\$s[0-9]/) {
          sub(/^.*async backtrace: /, "", t); sub(/^[ \t|`+-]+/, "", t)
          if (!shown) {
            printf "op=check.hang phase=%s task=%s\n", (runner ? "inFlight" : "mayBeFinished"), task > "/dev/stderr"
            shown = 1
          }
          print "  " t > "/dev/stderr"
          if (runner) found = 1
        }
      }
      nlines = 0; block = ""
    }
    /^ACTORS/ { flush(); done = 1; exit }
    /^      Task [0-9]+ - flags=/ { flush() }
    { lines[++nlines] = $0; block = block "\n" $0 }
    END {
      if (!done) flush()
      # No test case in flight means the host never reached our code — the pre-test
      # stall in docs/research/2026-09-01-xctest-host-stalls-before-running-tests.md.
      if (!found) print "op=check.hang phase=noTestInFlight" > "/dev/stderr"
    }' "$dump")"
  print_sampled_thread "$sample_log" main main >&2
  for thread in $threads; do
    print_sampled_thread "$sample_log" "$(( 16#$thread ))" test >&2
  done
  # A text-reading child (`Otos --read-text`) under the host is a test waiting on the
  # system's text model. Its first load in a process is cold, minutes on a loaded machine
  # with its compiled files purged, and its CPU is spent in a system service this run's CPU
  # does not count: the host then reads as stalled while it waits. Only the live readings
  # (OTOS_TEXT_READING_LIVE=1) start one with Vision.
  local child
  for child in $(descendants "$pid"); do
    if ps -o args= -p "$child" 2>/dev/null | grep -qE -- ' --read-text( |$)'; then
      echo "op=check.hang phase=textReadingChild pid=$child cpu=$(ps -o time= -p "$child" | tr -d ' ') detail=\"waiting on the system's text model (cold)\"" >&2
    fi
  done
  # Threads by the queue they run, so a cooperative pool whose every thread is held
  # (`com.apple.root.<qos>-qos.cooperative` at its core count) shows as one line.
  grep -oE "DispatchQueue_[0-9]+: [^ ]+" "$sample_log" | sed -E 's/^DispatchQueue_[0-9]+: //' \
    | sort | uniq -c | sort -rn | awk '{ print "op=check.hang phase=threadsByQueue threads=" $1 " queue=" $2 }' >&2 || true
}

# script/test.sh prints this, then the log path, before xcodebuild starts.
TEST_LOG_ANNOUNCEMENT="Capturing test output to "
# A test case that finished either way. Counting only passes froze tests= at the
# first failure, which reads like the hang the counter exists to reveal.
TEST_FINISHED_PATTERN="' (passed|failed) on '"

HANG_HEARTBEATS=3
last_tests=""
unchanged_heartbeats=0
started_at="$(date +%s)"
while :; do
  # time: schedule — the heartbeat a watcher reads; verify's own exit ends this wait at once
  read -r -t "$HEARTBEAT_SECONDS" _ <&9 && break
  # bash 3.2's read fails the same way on a timeout and on end of file. End of file means
  # the subshell is gone without its line (killed), and a gone subshell is a zombie until
  # `wait` below collects it, so only a subshell still running makes this a heartbeat.
  verify_state="$(ps -o stat= -p "$verify_pid" 2>/dev/null)"
  [[ -n "$verify_state" && "$verify_state" != Z* ]] || break
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

  # tests= unchanged for HANG_HEARTBEATS heartbeats is what a watcher reads as hung. The
  # host is reported then, once per count, without killing anything: a long test is not
  # a hang, and the CPU rule below still decides that. The report is what the reader of
  # this log needs at that moment, so nobody inspects the host by hand.
  if [[ "$stage" == "testing" && "$tests" == "$last_tests" ]]; then
    unchanged_heartbeats=$(( unchanged_heartbeats + 1 ))
  else
    unchanged_heartbeats=0
    last_tests="$tests"
  fi
  if (( unchanged_heartbeats == HANG_HEARTBEATS )); then
    echo "op=check.hang phase=suspected tests=$tests heartbeats=$unchanged_heartbeats cpuSeconds=$cpu" >&2
    for xctest_pid in $(own_pids_matching "Xcode/Agents/xctest"); do
      report_hang "$xctest_pid" testsUnchanged
    done
  fi

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
      report_hang "$xctest_pid" cpuStopped
    done
    echo "check: DEADLOCKED — consumed under ${MIN_CPU_SECONDS_PER_MINUTE} CPU-s/min for ${STALL_SECONDS}s while still running. Killed so this reports instead of hanging." >&2
    cleanup_children
    cat "$VERIFY_LOG" 2>/dev/null
    rm -f "$VERIFY_LOG" "$CPU_LEDGER"
    exit 1
  fi
done
exec 9<&-

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
elif [[ "$verify_status" == "0" && "$VERIFY_TIER" != "$CHECK_TIER" ]]; then
  echo "check: INCOMPLETE — every gate passed, but this machine has no Xcode, so nothing was built or tested; the pushed branch's Build And Test (Xcode 27) CI job builds and tests it (AGENTS.md, \"Cloud Sessions\")" >&2
  verify_status=1
elif [[ "$verify_status" == "0" && "$CHECK_TIER" == "static" ]]; then
  echo "check: PASSED (tier=static: every gate, no build or tests, because the diff reaches nothing they read) — evidence is valid only for the tree as it stands right now"
elif [[ "$verify_status" == "0" ]]; then
  echo "check: PASSED — evidence is valid only for the tree as it stands right now"
else
  echo "check: FAILED — read the stage line above; do not re-run until it is fixed" >&2
fi
exit "$verify_status"
