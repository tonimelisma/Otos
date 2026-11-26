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
# For each appearance it launches the app in a sandbox home (script/sandbox-library.sh: a
# library of generated photos on a disk image of its own), which the app registers through
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

HOME_DIR="$ROOT_DIR/build/capture-homes/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$(dirname "$HOME_DIR")"
APP_PID=""

# Ends a launch's process: a TERM, then a wait for the kernel to report it gone (a zombie
# child counts as gone; `wait` reaps it). An app that has not exited after twenty seconds is
# killed and reported: on 2026-11-26 a launch outlived its TERM on CI's runner and held the
# job for 22 minutes with nothing said.
end_app() {
  local pid="$1" waited=0 state
  kill -TERM "$pid" 2>/dev/null || true
  while state="$(/bin/ps -o stat= -p "$pid" 2>/dev/null)" && [[ -n "$state" && "$state" != Z* ]]; do
    if (( waited >= 200 )); then
      echo "op=appCapture phase=killed pid=$pid reason=outlivedTerm waitedSeconds=20" >&2
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    # time: deadline — the kernel reports the exit by the process being gone; twenty seconds
    # bounds an app that does not act on its TERM.
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  otos_log_stream_close
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    end_app "$APP_PID"
  fi
  if [[ -e "$HOME_DIR" ]]; then
    "$ROOT_DIR/script/sandbox-library.sh" check-trash --home "$HOME_DIR" || true
    "$ROOT_DIR/script/sandbox-library.sh" destroy --home "$HOME_DIR" || true
  fi
}
trap cleanup EXIT

"$ROOT_DIR/script/sandbox-library.sh" create --home "$HOME_DIR" --count "$PHOTOS" --media small
LIBRARY="$(/usr/bin/sed -n 's/^library=//p' "$HOME_DIR/.otos-sandbox-library")"
[[ -n "$LIBRARY" ]] || { echo "op=appCapture phase=failed reason=noSandboxLibrary home=$HOME_DIR" >&2; exit 1; }

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
  rm -f "$png" "$rendering"
  otos_log_stream_open "subsystem == \"$SUBSYSTEM\" AND processImagePath == \"$EXECUTABLE\" AND (eventMessage BEGINSWITH \"op=launch.firstGrid\" OR eventMessage BEGINSWITH \"op=smoke.capture\" OR eventMessage BEGINSWITH \"op=ui.mediaGrid.visibleThumbnails phase=complete\")" debug
  # -ApplePersistenceIgnoreState: AppKit keeps window state per bundle id in the account,
  # not the sandbox home; a session that last quit with no window would restore none.
  env HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" OTOS_SANDBOX_LIBRARY="$LIBRARY" \
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
