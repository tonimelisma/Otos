#!/usr/bin/env bash
# The weekly performance run (ADR 0043): one entry point, one verdict.
#
#   script/perf.sh status     One line: due, running, pass, fail or error. script/check.sh
#                             prints it.
#   script/perf.sh run        At most once a week, one run at a time, from the primary
#                             checkout: tours the installed app on the owner's library,
#                             read-only, and judges the felt numbers against
#                             docs/scorecard-targets.json; then counts the benchmark cases'
#                             instructions on origin/main against the last run's head
#                             (script/bench.sh compare). The session whose check reports
#                             verdict=due starts it in the background.
#   script/perf.sh not-reproduced <scorecard.json>
#                             After verdict=fail: records that the one reproducing tour, whose
#                             saved scorecard this is, met every target the run missed. The
#                             verdict stays fail and stops asking for a fix until the next run.
#   script/perf.sh self-test  The status and verdict rules against stubbed inputs. Measures
#                             nothing.
#
# The verdict fails only on a felt target missed on the owner's library. Instruction rises
# are listed in it (cpu=) and decide nothing; the baseline moves to each run's head.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/build-folder.sh"
source "$ROOT_DIR/script/lib/installed-app.sh"

COMMON_DIR="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)"
PRIMARY_DIR="$(dirname "$COMMON_DIR")"
# Shared by every worktree of the clone: the last run's verdict is one line, and the run in
# progress holds a kernel lock (otos_hold_lock) that dies with it.
VERDICT_FILE="$COMMON_DIR/otos-perf-verdict"
LOCK_FILE="$COMMON_DIR/otos-perf.flock"
# The commit the next run's counts are set against: the last run's head.
BASELINE_REF="refs/bench/baseline"
# A week between runs: time: schedule — the product's chosen cadence for this run (ADR 0043).
INTERVAL_DAYS=7

usage() {
  awk 'NR >= 4 { if ($0 == "#") exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# One field of a verdict line (`<verdict> day=… head=… felt=… cpu=…`); empty when absent.
field() {
  printf '%s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"
}

days_between() {
  local from="$1" to="$2"
  # Each day at a fixed noon: `date -j -f` takes every field its format leaves out from the
  # clock, so two calls a second apart measured a week as 604,799 s, six days (2026-11-19).
  # Noon keeps a daylight-saving change from moving the count either.
  echo $(( ($(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$to 12:00:00" +%s) \
    - $(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$from 12:00:00" +%s)) / 86400 ))
}

# The status line for a stored verdict, today's date, origin/main's head and the lock's
# state. Pure, so self-test can hold every case.
status_line() {
  local verdict="$1" today="$2" main="$3" lock_state="$4"
  local kind day head
  kind="${verdict%% *}"
  day="$(field "$verdict" day)"
  head="$(field "$verdict" head)"
  if [[ "$lock_state" == held* ]]; then
    echo "op=perf.status verdict=running ${lock_state#held }"
    return
  fi
  local due=""
  if [[ -z "$verdict" ]]; then
    due="neverRun"
  elif [[ "$kind" == error && "$day" != "$today" ]]; then
    due="lastRunFailed"
  elif [[ "$kind" != error && "$main" != "$head" ]] && (( $(days_between "$day" "$today") >= INTERVAL_DAYS )); then
    due="weekPassed"
  fi
  if [[ -n "$due" ]]; then
    echo "op=perf.status verdict=due reason=$due lastRun=${day:-never} action=\"start script/perf.sh run in the background and keep working\""
  elif [[ "$kind" == fail && -n "$(field "$verdict" notReproduced)" ]]; then
    echo "op=perf.status verdict=$verdict action=\"none: the miss did not reproduce; the next weekly run judges it\""
  elif [[ "$kind" == fail ]]; then
    echo "op=perf.status verdict=$verdict action=\"fix the felt targets next, starting with one tour that reproduces the miss\""
  else
    echo "op=perf.status verdict=$verdict"
  fi
}

status() {
  local verdict lock_state
  verdict="$(cat "$VERDICT_FILE" 2>/dev/null || true)"
  if ! lock_state="$(otos_lock_state "$LOCK_FILE")"; then
    echo "op=perf.status verdict=unknown reason=lockQueryFailed lock=$LOCK_FILE" >&2
    return 1
  fi
  status_line "$verdict" "$(/bin/date +%Y-%m-%d)" "$(git -C "$ROOT_DIR" rev-parse origin/main)" "$lock_state"
}

# The felt targets a saved scorecard missed, comma-separated, or `none`. Exits 1 when the
# file holds no verdicts: a tour that judged nothing is no measurement.
felt_misses() {
  /usr/bin/python3 -I - "$1" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1])).get("verdicts") or []
except (OSError, ValueError):
    rows = []
if not rows:
    sys.exit(1)
misses = sorted({row.get("metric") or row["label"] for row in rows if row.get("verdict") == "FAIL"})
print(",".join(m.replace(" ", "_") for m in misses) or "none")
PY
}

# The cases a `bench.sh compare` output flagged, or `none`; for its exit status 0 or 3.
cpu_rises() {
  local output="$1" status="$2"
  case "$status" in
    0) echo none ;;
    3) printf '%s\n' "$output" | sed -n 's/^op=bench phase=flagged cases=//p' ;;
    *) return 1 ;;
  esac
}

# The verdict line a run writes: fail when any felt target was missed, pass otherwise.
verdict_line() {
  local day="$1" head="$2" felt="$3" cpu="$4" scorecard="$5"
  local kind=pass
  [[ "$felt" != none ]] && kind=fail
  echo "$kind day=$day head=$head felt=$felt cpu=$cpu scorecard=$scorecard"
}

# The verdict line after a reproducing tour: unchanged when the tour missed any target the
# run missed (exit 1, the misses on stdout), marked notReproduced=<day> otherwise.
not_reproduced_line() {
  local verdict="$1" today="$2" tour_misses="$3"
  local still="" metric
  for metric in $(field "$verdict" felt | tr ',' ' '); do
    case ",$tour_misses," in *",$metric,"*) still="${still:+$still,}$metric" ;; esac
  done
  if [[ -n "$still" ]]; then
    echo "$still"
    return 1
  fi
  echo "$verdict notReproduced=$today"
}

not_reproduced() {
  local scorecard="${1:-}" verdict tour_misses line
  if [[ -z "$scorecard" ]]; then
    usage
    exit 2
  fi
  verdict="$(cat "$VERDICT_FILE" 2>/dev/null || true)"
  if [[ "${verdict%% *}" != fail ]]; then
    echo "op=perf.notReproduced phase=refused reason=verdictIsNotFail verdict=${verdict%% *}" >&2
    exit 1
  fi
  if [[ -n "$(field "$verdict" notReproduced)" ]]; then
    echo "op=perf.notReproduced phase=skipped reason=alreadyRecorded"
    return
  fi
  if ! tour_misses="$(felt_misses "$scorecard")"; then
    echo "op=perf.notReproduced phase=refused reason=tourJudgedNothing scorecard=$scorecard" >&2
    exit 1
  fi
  if ! line="$(not_reproduced_line "$verdict" "$(/bin/date +%Y-%m-%d)" "$tour_misses")"; then
    echo "op=perf.notReproduced phase=refused reason=reproduced felt=$line scorecard=$scorecard" >&2
    exit 1
  fi
  echo "$line" > "$VERDICT_FILE"
  echo "op=perf.notReproduced phase=recorded felt=$(field "$verdict" felt) tourMissed=$tour_misses scorecard=$scorecard"
}

reopen_installed_app() {
  if [[ "${OTOS_INSTALLED_WAS_RUNNING:-0}" == 1 ]]; then
    if otos_reopen_installed_app; then
      echo "op=perf.run phase=reopened app=$OTOS_INSTALLED_APP"
    else
      echo "op=perf.run phase=reopenFailed app=$OTOS_INSTALLED_APP" >&2
    fi
  fi
}

run() {
  # The primary checkout outlives the session that started the run.
  if [[ "$ROOT_DIR" != "$PRIMARY_DIR" ]]; then
    exec "$PRIMARY_DIR/script/perf.sh" run
  fi
  otos_hold_lock try "$LOCK_FILE" perf.run
  case "$OTOS_LOCK_OUTCOME" in
    held) ;;
    busy*) echo "op=perf.run phase=skipped reason=running ${OTOS_LOCK_OUTCOME#busy }"; return ;;
    *) echo "op=perf.run phase=failed reason=lockUnavailable lock=$LOCK_FILE" >&2; exit 1 ;;
  esac
  # Read under the lock, so a run that finished just before this one took it is seen.
  local today head baseline line
  today="$(/bin/date +%Y-%m-%d)"
  head="$(git -C "$ROOT_DIR" rev-parse origin/main)"
  line="$(status_line "$(cat "$VERDICT_FILE" 2>/dev/null || true)" "$today" "$head" free)"
  if [[ "$line" != *"verdict=due"* ]]; then
    echo "op=perf.run phase=skipped reason=notDue ${line#op=perf.status }"
    return
  fi
  baseline="$(git -C "$ROOT_DIR" rev-parse -q --verify "$BASELINE_REF" || true)"
  echo "op=perf.run phase=start head=$head baseline=${baseline:-none}"

  # The tour needs the installed app to itself. It is quit as script/install.sh quits it,
  # never while an import or reorganization is in flight, and reopened however the run ends.
  local quit_status=0
  trap reopen_installed_app EXIT
  otos_quit_installed_app || quit_status=$?
  case "$quit_status" in
    0) echo "op=perf.run phase=installedApp quit=$OTOS_INSTALLED_WAS_RUNNING" ;;
    1) echo "op=perf.run phase=pending reason=busy root=$OTOS_INSTALLED_BUSY_ROOT — stays due"; return ;;
    *) fail_run "$today" "$head" quitInstalledApp ;;
  esac

  local scorecard felt cpu output status=0
  mkdir -p "$ROOT_DIR/build/scorecards"
  scorecard="$ROOT_DIR/build/scorecards/$(/bin/date -u +%Y%m%dT%H%M%SZ)-weekly.json"
  # A launch tour with a two-minute idle (owner, 2026-11-18): long enough to see background
  # work beside the window, short enough that the run stays a few minutes.
  "$ROOT_DIR/script/scorecard.sh" --tour --idle 120 --json "$scorecard" || fail_run "$today" "$head" tour
  # The owner has the app back while the counts are measured.
  reopen_installed_app
  felt="$(felt_misses "$scorecard")" || fail_run "$today" "$head" tourJudgedNothing

  # With no baseline yet, the head is measured and becomes it.
  output="$("$ROOT_DIR/script/bench.sh" compare "${baseline:-$head}" "$head")" || status=$?
  printf '%s\n' "$output"
  cpu="$(cpu_rises "$output" "$status")" || fail_run "$today" "$head" "benchStatus$status"
  git -C "$ROOT_DIR" update-ref "$BASELINE_REF" "$head"
  line="$(verdict_line "$today" "$head" "$felt" "$cpu" "$scorecard")"
  echo "$line" > "$VERDICT_FILE"
  echo "op=perf.run phase=finish $line"
}

# A run that could not measure writes an error verdict, so it is due again tomorrow, and
# moves no baseline.
fail_run() {
  echo "error day=$1 head=$2 reason=$3" > "$VERDICT_FILE"
  echo "op=perf.run phase=failed reason=$3" >&2
  exit 1
}

self_test() {
  local failures=0
  expect() {
    if [[ "$2" != *"$3"* ]]; then
      echo "FAIL: $1: got '$2', expected it to hold '$3'" >&2
      failures=$((failures + 1))
    fi
  }
  expect neverRun "$(status_line "" 2026-11-18 aaa free)" "verdict=due reason=neverRun lastRun=never"
  expect running "$(status_line "" 2026-11-18 aaa "held pid=1")" "verdict=running pid=1"
  expect sameWeek "$(status_line "pass day=2026-11-12 head=aaa felt=none cpu=none" 2026-11-18 bbb free)" "verdict=pass day=2026-11-12"
  expect weekPassed "$(status_line "pass day=2026-11-11 head=aaa felt=none cpu=none" 2026-11-18 bbb free)" "verdict=due reason=weekPassed lastRun=2026-11-11"
  expect mainUnmoved "$(status_line "pass day=2026-11-01 head=aaa felt=none cpu=x" 2026-11-18 aaa free)" "verdict=pass"
  expect failShown "$(status_line "fail day=2026-11-15 head=aaa felt=launch.firstGridMs cpu=none" 2026-11-18 bbb free)" "verdict=fail day=2026-11-15 head=aaa felt=launch.firstGridMs cpu=none action="
  local failed="fail day=2026-11-15 head=aaa felt=mainThreadStalls.worstMs,click.returnMs cpu=none scorecard=s.json"
  expect notReproduced "$(not_reproduced_line "$failed" 2026-11-16 memory.peakFootprintMB)" "cpu=none scorecard=s.json notReproduced=2026-11-16"
  expect notReproducedClean "$(not_reproduced_line "$failed" 2026-11-16 none)" "notReproduced=2026-11-16"
  expect reproduced "$(not_reproduced_line "$failed" 2026-11-16 launch.firstGridMs,click.returnMs || true)" "click.returnMs"
  if not_reproduced_line "$failed" 2026-11-16 click.returnMs >/dev/null; then
    echo "FAIL: reproducedRefused: a tour that misses the same target reproduces it" >&2
    failures=$((failures + 1))
  fi
  expect notReproducedShown "$(status_line "$failed notReproduced=2026-11-16" 2026-11-18 bbb free)" "notReproduced=2026-11-16 action=\"none:"
  expect notReproducedStillDue "$(status_line "$failed notReproduced=2026-11-16" 2026-11-22 bbb free)" "verdict=due reason=weekPassed"
  expect errorToday "$(status_line "error day=2026-11-18 head=aaa reason=tour" 2026-11-18 bbb free)" "verdict=error day=2026-11-18"
  expect errorTomorrow "$(status_line "error day=2026-11-17 head=aaa reason=tour" 2026-11-18 aaa free)" "verdict=due reason=lastRunFailed"
  expect passes "$(verdict_line 2026-11-18 aaa none window.publish.orderChanged.158k s.json)" "pass day=2026-11-18 head=aaa felt=none cpu=window.publish.orderChanged.158k"
  expect fails "$(verdict_line 2026-11-18 aaa click.returnMs none s.json)" "fail day=2026-11-18"
  expect cpuClean "$(cpu_rises "op=bench phase=compared flagged=0" 0)" none
  expect cpuFlagged "$(cpu_rises $'x\nop=bench phase=flagged cases=a,b' 3)" "a,b"
  if cpu_rises "op=bench phase=judgeRefused" 4 >/dev/null; then
    echo "FAIL: cpuRefused: a refused judge is no measurement" >&2
    failures=$((failures + 1))
  fi
  local dir
  dir="$(mktemp -d)"
  printf '%s' '{"verdicts": [{"metric": "launch.firstGridMs", "label": "launch", "verdict": "PASS"}, {"metric": "click.returnMs", "label": "return", "verdict": "FAIL"}, {"metric": null, "label": "tour step x", "verdict": "FAIL"}]}' > "$dir/missed.json"
  printf '%s' '{"verdicts": [{"metric": "launch.firstGridMs", "label": "launch", "verdict": "PASS"}]}' > "$dir/met.json"
  printf '%s' '{"report": {}}' > "$dir/empty.json"
  expect feltMissed "$(felt_misses "$dir/missed.json")" "click.returnMs,tour_step_x"
  expect feltMet "$(felt_misses "$dir/met.json")" none
  if felt_misses "$dir/empty.json" >/dev/null; then
    echo "FAIL: feltEmpty: a scorecard with no verdicts is no measurement" >&2
    failures=$((failures + 1))
  fi
  rm -rf "$dir"
  if (( failures > 0 )); then
    echo "op=perf.selfTest phase=failed failures=$failures" >&2
    return 1
  fi
  echo "op=perf.selfTest phase=pass"
}

case "${1:-}" in
  status) status ;;
  run) run ;;
  not-reproduced) not_reproduced "${2:-}" ;;
  self-test) self_test ;;
  *) usage; exit 2 ;;
esac
