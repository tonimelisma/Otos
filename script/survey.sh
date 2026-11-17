#!/usr/bin/env bash
# One session's whole-machine picture, captured from outside the app, without root.
#
# The app's own lines say what Otos did; this says what it cost and what else on the
# machine competed. It wraps one session (a launch it makes, or a running instance it
# attaches to) and records, for that session's length:
#
#   CPU         an Instruments Time Profiler trace, attached to the pid (never --launch:
#               xctrace's own launch leaves the app suspended after its time limit)
#   memory      phys_footprint (rusage), vmmap --summary by region, footprint(1) and the
#               system's VM counters at each moment below; heap(1) and a thread sample
#               when the footprint reaches a new high
#   disk I/O    proc_pid_rusage counters for Otos, its text reader and every process this
#               user may read; iostat over the session
#   threads     a five-second sample at the footprint peak and after the first stalls
#   files       du and file counts of every folder Otos owns, before and after
#   network     nettop byte counters for every process
#   energy      the kernel's billed energy per process (rusage) and top's POWER column
#   neighbours  top's MEM/CPU/POWER for the system model, analysis, sync and index
#               processes, which run as other users and so are readable only through top
#
# Moments: launch +15 s, +30 s, +60 s, +180 s (time: measurement — a fixed sampling plan
# for the phases nothing reports), each `op=tour phase=step` line, the first
# `op=description` line (the system language model's footprint around its first use),
# and the end.
#
# Output: build/surveys/<UTC time>-<revision>/ holding raw/ and one summary.md +
# summary.json (script/lib/survey-summary.py). raw/ is local evidence and may hold paths;
# the summary carries function names, process names, region types, counts and sizes only.
#
# It never writes into a catalog or a library: every read of Otos's data is du, find or
# `sqlite3 -readonly`. It quits only an app it launched, confirms the app and its text
# reader are gone, and stops every recorder it started however it ends (trap).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"
source "$ROOT_DIR/script/lib/operational-busy.sh"

APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"
INSTALLED_APP="/Applications/Otos.app"
# Processes that compete with Otos for memory, disk and the model; matched by exact name.
NEIGHBOURS="TGOnDeviceInferenceProviderService modelmanagerd generativeexperiencesd mediaanalysisd photoanalysisd fileproviderd OneDrive mds mds_stores mdworker_shared XCBBuildService xcodebuild swift-frontend claude node"

usage() {
  cat <<'EOF'
Usage:
  script/survey.sh [session] [options]

Session (one of):
  (default)            launch the installed app (/Applications/Otos.app) with --env values
  --dev --home <dir>   build this checkout's dev app and launch it with HOME and
                       CFFIXED_USER_HOME set to <dir>, a sandbox home (never your own)
  --launch '<command>' run <command> (bash -c) to start Otos; the new pid is surveyed
  --attach <pid>       survey a running Otos; it is neither launched nor quit
                       (add --home <dir> when that instance runs in a sandbox home)

Options:
  --env KEY=VALUE      environment for the launched app, repeatable (the tour's flag)
  --duration <s>       session length when no tour runs (default 240)
  --tour-deadline <s>  longest a tour may run before the survey ends it (default 1800)
  --no-heap            skip heap(1), which pauses the app while it walks the heap
  --peak-floor-mb <n>  footprint below which no peak heap/sample is taken (default 200)
  --allocations        also record an Allocations trace (heavy; off by default)
  --out <dir>          output directory (default build/surveys/<time>-<revision>)

A session ends when the app exits by itself (a tour quits it), at --duration when no
`op=tour` line arrived, or at --tour-deadline. Refuses to start while an Otos it would
not own is running, except with --attach. A --home that script/sandbox-library.sh made
launches with its library (OTOS_SANDBOX_LIBRARY), which the app registers on its first
launch: a first launch of a new library, surveyed on generated media.
EOF
}

MODE="installed"
HOME_DIR=""
LAUNCH_CMD=""
ATTACH_PID=""
DURATION=240
TOUR_DEADLINE=1800
WANT_HEAP=1
PEAK_FLOOR_MB=200
WANT_ALLOCATIONS=0
OUT_DIR=""
APP_ENV=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) MODE="dev"; shift ;;
    --home) HOME_DIR="${2:?--home needs a directory}"; shift 2 ;;
    --launch) MODE="launch"; LAUNCH_CMD="${2:?--launch needs a command}"; shift 2 ;;
    --attach) MODE="attach"; ATTACH_PID="${2:?--attach needs a pid}"; shift 2 ;;
    --env)
      [[ "${2:-}" == *=* ]] || { echo "--env needs KEY=VALUE" >&2; exit 2; }
      APP_ENV+=("$2"); shift 2 ;;
    --duration) DURATION="${2:?}"; shift 2 ;;
    --tour-deadline) TOUR_DEADLINE="${2:?}"; shift 2 ;;
    --no-heap) WANT_HEAP=0; shift ;;
    --peak-floor-mb) PEAK_FLOOR_MB="${2:?}"; shift 2 ;;
    --allocations) WANT_ALLOCATIONS=1; shift ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$DURATION" =~ ^[0-9]+$ && "$TOUR_DEADLINE" =~ ^[0-9]+$ && "$PEAK_FLOOR_MB" =~ ^[0-9]+$ ]] \
  || { echo "durations and the peak floor are whole numbers" >&2; exit 2; }
if [[ "$MODE" == "attach" ]]; then
  [[ "$ATTACH_PID" =~ ^[0-9]+$ ]] || { echo "--attach needs a numeric pid" >&2; exit 2; }
  kill -0 "$ATTACH_PID" 2>/dev/null || { echo "No process $ATTACH_PID" >&2; exit 1; }
fi

# A sandbox home is never the user's own home or a folder that holds it.
if [[ -n "$HOME_DIR" ]]; then
  mkdir -p "$HOME_DIR"
  HOME_DIR="$(cd "$HOME_DIR" && pwd -P)"
  REAL_HOME="$(cd "$HOME" && pwd -P)"
  if [[ "$HOME_DIR" == "$REAL_HOME" || "$REAL_HOME" == "$HOME_DIR"/* ]]; then
    echo "--home must be a sandbox, not your home or a folder holding it" >&2
    exit 2
  fi
fi
[[ "$MODE" != "dev" || -n "$HOME_DIR" ]] || { echo "--dev needs --home <sandbox dir>" >&2; exit 2; }
DATA_HOME="${HOME_DIR:-$HOME}"

# ── Refuse a session this run would not own ──────────────────────────────────
# The session's text readers are the app's own `Otos --read-text` children (ADR 0048). A
# reader another process started (a test host's) is not this session's and is left alone.
# Every reader seen is recorded in a file, since callers read this in a subshell.
reader_pids() {
  local pid
  [[ -n "$APP_PID" ]] || return 0
  for pid in $(pgrep -P "$APP_PID" -x "$APP_NAME" 2>/dev/null || true); do
    grep -qx "$pid" "$RAW/readers.txt" 2>/dev/null || echo "$pid" >> "$RAW/readers.txt"
    echo "$pid"
  done
}
if [[ "$MODE" != "attach" ]]; then
  otos_refuse_if_running "$APP_NAME"
fi

REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/surveys/$(date -u +%Y%m%dT%H%M%SZ)-$REVISION}"
RAW="$OUT_DIR/raw"
mkdir -p "$RAW"
ERRORS="$RAW/errors.log"
: > "$ERRORS"
EVENTS="$RAW/events.tsv"
printf 'epoch\tkind\tlabel\tdetail\n' > "$EVENTS"
# xctrace stages each recording as an `instruments*.ktrace` in its temporary folder, several
# GB a session, and leaves it there. The recorders and the exports get a temporary folder of
# their own (TMPDIR), which cleanup removes once every recorder has stopped.
TRACE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/otos-survey-trace.XXXXXX")"
TRACE_MARK="$TRACE_TMP/.started"
: > "$TRACE_MARK"

event() { printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "${3:-}" >> "$EVENTS"; }
fail_note() { echo "$(date +%s) $*" >> "$ERRORS"; echo "op=survey.capture phase=failed $*" >&2; }

APP_PID=""
LAUNCHED=0
LOG_PID=""
XCTRACE_PID=""
ALLOC_PID=""
IOSTAT_PID=""
APP_BUNDLE=""
BUNDLE_ID=""

# ── Cleanup: every recorder stops, a launched app quits, however this ends ───
stop_recorder() {
  local pid="$1" signal="$2"
  [[ -n "$pid" ]] || return 0
  kill "-$signal" "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# An xctrace recorder finishes its file on SIGINT, but only once it records: a background
# job of a non-interactive shell starts with SIGINT ignored, and xctrace takes the signal
# only after it installs its own handler, which it reports by printing its "Ctrl-C to stop"
# line. An INT sent before that line is lost, and a `wait` on the recorder never returns.
# So the stop waits for that line, sends INT, and waits for the recorder to exit; a recorder
# that has not done either by the deadline is terminated, its trace reported lost and
# removed (a half-written trace would stall its export), and the survey goes on.
TRACE_STOP_DEADLINE_TENTHS=1800
stop_trace() {
  local pid="$1" log="$2" trace="$3"
  [[ -n "$pid" ]] || return 0
  local waited=0
  while kill -0 "$pid" 2>/dev/null && ! grep -q 'Ctrl-C to stop' "$log" 2>/dev/null \
    && (( waited < TRACE_STOP_DEADLINE_TENTHS )); do
    # time: deadline — an attach that never reports recording is given up after 180 s
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -INT "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && (( waited < TRACE_STOP_DEADLINE_TENTHS )); do
    # time: deadline — saving a session's trace is given 180 s in all before it counts as lost
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf -- "$trace"
    fail_note "trace=$(basename "$trace") reason=recorderDidNotStop waitedS=$((waited / 10))"
    echo "op=survey.trace phase=lost trace=$(basename "$trace") reason=recorderDidNotStop" >&2
    return 0
  fi
  wait "$pid" 2>/dev/null || true
  echo "op=survey.trace phase=saved trace=$(basename "$trace") stopS=$((waited / 10))"
}

quit_launched_app() {
  [[ "$LAUNCHED" == 1 && -n "$APP_PID" ]] || return 0
  kill -0 "$APP_PID" 2>/dev/null || return 0
  local catalog="$DATA_HOME/Library/Application Support/$BUNDLE_ID/Catalog/catalog.sqlite"
  if has_active_operational_work "$catalog" > /dev/null; then
    echo "op=survey.quit phase=refused reason=operationalWorkActive pid=$APP_PID" >&2
    echo "An import or reorganization is in flight; quit Otos yourself when it ends." >&2
    return 1
  fi
  # Addressed by the bundle's path: several builds share the dev bundle identifier, and
  # an identifier can resolve to one that is not running, which makes Quit a no-op.
  /usr/bin/osascript -e "tell application \"$APP_BUNDLE\" to quit" >/dev/null 2>>"$ERRORS" || true
  local waited=0
  while kill -0 "$APP_PID" 2>/dev/null && (( waited < 300 )); do
    # time: deadline — an app that ignores Quit for 30 s is terminated
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$APP_PID" 2>/dev/null; then
    echo "op=survey.quit phase=terminated reason=ignoredQuit pid=$APP_PID" >&2
    kill "$APP_PID" 2>/dev/null || true
  fi
}

# Every reader this session saw, and any still parented to the app, that is still alive.
alive_readers() {
  local pid
  reader_pids > /dev/null
  for pid in $(cat "$RAW/readers.txt" 2>/dev/null || true); do
    if kill -0 "$pid" 2>/dev/null; then echo "$pid"; fi
  done
}

confirm_gone() {
  [[ "$LAUNCHED" == 1 ]] || return 0
  local waited=0 apps readers
  while (( waited < 100 )); do
    apps="$(otos_running_pids "$APP_NAME")"
    readers="$(alive_readers)"
    [[ -z "$apps" && -z "$readers" ]] && break
    # time: deadline — the text reader exits once its parent is gone; bounded at 10 s
    sleep 0.1
    waited=$((waited + 1))
  done
  apps="$(otos_running_pids "$APP_NAME")"
  readers="$(alive_readers)"
  if [[ -n "$apps" || -n "$readers" ]]; then
    echo "op=survey.quit phase=failed apps=$(tr '\n' ',' <<<"$apps") readers=$(tr '\n' ',' <<<"$readers")" >&2
    return 1
  fi
  echo "op=survey.quit phase=confirmed app=gone reader=gone"
}

# Deletes this run's trace temporaries: its own TMPDIR folder, and any `instruments*.ktrace`
# xctrace staged in the per-user temporary folder anyway since the run began that no process
# still holds open (another session's recorder holds its own). Called only once every
# recorder this run started has stopped.
remove_trace_temps() {
  [[ -n "${TRACE_TMP:-}" && -d "$TRACE_TMP" ]] || return 0
  local user_tmp file bytes=0 removed=0 folder_kb
  user_tmp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
  while IFS= read -r -d '' file; do
    /usr/sbin/lsof -t -- "$file" >/dev/null 2>&1 && continue
    bytes=$(( bytes + $(/usr/bin/stat -f %z "$file") ))
    removed=$(( removed + 1 ))
    rm -f -- "$file"
  done < <(/usr/bin/find "$user_tmp" -maxdepth 1 -name 'instruments*.ktrace' -newer "$TRACE_MARK" -print0 2>/dev/null)
  folder_kb="$(/usr/bin/du -sk "$TRACE_TMP" | cut -f1)"
  rm -rf -- "$TRACE_TMP"
  echo "op=survey.traceTemp phase=removed folderKB=$folder_kb strayKtraces=$removed strayBytes=$bytes"
}

CLEANED=0
cleanup() {
  local status=$?
  (( CLEANED == 0 )) || return 0
  CLEANED=1
  trap - EXIT INT TERM
  # xctrace finishes its file on SIGINT; it stops before the app does, so the trace does
  # not end with the quit.
  stop_trace "$XCTRACE_PID" "$RAW/xctrace.log" "$RAW/cpu.trace"
  stop_trace "$ALLOC_PID" "$RAW/xctrace-allocations.log" "$RAW/allocations.trace"
  quit_launched_app || status=1
  stop_recorder "$IOSTAT_PID" TERM
  stop_recorder "$LOG_PID" TERM
  confirm_gone || status=1
  local leftovers="" pid
  for pid in $XCTRACE_PID $ALLOC_PID $IOSTAT_PID $LOG_PID; do
    if kill -0 "$pid" 2>/dev/null; then leftovers="$leftovers $pid"; fi
  done
  if [[ -n "$leftovers" ]]; then
    echo "op=survey.recorders phase=failed alive=$leftovers" >&2
    echo "op=survey.traceTemp phase=kept reason=recorderAlive folder=$TRACE_TMP" >&2
    status=1
  else
    echo "op=survey.recorders phase=stopped"
    remove_trace_temps
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ── The folders Otos owns, sized (du/find only) ──────────────────────────────
owned_locations() {
  local bid="$1" entry
  printf 'AppSupport\t%s\n' "$DATA_HOME/Library/Application Support/$bid"
  printf 'Caches\t%s\n' "$DATA_HOME/Library/Caches/$bid"
  printf 'DarwinCache\t%s\n' "$(getconf DARWIN_USER_CACHE_DIR)$bid"
  printf 'DarwinTemp\t%s\n' "$(getconf DARWIN_USER_TEMP_DIR)$bid"
  # The app's own temporary folders (staging and hand-off of an in-memory catalog); test
  # hosts leave OtosTests-* folders here too, and those are not the app's.
  for entry in "$(getconf DARWIN_USER_TEMP_DIR)"OtosStaging-* "$(getconf DARWIN_USER_TEMP_DIR)"OtosHandOff; do
    if [[ -e "$entry" ]]; then printf 'Temp\t%s\n' "$entry"; fi
  done
  return 0
}

size_entry() {
  local kind="$1" sub="$2" path="$3" kb files
  kb="$(du -sk "$path" 2>/dev/null | cut -f1)"
  files="$(/usr/bin/find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\n' "$kind" "$sub" "$(( ${kb:-0} * 1024 ))" "$files"
}

size_files() {
  local output="$1" kind path entry
  printf 'kind\tsubfolder\tbytes\tfiles\n' > "$output"
  while IFS=$'\t' read -r kind path; do
    if [[ ! -e "$path" ]]; then
      printf '%s\t-\t0\t0\n' "$kind" >> "$output"
    elif [[ "$kind" == "Temp" ]]; then
      size_entry "$kind" "$(basename "$path" | sed -E 's/-[0-9A-Fa-f-]{36}$/-<uuid>/')" "$path" >> "$output"
    else
      for entry in "$path"/* "$path"/.[!.]*; do
        if [[ -e "$entry" ]]; then size_entry "$kind" "$(basename "$entry")" "$entry" >> "$output"; fi
      done
    fi
  done < <(owned_locations "$BUNDLE_ID")
}

# ── Start the session ────────────────────────────────────────────────────────
log_predicate() {
  local predicate
  predicate="process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\""
  if [[ "$MODE" == "attach" ]]; then predicate="$predicate AND processID == $ATTACH_PID"; fi
  printf '%s' "$predicate"
}

bundle_of_pid() {
  local exe
  exe="$(/bin/ps -o comm= -p "$1" 2>/dev/null || true)"
  [[ "$exe" == */Contents/MacOS/* ]] || return 1
  printf '%s' "${exe%/Contents/MacOS/*}"
}

case "$MODE" in
  installed)
    APP_BUNDLE="$INSTALLED_APP"
    ;;
  dev)
    source "$ROOT_DIR/script/lib/xcode.sh"
    source "$ROOT_DIR/script/lib/build-folder.sh"
    otos_require_full_xcode
    otos_hold_build_folder "$ROOT_DIR/build/DerivedData" survey
    echo "op=survey.build phase=start log=$RAW/build.log"
    if ! otos_build_checkout "$ROOT_DIR" debuggable build > "$RAW/build.log" 2>&1; then
      echo "op=survey.build phase=failed log=$RAW/build.log" >&2
      exit 1
    fi
    APP_BUNDLE="$ROOT_DIR/build/DerivedData/Build/Products/Debug/$APP_NAME.app"
    ;;
esac
if [[ -n "$APP_BUNDLE" ]]; then
  [[ -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]] || { echo "No app at $APP_BUNDLE" >&2; exit 1; }
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
fi

# Debug level: `op=description phase=written` is a debug line, and the app's logging
# profile delivers debug lines to a live stream.
/usr/bin/log stream --style ndjson --level debug --predicate "$(log_predicate)" > "$RAW/log.ndjson" 2>>"$ERRORS" &
LOG_PID=$!
# The stream prints its header once it is live; a launch before that loses its first lines.
until [[ -s "$RAW/log.ndjson" ]] || ! kill -0 "$LOG_PID" 2>/dev/null; do
  # time: poll — log(1) reports readiness only by writing its first line
  sleep 0.1
done

before="$(otos_running_pids "$APP_NAME")"
case "$MODE" in
  installed|dev)
    launch_env=()
    if [[ "$MODE" == "dev" ]]; then launch_env+=("HOME=$HOME_DIR" "CFFIXED_USER_HOME=$HOME_DIR"); fi
    # A home script/sandbox-library.sh made: the app registers its library through its own
    # Add Library intent on the first launch (`SandboxLibrary`).
    if [[ "$MODE" == "dev" && -f "$HOME_DIR/.otos-sandbox-library" ]]; then
      launch_env+=("OTOS_SANDBOX_LIBRARY=$(/usr/bin/sed -n 's/^library=//p' "$HOME_DIR/.otos-sandbox-library")")
    fi
    launch_env+=(${APP_ENV[@]+"${APP_ENV[@]}"})
    env ${launch_env[@]+"${launch_env[@]}"} "$APP_BUNDLE/Contents/MacOS/$APP_NAME" > "$RAW/app-stdout.log" 2>&1 &
    APP_PID=$!
    LAUNCHED=1
    ;;
  launch)
    env ${APP_ENV[@]+"${APP_ENV[@]}"} /bin/bash -c "$LAUNCH_CMD" > "$RAW/app-stdout.log" 2>&1 || true
    APP_PID="$(otos_newly_launched_pid "$APP_NAME" "$before")"
    LAUNCHED=1
    ;;
  attach)
    APP_PID="$ATTACH_PID"
    ;;
esac
SESSION_START="$(date +%s)"
if [[ -z "$BUNDLE_ID" ]]; then
  APP_BUNDLE="$(bundle_of_pid "$APP_PID")" || { echo "pid $APP_PID is not an app bundle's executable" >&2; exit 1; }
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
fi
event session start "mode=$MODE pid=$APP_PID bundle=$BUNDLE_ID"
echo "op=survey.session phase=start mode=$MODE pid=$APP_PID out=$OUT_DIR"

size_files "$RAW/files-before.tsv"

TMPDIR="$TRACE_TMP/" /usr/bin/xcrun xctrace record --template 'Time Profiler' --attach "$APP_PID" \
  --output "$RAW/cpu.trace" --no-prompt > "$RAW/xctrace.log" 2>&1 &
XCTRACE_PID=$!
if [[ "$WANT_ALLOCATIONS" == 1 ]]; then
  TMPDIR="$TRACE_TMP/" /usr/bin/xcrun xctrace record --template 'Allocations' --attach "$APP_PID" \
    --output "$RAW/allocations.trace" --no-prompt > "$RAW/xctrace-allocations.log" 2>&1 &
  ALLOC_PID=$!
fi
# iostat's own interval is its measurement cadence, not a wait in this script.
/usr/sbin/iostat -d -C -w 5 > "$RAW/iostat.txt" 2>>"$ERRORS" &
IOSTAT_PID=$!

# ── One moment's capture ─────────────────────────────────────────────────────
SNAP=0
PEAK_TAKEN=0

snapshot() {
  local label="$1" n pids
  SNAP=$((SNAP + 1))
  n="$(printf '%02d' "$SNAP")"
  event snapshot "$label" "n=$n"
  kill -0 "$APP_PID" 2>/dev/null || { fail_note "snapshot=$label reason=appGone"; return 0; }
  # shellcheck disable=SC2046 # one argument per reader pid
  /usr/bin/python3 "$ROOT_DIR/script/lib/proc-rusage.py" "$APP_PID" $(reader_pids) 2>>"$ERRORS" \
    | sed "s/^{/{\"snapshot\": \"$n\", \"label\": \"$label\", \"epoch\": $(date +%s), /" >> "$RAW/rusage.ndjson" \
    || fail_note "rusage snapshot=$n"
  /usr/bin/python3 "$ROOT_DIR/script/lib/proc-rusage.py" --all > "$RAW/all-$n.ndjson" 2>>"$ERRORS" || true
  /usr/bin/vmmap --summary "$APP_PID" > "$RAW/vmmap-$n.txt" 2>&1 || fail_note "vmmap snapshot=$n"
  /usr/bin/footprint "$APP_PID" > "$RAW/footprint-$n.txt" 2>&1 || fail_note "footprint snapshot=$n"
  {
    /usr/bin/vm_stat
    /usr/sbin/sysctl vm.swapusage kern.memorystatus_vm_pressure_level kern.memorystatus_level hw.memsize
  } > "$RAW/vm-$n.txt" 2>&1 || fail_note "vm_stat snapshot=$n"
  /usr/bin/top -l 2 -s 1 -o cpu -n 25 -stats pid,command,cpu,mem,power,threads,state > "$RAW/top-cpu-$n.txt" 2>&1 \
    || fail_note "top snapshot=$n"
  /usr/bin/top -l 1 -o mem -n 25 -stats pid,command,cpu,mem,power,threads,state > "$RAW/top-mem-$n.txt" 2>&1 \
    || fail_note "top-mem snapshot=$n"
  pids=""
  for name in $NEIGHBOURS; do
    for pid in $(pgrep -x "$name" 2>/dev/null || true); do pids="$pids -pid $pid"; done
  done
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086 # one -pid flag per process
    /usr/bin/top -l 1 $pids -stats pid,command,mem,cpu,power > "$RAW/neighbours-$n.txt" 2>&1 \
      || fail_note "neighbours snapshot=$n"
  fi
  /usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out > "$RAW/nettop-$n.csv" 2>&1 || fail_note "nettop snapshot=$n"
  peak_capture "$n"
}

# heap(1) and sample(1) at each new footprint high at least 25 % above the last one taken
# and above --peak-floor-mb, so the capture lands near the peak without walking the heap each time.
peak_capture() {
  local n="$1" footprint started
  footprint="$(grep "\"pid\": $APP_PID," "$RAW/rusage.ndjson" 2>/dev/null | tail -n 1 \
    | sed -nE 's/.*"phys_footprint_bytes": ([0-9]+).*/\1/p')"
  footprint="${footprint:-0}"
  (( footprint > PEAK_TAKEN * 5 / 4 && footprint > PEAK_FLOOR_MB * 1024 * 1024 )) || return 0
  PEAK_TAKEN="$footprint"
  event peak footprint "n=$n bytes=$footprint"
  /usr/bin/sample "$APP_PID" 5 -file "$RAW/sample-peak-$n.txt" > /dev/null 2>&1 || fail_note "sample peak n=$n"
  if [[ "$WANT_HEAP" == 1 ]]; then
    started="$(date +%s)"
    /usr/bin/heap -s -q "$APP_PID" > "$RAW/heap-$n.txt" 2>&1 || fail_note "heap n=$n"
    event heap "n=$n" "seconds=$(( $(date +%s) - started ))"
  fi
}

count_lines() { grep -cE "$1" "$RAW/log.ndjson" 2>/dev/null || true; }

# ── The session ──────────────────────────────────────────────────────────────
TIMED="15 30 60 180"
TOUR_SEEN=0
TOUR_STEPS_SEEN=0
STALLS_SEEN=0
STALL_SAMPLES=0
DESCRIPTION_SEEN=0
while kill -0 "$APP_PID" 2>/dev/null; do
  elapsed=$(( $(date +%s) - SESSION_START ))
  due=""
  for offset in $TIMED; do
    if (( elapsed >= offset )); then due="$offset"; fi
  done
  if [[ -n "$due" ]]; then
    TIMED="$(tr ' ' '\n' <<<"$TIMED" | awk -v d="$due" '$1 > d' | tr '\n' ' ')"
    snapshot "t+${due}s"
  fi
  if (( TOUR_SEEN == 0 )) && [[ "$(count_lines 'op=tour')" != 0 ]]; then
    TOUR_SEEN=1
    event tour seen
  fi
  steps="$(count_lines 'op=tour phase=step')"
  while (( ${steps:-0} > TOUR_STEPS_SEEN )); do
    TOUR_STEPS_SEEN=$((TOUR_STEPS_SEEN + 1))
    step="$(grep 'op=tour phase=step' "$RAW/log.ndjson" | sed -n "${TOUR_STEPS_SEEN}p" \
      | grep -oE 'step=[A-Za-z][A-Za-z0-9._-]{0,39}' | head -n 1 | cut -d= -f2 || true)"
    snapshot "tour-${TOUR_STEPS_SEEN}${step:+-$step}"
  done
  if (( DESCRIPTION_SEEN == 0 )) && [[ "$(count_lines 'op=description ')" != 0 ]]; then
    DESCRIPTION_SEEN=1
    snapshot "description-first"
  fi
  stalls="$(count_lines 'op=mainThreadStall |op=catalog\.store\.stall ')"
  if (( ${stalls:-0} > STALLS_SEEN && STALL_SAMPLES < 3 )); then
    STALLS_SEEN="$stalls"
    STALL_SAMPLES=$((STALL_SAMPLES + 1))
    event stall sample "n=$STALL_SAMPLES"
    /usr/bin/sample "$APP_PID" 5 -file "$RAW/sample-stall-$STALL_SAMPLES.txt" > /dev/null 2>&1 \
      || fail_note "sample stall n=$STALL_SAMPLES"
  fi
  if (( TOUR_SEEN == 1 )); then
    if (( elapsed >= TOUR_DEADLINE )); then event session deadline tour; break; fi
  elif (( elapsed >= DURATION )); then
    event session deadline duration
    break
  fi
  # time: poll — one pass over the log and the process each second; nothing pushes these
  sleep 1
done
if kill -0 "$APP_PID" 2>/dev/null; then
  snapshot "end"
  event session end appRunning
else
  event session end appExited
fi
SESSION_END="$(date +%s)"

# Recorders stop before sizing and summarizing; cleanup's pass then finds them stopped
# and still quits the app if this run launched it.
stop_trace "$XCTRACE_PID" "$RAW/xctrace.log" "$RAW/cpu.trace"; XCTRACE_PID=""
stop_trace "$ALLOC_PID" "$RAW/xctrace-allocations.log" "$RAW/allocations.trace"; ALLOC_PID=""
quit_launched_app || true
stop_recorder "$IOSTAT_PID" TERM; IOSTAT_PID=""
stop_recorder "$LOG_PID" TERM; LOG_PID=""
size_files "$RAW/files-after.tsv"

if [[ -d "$RAW/cpu.trace" ]]; then
  TMPDIR="$TRACE_TMP/" "$ROOT_DIR/script/profile-export.sh" "$RAW/cpu.trace" --toc > "$RAW/cpu-toc.xml" 2>>"$ERRORS" || fail_note "export toc"
  TMPDIR="$TRACE_TMP/" "$ROOT_DIR/script/profile-export.sh" "$RAW/cpu.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
    > "$RAW/time-profile.xml" 2>>"$ERRORS" || fail_note "export time-profile"
else
  fail_note "cpu.trace missing (raw/xctrace.log says why)"
fi

cat > "$RAW/session.json" <<EOF
{"mode": "$MODE", "pid": $APP_PID, "bundle_id": "$BUNDLE_ID", "repo_revision": "$REVISION",
 "session_start": $SESSION_START, "session_end": $SESSION_END, "tour_seen": $TOUR_SEEN,
 "tour_steps": $TOUR_STEPS_SEEN, "heap": $WANT_HEAP, "peak_floor_mb": $PEAK_FLOOR_MB, "allocations": $WANT_ALLOCATIONS,
 "sandbox_home": $([[ -n "$HOME_DIR" ]] && echo true || echo false)}
EOF
/usr/bin/python3 -I "$ROOT_DIR/script/lib/survey-summary.py" "$OUT_DIR" || fail_note "summary"
echo "op=survey.session phase=finish out=$OUT_DIR summary=$OUT_DIR/summary.md"
