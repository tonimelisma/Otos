#!/usr/bin/env bash
# Launches an Otos build on a library of generated media and captures its main window in each
# of its views, light and dark, as PNGs (ADR 0061):
#
#   script/app-capture.sh <Otos.app> <output folder> [photos [view...]]
#
# The views: `library` (the library's grid), `places` (the map), `on-this-day`, `duplicates`,
# and `edit` (the grid with the Edit pane open on its first still); all of them unless some
# are named.
# People is not captured: the generated photos hold no faces (owner, 2026-11-27). The
# library's photos include what each view needs: some with GPS, some on today's day in past
# years, an exact copy and a re-encoded version (script/sandbox-library-media.swift).
#
# It is the look a session with no Mac reads (CI's App Captures job uploads the folder), and
# the launch check a release passes before it publishes (script/release.sh): an app that
# cannot reach its first grid and draw its window writes no capture, and this fails.
#
# One launch per appearance walks every view, each launch in a sandbox home of its own
# (script/sandbox-library.sh: a library of generated photos on a disk image of its own). The
# app registers the library through its own Add Library intent (`OTOS_SANDBOX_LIBRARY`), and
# its capture seam (ADR 0020) walks the views it is asked for (`OTOS_SMOKE_CAPTURE_VIEWS`):
# it selects each through the sidebar's intent, waits until the window shows it with what it
# holds, writes its own rendering and logs `op=smoke.capture phase=finish view=… appearance=…`
# (or `failed`), then waits for this script's go-ahead (`SIGUSR1`). That rendering is drawn
# with `cacheDisplay`, which leaves out layer-backed content (the grid's tiles, the map) and
# everything outside the content view (the toolbar), so it is the readiness signal and a
# fallback; the capture to read is the window as the screen composes it (`screencapture -l`,
# the window found by the app's pid), `<view>-<appearance>.png`. Every wait is on the app's
# reports, from this launch's process only. Then it quits that process and waits for its
# exit. It writes nothing outside the sandbox home and the output folder, launches nothing
# beside the app, and removes the sandbox however it ends. Lines: `op=appCapture phase=…`,
# one `op=appCapture phase=written` per PNG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"

usage() {
  echo "usage: script/app-capture.sh <Otos.app> <output folder> [photos [library|places|on-this-day|duplicates|edit]...]" >&2
  exit 2
}
[[ $# -ge 2 ]] || usage
APP="$(cd "$1" && pwd -P)" || usage
OUT="$2"
PHOTOS="${3:-120}"
[[ "$PHOTOS" =~ ^[1-9][0-9]*$ ]] || usage
shift $(( $# >= 3 ? 3 : 2 ))
VIEWS=("$@")
[[ ${#VIEWS[@]} -gt 0 ]] || VIEWS=(library places on-this-day duplicates edit)

for view in "${VIEWS[@]}"; do
  case "$view" in
    library | places | on-this-day | duplicates | edit) ;;
    *) echo "op=appCapture phase=failed reason=unknownView view=$view" >&2; usage ;;
  esac
done
APPEARANCES=(light dark)
EXECUTABLE="$APP/Contents/MacOS/Otos"
SUBSYSTEM="net.melisma.Otos"
[[ -x "$EXECUTABLE" ]] || { echo "op=appCapture phase=failed reason=noExecutable app=$APP" >&2; exit 1; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

# The bundle as signed: a broken or missing seal fails here, before anything launches.
if ! /usr/bin/codesign --verify --deep --strict "$APP" 2>&1; then
  echo "op=appCapture phase=failed reason=signature app=$APP" >&2
  exit 1
fi
echo "op=appCapture phase=signature outcome=valid app=$APP"

HOMES_DIR="$ROOT_DIR/build/capture-homes/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$HOMES_DIR"
APP_PID=""

# Ends a launch's process: a TERM, then a wait for the kernel to report it gone (a zombie
# child counts as gone; `wait` reaps it), then a KILL after twenty seconds. A process that
# outlives even the KILL is stuck in the kernel. On CI's virtual Mac that is the
# paravirtualized VideoToolbox driver: as the exiting process's video sessions are torn down
# it messages the VM's host and sleeps until the host answers, which it sometimes never does
# (docs/research/2026-11-27-a-capture-launch-stuck-in-the-vms-video-driver.md). The process
# keeps its memory-mapped files, so its home's volume stays mounted; a home of its own for
# each run keeps that from reaching the next run. Such a process is never waited on. What it
# is stuck on is written beside the captures: its threads' kernel and user stacks
# (`spindump`, which reads an exiting process where `sample` cannot attach) and its open
# files (`lsof`). Both need root, which CI's runner grants without a password (`sudo -n`);
# where it is refused, the refusal is the record. The capture, already written, stands.
gone() {
  local state
  state="$(/bin/ps -o stat= -p "$1" 2>/dev/null)"
  [[ -z "$state" || "$state" == Z* ]]
}

# Waits up to <tenths> tenths of a second for <pid> to be gone; returns 1 if it is not.
wait_gone() {
  local pid="$1" tenths="$2" waited=0
  until gone "$pid"; do
    (( waited >= tenths )) && return 1
    # time: deadline — the kernel reports the exit by the process being gone
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
}

end_app() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  wait_gone "$pid" 200 && return 0
  echo "op=appCapture phase=killed pid=$pid reason=outlivedTerm waitedSeconds=20" >&2
  kill -KILL "$pid" 2>/dev/null || true
  wait_gone "$pid" 100 && return 0
  echo "op=appCapture phase=unkillable pid=$pid state=\"$(/bin/ps -o stat=,etime= -p "$pid" 2>/dev/null | tr -s ' ')\"" >&2
  local stacks="$OUT/unkillable-$pid.spindump.txt" files="$OUT/unkillable-$pid.lsof.txt"
  /usr/bin/sudo -n /usr/sbin/lsof -n -w -p "$pid" > "$files" 2>&1 || true
  /usr/bin/sudo -n /usr/sbin/spindump "$pid" 2 -file "$stacks" > "$stacks.log" 2>&1 &
  local dumper="$!"
  # time: deadline — spindump samples for two seconds, then symbolicates; it reports its end
  # by exiting.
  wait_gone "$dumper" 900 || kill -KILL "$dumper" 2>/dev/null || true
  if [[ -s "$stacks" ]]; then
    echo "op=appCapture phase=stacks pid=$pid file=$stacks openFiles=$files" >&2
  else
    echo "op=appCapture phase=stacks pid=$pid outcome=none detail=\"$(tr '\n' ' ' < "$stacks.log" | cut -c1-200)\" openFiles=$files" >&2
  fi
  return 0
}

cleanup() {
  otos_log_stream_close
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    end_app "$APP_PID"
  fi
  local home
  for home in "$HOMES_DIR"/*; do
    [[ -d "$home" ]] || continue
    "$ROOT_DIR/script/sandbox-library.sh" destroy --home "$home" || true
  done
  rmdir "$HOMES_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# The number of the largest on-screen, normal-level window the process owns, through
# CoreGraphics from JavaScript for Automation: numbers, owners and bounds need no Screen
# Recording grant, and nothing here scripts another app.
window_number() {
  /usr/bin/osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = parseInt(argv[0], 10);
  const windows = ObjC.deepUnwrap(ObjC.castRefToObject(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
  const own = (windows || []).filter(w => w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0);
  own.sort((a, b) => b.kCGWindowBounds.Width * b.kCGWindowBounds.Height
    - a.kCGWindowBounds.Width * a.kCGWindowBounds.Height);
  return own.length ? String(own[0].kCGWindowNumber) : '';
}
JXA
}

# One step: waits for the seam's report that the window shows the step's view in its
# appearance (for the library's grid, also for its tiles drawn), then captures the window as the
# screen shows it. Sets STEP_STATUS.
capture_step() {
  local view="$1" appearance="$2" own="$3" line="" rendered=0 number=""
  local png="$OUT/$view-$appearance.png"
  STEP_STATUS=0
  # Two reports, in either order, for the grid: the app's own rendering (`op=smoke.capture`),
  # and the grid's tiles drawn (`op=ui.mediaGrid.visibleThumbnails phase=complete`: every
  # visible tile shows what the catalog holds for it). The state can hold photos a second
  # before the grid draws them; a screen capture taken then shows an empty grid (run
  # 45864653887, dark). The tiles report comes once, whichever step it arrives in.
  # time: deadline — the grid fills as the library's first walk lands, and each view's facts
  # as enrichment reads the photos; reports that never come mean it never showed them.
  while [[ "$rendered" == 0 || ( "$view" == library && -z "$TILES" ) ]]; do
    if ! line="$(otos_log_stream_await "$own.*(op=smoke.capture phase=|op=ui.mediaGrid.visibleThumbnails phase=complete)" 120)"; then
      echo "op=appCapture phase=failed reason=noCapture view=$view appearance=$appearance rendered=$rendered tiles=${TILES:-none}" >&2
      STEP_STATUS=1
      return 0
    fi
    case "$line" in
      *"op=smoke.capture phase=finish view=$view appearance=$appearance "*)
        rendered=1
        echo "op=appCapture phase=rendered view=$view appearance=$appearance"
        ;;
      *"op=smoke.capture phase=start"* | *"op=smoke.capture phase=selected"* | *"op=smoke.capture phase=waiting"* | *"op=smoke.capture phase=editorShown"* \
        | *"op=smoke.capture phase=presented"* | *"op=smoke.capture phase=thumbnailsRendered"* | *"op=smoke.capture phase=detailReadFailed"* \
        | *"op=smoke.capture phase=editorOriginalUnreadable"*)
        echo "op=appCapture phase=progress ${line#*op=smoke.capture }"
        ;;
      *"op=smoke.capture"*)
        echo "op=appCapture phase=failed reason=captureFailed view=$view appearance=$appearance ${line#*op=smoke.capture }" >&2
        STEP_STATUS=1
        return 0
        ;;
      *)
        TILES="${line#*phase=complete }"
        echo "op=appCapture phase=tiles $TILES"
        ;;
    esac
  done
  number="$(window_number "$APP_PID" || true)"
  echo "op=appCapture phase=window view=$view appearance=$appearance number=${number:-none}"
  if [[ -z "$number" ]] || ! /usr/sbin/screencapture -x -o -l "$number" "$png" || [[ ! -s "$png" ]]; then
    echo "op=appCapture phase=failed reason=screenCapture view=$view appearance=$appearance window=${number:-none}" >&2
    STEP_STATUS=1
    return 0
  fi
  echo "op=appCapture phase=written view=$view appearance=$appearance path=$png bytes=$(/usr/bin/stat -f %z "$png") $(/usr/bin/sips -g pixelWidth -g pixelHeight "$png" | /usr/bin/awk '/pixel/ { sub(":", "", $1); printf "%s=%s ", $1, $2 }')"
}

# One launch in one appearance, set from its start: an appearance switched mid-launch is still
# animating the toolbar's glass when the next capture is taken (run 45947165362, edit light),
# and nothing reports that animation's end. Each launch has a sandbox home of its own, made
# before and removed after it, so a launch that cannot end holds nothing the next one opens.
# Returns 1 when a step failed.
walk_launch() {
  local appearance="$1" home="$HOMES_DIR/$1" library line index view status=0
  local steps=()
  for view in "${VIEWS[@]}"; do
    steps+=("$view")
    rm -f "$OUT/$view-$appearance.png" "$OUT/$view-$appearance-rendering.png"
  done
  "$ROOT_DIR/script/sandbox-library.sh" create --home "$home" --count "$PHOTOS" --media small
  library="$(/usr/bin/sed -n 's/^library=//p' "$home/.otos-sandbox-library")"
  [[ -n "$library" ]] || { echo "op=appCapture phase=failed reason=noSandboxLibrary home=$home" >&2; return 1; }
  otos_log_stream_open "subsystem == \"$SUBSYSTEM\" AND processImagePath == \"$EXECUTABLE\" AND (eventMessage BEGINSWITH \"op=launch.firstGrid\" OR eventMessage BEGINSWITH \"op=smoke.capture\" OR eventMessage BEGINSWITH \"op=ui.mediaGrid.visibleThumbnails phase=complete\")" debug
  local launched_at
  launched_at="$(/bin/date '+%Y-%m-%d %H:%M:%S')"
  # -ApplePersistenceIgnoreState: AppKit keeps window state per bundle id in the account, not
  # the sandbox home; a session that last quit with no window would restore none. The map's
  # settle is the one wait nothing reports (SmokeWindowCapture's settle): its tiles had drawn
  # 3 s after the stacks in run 45944603274 (a 680-point map) and had not in run 45945839837
  # (an 804-point map, its first fetch), so it is 6 s.
  env HOME="$home" CFFIXED_USER_HOME="$home" OTOS_SANDBOX_LIBRARY="$library" \
    OTOS_SMOKE_CAPTURE_PATH="$OUT" OTOS_SMOKE_CAPTURE_VIEWS="$VIEWS_LIST" \
    OTOS_SMOKE_APPEARANCE="$appearance" OTOS_SMOKE_CAPTURE_SETTLE_SECONDS=6 \
    "$EXECUTABLE" -ApplePersistenceIgnoreState YES > /dev/null 2>&1 3<&- &
  APP_PID="$!"
  echo "op=appCapture phase=launched pid=$APP_PID views=$VIEWS_LIST appearance=$appearance"
  local own="\\[${APP_PID}:[^]]*\\]"
  TILES=""
  # time: deadline — an app that never reaches its first grid reports nothing. Two minutes
  # with no line from it; the launch's measured time is the line's own ms= field.
  if line="$(otos_log_stream_await "$own.*op=launch.firstGrid" 120)"; then
    echo "op=appCapture phase=firstGrid appearance=$appearance ${line#*op=launch.firstGrid }"
    for index in "${!steps[@]}"; do
      view="${steps[$index]}"
      capture_step "$view" "$appearance" "$own"
      if [[ "$STEP_STATUS" != 0 ]]; then
        status=1
        break
      fi
      # The go-ahead: this step's screen capture is written, so the seam may show the next.
      if (( index + 1 < ${#steps[@]} )); then
        if ! kill -USR1 "$APP_PID" 2>/dev/null; then
          echo "op=appCapture phase=failed reason=appGone view=$view appearance=$appearance" >&2
          status=1
          break
        fi
      fi
    done
  else
    echo "op=appCapture phase=failed reason=noFirstGrid appearance=$appearance" >&2
    status=1
  fi
  otos_log_stream_close
  # A failed walk leaves the app's own lines of this launch beside the captures, so a session
  # reading the artifact sees where the walk stopped. The library is generated media.
  if [[ "$status" != 0 ]]; then
    # Whether the library's own volume was still mounted when the walk stopped: an original
    # that vanished (errno 2 in `op=file.status`) with the volume gone is the runner's disk
    # image detaching, not the app (runs 46109184512, 46115028966).
    local volume
    volume="$(/sbin/mount | /usr/bin/grep -F " on $home/TourLibrary " || true)"
    echo "op=appCapture phase=libraryVolume appearance=$appearance mounted=$([[ -n "$volume" ]] && echo true || echo false) files=$(/usr/bin/find "$library" -type f 2>/dev/null | /usr/bin/wc -l | tr -d ' ')" >&2
    /usr/bin/log show --style compact --info --debug --start "$launched_at" \
      --predicate "subsystem == \"$SUBSYSTEM\" AND processImagePath == \"$EXECUTABLE\" AND eventMessage BEGINSWITH \"op=\"" \
      > "$OUT/app-log-$appearance.txt" 2>&1 || true
    echo "op=appCapture phase=appLog path=$OUT/app-log-$appearance.txt lines=$(wc -l < "$OUT/app-log-$appearance.txt" | tr -d ' ')" >&2
  fi
  # Quit this launch's process only; another Otos on the machine is never touched.
  echo "op=appCapture phase=quitting appearance=$appearance pid=$APP_PID"
  end_app "$APP_PID"
  echo "op=appCapture phase=quit appearance=$appearance pid=$APP_PID"
  APP_PID=""
  # Its home goes now, unless a process that cannot end still holds its volume: then it is
  # reported, and tried again as the script ends.
  "$ROOT_DIR/script/sandbox-library.sh" destroy --home "$home" || true
  return "$status"
}

VIEWS_LIST="$(IFS=,; echo "${VIEWS[*]}")"
failed=0
for appearance in "${APPEARANCES[@]}"; do
  walk_launch "$appearance" || failed=1
done
if [[ "$failed" != 0 ]]; then
  echo "op=appCapture phase=finish outcome=failed" >&2
  exit 1
fi
echo "op=appCapture phase=finish outcome=written folder=$OUT captures=$(( ${#VIEWS[@]} * ${#APPEARANCES[@]} ))"
