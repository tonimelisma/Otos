#!/usr/bin/env bash
# Launches an Otos build on a library of generated media and writes its main window's own
# rendering, light and dark, as PNGs (plan 0118, ADR 0020's capture seam):
#
#   script/app-capture.sh <Otos.app> <output folder> [photos]
#
# It is the look a session with no Mac reads (CI's App Captures job uploads the folder), and
# the launch check a release passes before it publishes (script/release.sh): an app that
# cannot reach its first grid and draw its window writes no capture, and this fails.
#
# For each appearance it launches the app in a sandbox home (script/sandbox-library.sh: a
# library of generated photos on a disk image of its own), which the app registers through
# its own Add Library intent (`OTOS_SANDBOX_LIBRARY`), and asks for a capture
# (`OTOS_SMOKE_CAPTURE_PATH`). It waits on the app's reports: `op=launch.firstGrid`, then
# `op=smoke.capture phase=finish` (or `failed`), from this launch's process only; then it
# quits that process and waits for its exit. It writes nothing outside the sandbox home and
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
cleanup() {
  otos_log_stream_close
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
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

# One launch: waits for the first grid and the capture, quits the app, waits for its exit.
capture_one() {
  local appearance="$1" png="$OUT/all-media-$1.png" line="" status=0
  rm -f "$png"
  otos_log_stream_open "subsystem == \"$SUBSYSTEM\" AND processImagePath == \"$EXECUTABLE\" AND (eventMessage BEGINSWITH \"op=launch.firstGrid\" OR eventMessage BEGINSWITH \"op=smoke.capture\")"
  # -ApplePersistenceIgnoreState: AppKit keeps window state per bundle id in the account,
  # not the sandbox home; a session that last quit with no window would restore none.
  env HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" OTOS_SANDBOX_LIBRARY="$LIBRARY" \
    OTOS_SMOKE_CAPTURE_PATH="$png" OTOS_SMOKE_APPEARANCE="$appearance" \
    "$EXECUTABLE" -ApplePersistenceIgnoreState YES > /dev/null 2>&1 3<&- &
  APP_PID="$!"
  echo "op=appCapture phase=launched appearance=$appearance pid=$APP_PID"
  local own="\\[${APP_PID}:[^]]*\\]"
  # time: deadline — an app that never reaches its first grid reports nothing. Two minutes
  # with no line from it; the launch's measured time is the line's own ms= field.
  if line="$(otos_log_stream_await "$own.*op=launch.firstGrid" 120)"; then
    echo "op=appCapture phase=firstGrid appearance=$appearance ${line#*op=launch.firstGrid }"
  else
    echo "op=appCapture phase=failed reason=noFirstGrid appearance=$appearance" >&2
    status=1
  fi
  if [[ "$status" == 0 ]]; then
    # time: deadline — the grid fills as the library's first walk lands; a capture that
    # never comes means the window never showed a photo.
    if line="$(otos_log_stream_await "$own.*op=smoke.capture phase=(finish|failed)" 120)"; then
      case "$line" in
        *"phase=finish"*) ;;
        *) echo "op=appCapture phase=failed reason=captureFailed appearance=$appearance ${line#*op=smoke.capture }" >&2; status=1 ;;
      esac
    else
      echo "op=appCapture phase=failed reason=noCapture appearance=$appearance" >&2
      status=1
    fi
  fi
  otos_log_stream_close
  # Quit this launch's process only; another Otos on the machine is never touched.
  kill -TERM "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  if kill -0 "$APP_PID" 2>/dev/null; then
    echo "op=appCapture phase=failed reason=stillRunning pid=$APP_PID" >&2
    status=1
  fi
  APP_PID=""
  if [[ "$status" == 0 ]]; then
    if [[ ! -s "$png" ]]; then
      echo "op=appCapture phase=failed reason=noPNG path=$png" >&2
      return 1
    fi
    echo "op=appCapture phase=written appearance=$appearance path=$png bytes=$(/usr/bin/stat -f %z "$png") $(/usr/bin/sips -g pixelWidth -g pixelHeight "$png" | /usr/bin/awk '/pixel/ { printf "%s=%s ", $1, $2 }')"
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
