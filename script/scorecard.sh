#!/usr/bin/env bash
# The scorecard: what one Otos session felt like, read from the unified log (ADR 0015).
#
# A report, never a gate: it is not part of script/check.sh and is not a benchmark. It
# reads the log unsandboxed with /usr/bin/log show; the parsing lives in
# script/lib/scorecard.py and is tested by script/lib/scorecard_test.py.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"
source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/build-folder.sh"
APP_NAME="Otos"
SUBSYSTEM="net.melisma.Otos"
INSTALLED_APP="/Applications/Otos.app"
DEV_APP="$ROOT_DIR/build/DerivedData/Build/Products/Debug/Otos.app"
# The dev build compiled the way the installed app is (--optimized), in a folder of its own.
OPTIMIZED_DERIVED_DATA="$ROOT_DIR/build/OptimizedDerivedData"
TARGETS="$ROOT_DIR/docs/scorecard-targets.json"
PARSER="$ROOT_DIR/script/lib/scorecard.py"
SCORECARDS="$ROOT_DIR/build/scorecards"

usage() {
  cat <<'EOF'
usage:
  script/scorecard.sh [--dev] [--last 1h] [--session <id>] [--json <out>] [--compare <saved.json>]
      The newest session of the installed app (--dev: the dev build) in the last hour.
  script/scorecard.sh --input <log.ndjson> [--dev] [--session <id>] [--json <out>] [--compare <saved.json>]
      A saved `log show --style ndjson` capture.
  script/scorecard.sh --tour [--dev [--optimized] [--home <dir>] [--seed <photos>]] [--ablate none|all|<owner>[,<owner>…]]
                      [--steps full|scopes] [--idle <seconds>] [--deadline <seconds a step>] [--compare <saved.json>]
      Launches the app with OTOS_TOUR=1, waits for it to finish its read-only tour and quit,
      prints that session's scorecard and saves it under build/scorecards/.
  script/scorecard.sh --ablation-matrix [--dev [--home <dir>] [--seed <photos>]]
      Short tours with every background owner off (the floor), with each owner alone
      running, and with none off; prints one table.

Owners: enrichment metadataRefresh renderSignatures previewFaces placeNames searchIndex
descriptions duplicates people immich. --home gives the dev build a sandbox home
(CFFIXED_USER_HOME and HOME). --seed <photos> makes a fresh sandbox home (at --home, which
must not exist, or under build/sandbox-homes/) with a library of that many generated photos
on a volume of its own (script/sandbox-library.sh), has the app register it through its own
Add Library intent, and removes all of it when the run ends, however it ends. The tour's act
steps (Move to Trash and Put Back among them) run only on such a library: on any other the
app skips them (`trashOutsideSandbox`), because a sandbox home on the account's volume
trashes into the account's own Trash. After every tour in a sandbox library the account's
Trash is tested for each generated file by name; one found there is removed and the run
fails. --optimized first builds the dev app with the installed app's settings (-O, no
coverage, no debug dylib; ADR 0030) into build/OptimizedDerivedData and tours that build:
the dev bundle id, never /Applications. The tour never runs while Otos is already running.
EOF
}

OWNERS=(enrichment metadataRefresh renderSignatures previewFaces placeNames searchIndex descriptions duplicates people immich)

DEV=0
LAST="1h"
SESSION=""
INPUT=""
JSON_OUT=""
COMPARE=""
TOUR=0
MATRIX=0
ABLATE="none"
STEPS="full"
IDLE=""
DEADLINE=""
HOME_DIR=""
SEED=""
OPTIMIZED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) DEV=1; shift ;;
    --optimized) OPTIMIZED=1; shift ;;
    --last) LAST="${2:?}"; shift 2 ;;
    --session) SESSION="${2:?}"; shift 2 ;;
    --input) INPUT="${2:?}"; shift 2 ;;
    --json) JSON_OUT="${2:?}"; shift 2 ;;
    --compare) COMPARE="${2:?}"; shift 2 ;;
    --tour) TOUR=1; shift ;;
    --ablation-matrix) MATRIX=1; shift ;;
    --ablate) ABLATE="${2:?}"; shift 2 ;;
    --steps) STEPS="${2:?}"; shift 2 ;;
    --idle) IDLE="${2:?}"; shift 2 ;;
    --deadline) DEADLINE="${2:?}"; shift 2 ;;
    --home) HOME_DIR="${2:?}"; shift 2 ;;
    --seed) SEED="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$OPTIMIZED" == 1 && ( "$DEV" != 1 || "$TOUR$MATRIX" == "00" ) ]]; then
  echo "--optimized is for a dev tour (--tour or --ablation-matrix with --dev)." >&2
  exit 2
fi

# Builds the dev app the way script/install.sh builds the installed one, so a sandbox tour
# measures the code the owner runs, and points DEV_APP at it. Its own DerivedData, held for
# this run, so a check's or an install's build folder is never touched.
build_optimized_dev_app() {
  otos_require_full_xcode
  otos_hold_build_folder "$OPTIMIZED_DERIVED_DATA" scorecard.build
  echo "op=scorecard.build phase=start folder=$OPTIMIZED_DERIVED_DATA optimization=-O" >&2
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/Otos.xcodeproj" \
    -scheme Otos \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$OPTIMIZED_DERIVED_DATA" \
    ENABLE_CODE_COVERAGE=NO \
    ENABLE_DEBUG_DYLIB=NO \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    build >&2
  DEV_APP="$OPTIMIZED_DERIVED_DATA/Build/Products/Debug/Otos.app"
  local built_id
  built_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEV_APP/Contents/Info.plist")"
  if [[ "$built_id" != "net.melisma.Otos.dev" ]]; then
    echo "op=scorecard.build phase=failed reason=bundleID built=$built_id expected=net.melisma.Otos.dev" >&2
    exit 1
  fi
  echo "op=scorecard.build phase=finish app=$DEV_APP" >&2
}
[[ "$OPTIMIZED" == 1 ]] && build_optimized_dev_app

# ── A sandbox library ───────────────────────────────────────────────────────────
# With --seed the run makes the sandbox home and its library, and its EXIT trap removes them
# once no process of the toured app remains. A --home that script/sandbox-library.sh made is
# toured with its library and kept. Either way every tour in it ends with the Trash check.
SANDBOX_LIBRARY_SCRIPT="$ROOT_DIR/script/sandbox-library.sh"
SANDBOX_LIBRARY=""
SANDBOX_OWNED=0
TRASH_DIRTY=0
if [[ -n "$SEED" ]]; then
  if [[ "$DEV" != 1 || "$TOUR$MATRIX" == "00" ]]; then
    echo "--seed is for a dev tour (--tour or --ablation-matrix with --dev)." >&2
    exit 2
  fi
  [[ -n "$HOME_DIR" ]] || HOME_DIR="$ROOT_DIR/build/sandbox-homes/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$(dirname "$HOME_DIR")"
  # Refuses, and makes nothing, when it cannot give the library a volume of its own.
  "$SANDBOX_LIBRARY_SCRIPT" create --home "$HOME_DIR" --count "$SEED" >&2
  HOME_DIR="$(cd "$HOME_DIR" && pwd -P)"
  SANDBOX_OWNED=1
fi
if [[ -n "$HOME_DIR" && -f "$HOME_DIR/.otos-sandbox-library" ]]; then
  SANDBOX_LIBRARY="$(/usr/bin/sed -n 's/^library=//p' "$HOME_DIR/.otos-sandbox-library")"
elif [[ -n "$HOME_DIR" ]]; then
  echo "op=scorecard.sandbox phase=noLibraryVolume home=$HOME_DIR — not a sandbox library (script/sandbox-library.sh): the app skips every act step (trashOutsideSandbox)" >&2
fi

# Tests the account's Trash for every file the sandbox library generated; remembers a failure.
check_sandbox_trash() {
  [[ -n "$SANDBOX_LIBRARY" ]] || return 0
  if ! "$SANDBOX_LIBRARY_SCRIPT" check-trash --home "$HOME_DIR" >&2; then
    TRASH_DIRTY=1
    echo "op=scorecard.sandbox phase=FAILED reason=filesInAccountTrash — removed and named above; this is a defect: no tour file may reach the account's Trash" >&2
  fi
}

# The EXIT trap of a --seed run: never while the toured app runs, so a volume is never pulled
# from under it. A run whose app will not quit leaves the home and says so.
remove_seeded_home() {
  local status=$?
  [[ "$TRASH_DIRTY" == 1 ]] && status=1
  [[ "$SANDBOX_OWNED" == 1 ]] || exit "$status"
  local executable="$DEV_APP/Contents/MacOS/$APP_NAME"
  if pgrep -f "^$executable" >/dev/null; then
    echo "op=scorecard.sandbox phase=kept home=$HOME_DIR reason=appStillRunning — quit it, then: script/sandbox-library.sh destroy --home $HOME_DIR" >&2
    exit 1
  fi
  if ! "$SANDBOX_LIBRARY_SCRIPT" destroy --home "$HOME_DIR" >&2; then
    status=1
  fi
  [[ "$TRASH_DIRTY" == 1 ]] && status=1
  exit "$status"
}
trap remove_seeded_home EXIT

parser_args() {
  local args=(--targets "$TARGETS")
  [[ "$DEV" == 1 ]] && args+=(--dev)
  [[ -n "$SESSION" ]] && args+=(--session "$SESSION")
  [[ -n "$JSON_OUT" ]] && args+=(--json "$JSON_OUT")
  [[ -n "$COMPARE" ]] && args+=(--compare "$COMPARE")
  printf '%s\n' "${args[@]}"
}

run_parser() {
  local input="$1"
  shift
  local args=()
  while IFS= read -r line; do args+=("$line"); done < <(parser_args)
  /usr/bin/python3 -I "$PARSER" --input "$input" "${args[@]}" "$@"
}

capture() {
  # Writes the ndjson of every Otos line in the window to $1.
  local out="$1"
  shift
  /usr/bin/log show --style ndjson --info --debug "$@" \
    --predicate "process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\"" > "$out"
}

# ── One tour ───────────────────────────────────────────────────────────────────
# Launches the app with the tour flag and its options, waits on the app's own report that
# the tour finished (or the process ending), confirms it quit, and leaves the session's
# ndjson at $TOUR_NDJSON and its pid at $TOUR_PID.
run_one_tour() {
  local ablate="$1" steps="$2"
  local app="$INSTALLED_APP"
  [[ "$DEV" == 1 ]] && app="$DEV_APP"
  [[ -x "$app/Contents/MacOS/$APP_NAME" ]] || { echo "No app at $app" >&2; exit 1; }
  if [[ "$DEV" != 1 && -n "$HOME_DIR" ]]; then
    echo "--home is for the dev build only: the installed app is toured on the owner's own library." >&2
    exit 2
  fi
  # An instance of this app already running is a session someone is in: refuse, never adopt
  # or quit it. Another build's instance (another worktree's dev app) writes lines under its
  # own pid, which this run never reads.
  local executable="$app/Contents/MacOS/$APP_NAME"
  if pgrep -f "^$executable" >/dev/null; then
    echo "Cannot start the tour: $executable is already running (pid $(pgrep -f "^$executable" | tr '\n' ' '))." >&2
    echo "Quit it first; the tour never quits an app it did not launch." >&2
    exit 1
  fi
  # The idle length and step deadline are always passed, so the silence limit below follows
  # from exactly what this tour was asked to do. Unset, they are the app's own defaults
  # (`SmokeTour.Configuration`): a 60 s idle for the full tour, none for the scopes, and a
  # 120 s deadline a step.
  local idle="$IDLE" deadline="${DEADLINE:-120}"
  if [[ -z "$idle" ]]; then
    idle=0
    [[ "$steps" == full ]] && idle=60
  fi
  local silence_limit
  silence_limit="$(/usr/bin/python3 -I "$PARSER" --tour-silence-limit "$idle" "$deadline")"
  local env_args=(OTOS_TOUR=1 "OTOS_TOUR_ABLATE=$ablate" "OTOS_TOUR_STEPS=$steps"
    "OTOS_TOUR_IDLE_SECONDS=$idle" "OTOS_TOUR_STEP_DEADLINE_SECONDS=$deadline")
  [[ -n "$HOME_DIR" ]] && env_args+=("CFFIXED_USER_HOME=$HOME_DIR" "HOME=$HOME_DIR")
  [[ -n "$SANDBOX_LIBRARY" ]] && env_args+=("OTOS_SANDBOX_LIBRARY=$SANDBOX_LIBRARY")
  # The dev build's saved window state is the account's, not the sandbox home's (AppKit keeps
  # it per bundle id through its restoration service), and every worktree's dev build shares
  # that id. A session that last quit with the window closed restores no window, so the
  # window never attaches and the tour, which starts with it, never runs: a dev tour opens
  # its window fresh.
  local app_args=()
  [[ "$DEV" == 1 ]] && app_args+=(-ApplePersistenceIgnoreState YES)
  local started
  started="$(date '+%Y-%m-%d %H:%M:%S')"
  otos_log_stream_open "process == \"$APP_NAME\" AND subsystem == \"$SUBSYSTEM\" AND eventMessage BEGINSWITH \"op=tour \""
  env "${env_args[@]}" "$app/Contents/MacOS/$APP_NAME" ${app_args[@]+"${app_args[@]}"} >/dev/null 2>&1 3<&- &
  TOUR_PID="$!"
  echo "op=scorecard.tour phase=launched pid=$TOUR_PID ablate=$ablate steps=$steps idleSeconds=$idle deadlineSeconds=$deadline silenceLimitSeconds=$silence_limit app=$app" >&2
  local line="" quiet=0 ended=0
  # The tour reports each step and its finish, and the process's exit ends the wait too: the
  # stream is read in 10 s slices only so an exit is noticed between them. A stream quiet for
  # longer than the tour's longest silent stretch (its idle or a step's deadline, plus a
  # margin: `tour_silence_limit` in scorecard.py) means the tour is stuck. time: deadline
  # Only this run's process: another Otos touring at the same time (another worktree's dev
  # build, or the installed app) logs the same lines under its own pid (`Otos[pid:tid]`).
  local own_tour_line="\\[${TOUR_PID}:[^]]*\\].*op=tour (phase=(finish|step|config|failed|plan|restored|library))"
  while kill -0 "$TOUR_PID" 2>/dev/null; do
    if ! line="$(otos_log_stream_await "$own_tour_line" 10)"; then
      quiet=$((quiet + 10))
      if (( quiet >= silence_limit )); then
        echo "op=scorecard.tour phase=silent pid=$TOUR_PID silenceLimitSeconds=$silence_limit — no tour line for $quiet s (if none came at all, the window never attached: the tour starts with it)" >&2
        break
      fi
      continue
    fi
    quiet=0
    case "$line" in
      *"phase=step"*) echo "  ${line#*op=tour }" >&2 ;;
      *"phase=finish"*|*"phase=failed"*) echo "  ${line#*op=tour }" >&2; ended=1; break ;;
    esac
  done
  otos_log_stream_close
  if [[ "${ended:-0}" != 1 ]]; then
    echo "op=scorecard.tour phase=endedWithoutFinish pid=$TOUR_PID — the app exited or went silent before its tour finished" >&2
  fi
  # The tour quits the app itself: wait on its exit, as this script's child. A watcher asks
  # it to quit, and says so, only if it has not exited a minute after the tour ended.
  local bundle_id="net.melisma.Otos"
  [[ "$DEV" == 1 ]] && bundle_id="net.melisma.Otos.dev"
  (
    # time: deadline — an app that does not quit after its tour is told to, and reported
    sleep 60
    if kill -0 "$TOUR_PID" 2>/dev/null; then
      echo "op=scorecard.tour phase=quitByScript pid=$TOUR_PID reason=appDidNotQuitAfterTour" >&2
      if [[ "$DEV" == 1 ]]; then
        # Another worktree's dev app shares the bundle id; only this run's pid is told.
        kill -TERM "$TOUR_PID" 2>/dev/null || true
      else
        /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
      fi
    fi
  ) &
  local watcher="$!"
  wait "$TOUR_PID" 2>/dev/null || true
  pkill -P "$watcher" 2>/dev/null || true
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  # The app and its text-reading child (`Otos --read-text`) run from this executable.
  if pgrep -f "^$executable" >/dev/null; then
    echo "op=scorecard.tour phase=stillRunning pids=$(pgrep -f "^$executable" | tr '\n' ',') — the app or its --read-text child is still running" >&2
  else
    echo "op=scorecard.tour phase=quit pid=$TOUR_PID confirmed=noProcessOf=$executable" >&2
  fi
  check_sandbox_trash
  TOUR_NDJSON="$(mktemp -t otos-tour)"
  capture "$TOUR_NDJSON" --start "$started"
}

save_path() {
  local label="$1"
  mkdir -p "$SCORECARDS"
  local revision
  revision="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "$SCORECARDS/$(date -u +%Y%m%dT%H%M%SZ)-$revision-$label.json"
}

if [[ "$MATRIX" == 1 ]]; then
  configs=("all")
  for owner in "${OWNERS[@]}"; do
    others=()
    for other in "${OWNERS[@]}"; do [[ "$other" == "$owner" ]] || others+=("$other"); done
    configs+=("$(IFS=,; echo "${others[*]}")")
  done
  configs+=("none")
  echo "op=scorecard.matrix phase=start launches=${#configs[@]} steps=scopes — each launch runs the sidebar steps once, waits on each paint (deadline 120 s a step) and quits; expect about ${#configs[@]} × (launch + tour) — the first run's length below sets the estimate" >&2
  files=()
  labels=()
  for config in "${configs[@]}"; do
    run_one_tour "$config" scopes
    label="$config"
    [[ "$config" == "all" ]] && label="floor(all off)"
    [[ "$config" == "none" ]] && label="none off"
    for owner in "${OWNERS[@]}"; do
      [[ "$config" == *","* && ",$config," != *",$owner,"* ]] && label="$owner only"
    done
    out="$(save_path "matrix-${label//[^A-Za-z]/}")"
    JSON_OUT="$out"
    run_parser "$TOUR_NDJSON" --pid "$TOUR_PID" > /dev/null
    rm -f "$TOUR_NDJSON"
    files+=("$out")
    labels+=("$label")
  done
  /usr/bin/python3 -I "$ROOT_DIR/script/lib/scorecard.py" --matrix "${files[@]}" --labels "$(IFS='|'; echo "${labels[*]}")"
  exit 0
fi

if [[ "$TOUR" == 1 ]]; then
  run_one_tour "$ABLATE" "$STEPS"
  [[ -n "$JSON_OUT" ]] || JSON_OUT="$(save_path tour)"
  run_parser "$TOUR_NDJSON" --pid "$TOUR_PID"
  rm -f "$TOUR_NDJSON"
  exit 0
fi

if [[ -n "$INPUT" ]]; then
  run_parser "$INPUT"
  exit 0
fi

NDJSON="$(mktemp -t otos-scorecard)"
trap 'rm -f "$NDJSON"' EXIT
capture "$NDJSON" --last "$LAST"
run_parser "$NDJSON"
