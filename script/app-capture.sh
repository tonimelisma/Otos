#!/usr/bin/env bash
# Launches an Otos build on a library of generated media and captures its main window, light
# and dark, as PNGs (plan 0118):
#
#   script/app-capture.sh <Otos.app> <output folder> [photos]
#
# It is the look a session with no Mac reads (CI's App Captures job uploads the folder), and
# the launch check a release passes before it publishes (script/release.sh): an app that
# cannot reach its first grid and draw its window writes no capture, and this fails.
#
# For each appearance it launches the app in a sandbox home of that launch's own
# (script/sandbox-library.sh: a library of generated photos on a disk image of its own), so a
# launch that cannot end holds no catalog or volume the next one opens. The app registers it through
# its own Add Library intent (`OTOS_SANDBOX_LIBRARY`), and asks for the app's own rendering
# (`OTOS_SMOKE_CAPTURE_PATH`, ADR 0020). It waits on the app's reports: `op=launch.firstGrid`,
# then `op=smoke.capture phase=finish` (or `failed`), from this launch's process only. That
# rendering is drawn with `cacheDisplay`, which leaves out layer-backed content (the grid's
# tiles) and everything outside the content view (the toolbar), so it is the readiness
# signal and a fallback; the capture to read is the window as the screen composes it
# (`screencapture -l`, the window found by the app's pid). Then it quits that process and
# waits for its exit. It writes nothing outside the sandbox home and
# the output folder, launches nothing beside the app, and removes the sandbox however it
# ends. Lines: `op=appCapture phase=…`, one `op=appCapture phase=written` per PNG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/run-context.sh"

usage() {
  echo "usage: script/app-capture.sh <Otos.app> <output folder> [photos]" >&2
  exit 2
}
[[ $# -ge 2 && $# -le 3 ]] || usage
APP="$(cd "$1" && pwd -P)" || usage
OUT="$2"
PHOTOS="${3:-120}"
[[ "$PHOTOS" =~ ^[1-9][0-9]*$ ]] || usage
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
# keeps its memory-mapped files, so its home's volume stays mounted; a home of its own keeps
# that from reaching the next launch. Such a process is never waited on. What it is stuck on is written beside the captures: its threads' kernel and user
# stacks (`spindump`, which reads an exiting process where `sample` cannot attach) and its
# open files (`lsof`). Both need root, which CI's runner grants without a password (`sudo -n`);
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
    [[ -e "$home" ]] || continue
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

# One launch: waits for the first grid and the app's own rendering, captures the window as
# the screen shows it, quits the app, waits for its exit.
capture_one() {
  local appearance="$1" line="" status=0 scope="unknown" number=""
  local png="$OUT/window-$appearance.png" rendering="$OUT/window-$appearance-rendering.png"
  local home="$HOMES_DIR/$appearance" library
  rm -f "$png" "$rendering"
  "$ROOT_DIR/script/sandbox-library.sh" create --home "$home" --count "$PHOTOS" --media small
  library="$(/usr/bin/sed -n 's/^library=//p' "$home/.otos-sandbox-library")"
  [[ -n "$library" ]] || { echo "op=appCapture phase=failed reason=noSandboxLibrary home=$home" >&2; return 1; }
  otos_log_stream_open "subsystem == \"$SUBSYSTEM\" AND processImagePath == \"$EXECUTABLE\" AND (eventMessage BEGINSWITH \"op=launch.firstGrid\" OR eventMessage BEGINSWITH \"op=smoke.capture\" OR eventMessage BEGINSWITH \"op=ui.mediaGrid.visibleThumbnails phase=complete\")" debug
  # -ApplePersistenceIgnoreState: AppKit keeps window state per bundle id in the account,
  # not the sandbox home; a session that last quit with no window would restore none.
  env HOME="$home" CFFIXED_USER_HOME="$home" OTOS_SANDBOX_LIBRARY="$library" \
    OTOS_SMOKE_CAPTURE_PATH="$rendering" OTOS_SMOKE_APPEARANCE="$appearance" \
    "$EXECUTABLE" -ApplePersistenceIgnoreState YES > /dev/null 2>&1 3<&- &
  APP_PID="$!"
  echo "op=appCapture phase=launched appearance=$appearance pid=$APP_PID"
  local own="\\[${APP_PID}:[^]]*\\]"
  # time: deadline — an app that never reaches its first grid reports nothing. Two minutes
  # with no line from it; the launch's measured time is the line's own ms= field.
  if line="$(otos_log_stream_await "$own.*op=launch.firstGrid" 120)"; then
    echo "op=appCapture phase=firstGrid appearance=$appearance ${line#*op=launch.firstGrid }"
    scope="$(printf '%s' "$line" | /usr/bin/sed -n 's/.*scope=\([^ ]*\).*/\1/p')"
  else
    echo "op=appCapture phase=failed reason=noFirstGrid appearance=$appearance" >&2
    status=1
  fi
  if [[ "$status" == 0 ]]; then
    # Two reports, in either order: the app's own rendering, written once its state holds a
    # photo (`op=smoke.capture`), and the grid's tiles drawn (`op=ui.mediaGrid.visibleThumbnails
    # phase=complete`: every visible tile shows what the catalog holds for it). The state can
    # hold photos a second before the grid draws them; a screen capture taken then shows an
    # empty grid (run 45864653887, dark).
    local rendered=0 tiles=""
    # time: deadline — the grid fills as the library's first walk lands; reports that never
    # come mean the window never showed a photo.
    while [[ "$rendered" == 0 || -z "$tiles" ]]; do
      if ! line="$(otos_log_stream_await "$own.*(op=smoke.capture phase=(finish|failed)|op=ui.mediaGrid.visibleThumbnails phase=complete)" 120)"; then
        echo "op=appCapture phase=failed reason=noCapture appearance=$appearance rendered=$rendered tiles=${tiles:-none}" >&2
        status=1
        break
      fi
      case "$line" in
        *"op=smoke.capture phase=finish"*) rendered=1; echo "op=appCapture phase=rendered appearance=$appearance" ;;
        *"op=smoke.capture"*) echo "op=appCapture phase=failed reason=captureFailed appearance=$appearance ${line#*op=smoke.capture }" >&2; status=1; break ;;
        *) tiles="${line#*phase=complete }"; echo "op=appCapture phase=tiles appearance=$appearance $tiles" ;;
      esac
    done
  fi
  if [[ "$status" == 0 ]]; then
    number="$(window_number "$APP_PID" || true)"
    echo "op=appCapture phase=window appearance=$appearance number=${number:-none}"
    if [[ -z "$number" ]] || ! /usr/sbin/screencapture -x -o -l "$number" "$png"; then
      echo "op=appCapture phase=failed reason=screenCapture appearance=$appearance window=${number:-none}" >&2
      status=1
    fi
  fi
  otos_log_stream_close
  # Quit this launch's process only; another Otos on the machine is never touched.
  echo "op=appCapture phase=quitting appearance=$appearance pid=$APP_PID"
  end_app "$APP_PID"
  echo "op=appCapture phase=quit appearance=$appearance pid=$APP_PID"
  APP_PID=""
  # Its home goes now, unless a process that cannot end still holds its volume: then it is
  # reported, and tried again as the script ends.
  "$ROOT_DIR/script/sandbox-library.sh" destroy --home "$home" || true
  if [[ "$status" == 0 ]]; then
    if [[ ! -s "$png" ]]; then
      echo "op=appCapture phase=failed reason=noPNG path=$png" >&2
      return 1
    fi
    echo "op=appCapture phase=written appearance=$appearance firstGridScope=$scope path=$png bytes=$(/usr/bin/stat -f %z "$png") $(/usr/bin/sips -g pixelWidth -g pixelHeight "$png" | /usr/bin/awk '/pixel/ { sub(":", "", $1); printf "%s=%s ", $1, $2 }')"
  fi
  return "$status"
}

failed=0
for appearance in light dark; do
  capture_one "$appearance" || failed=1
done
if [[ "$failed" != 0 ]]; then
  echo "op=appCapture phase=finish outcome=failed" >&2
  exit 1
fi
echo "op=appCapture phase=finish outcome=written folder=$OUT"
