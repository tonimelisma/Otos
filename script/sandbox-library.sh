#!/usr/bin/env bash
# A sandbox library for a tour or a survey: a sandbox home with a library of generated media
# on a volume of its own, mounted inside that home (ADR 0015, ADR 0020).
#
# Why a volume: Move to Trash (`FileManager.trashItem`) keeps an item on its own volume. On
# the volume that holds the account's home it moves it into the account's own `~/.Trash`,
# whatever HOME or CFFIXED_USER_HOME says; on any other volume into that volume's
# `.Trashes/<uid>` (docs/research/2026-11-16-trash-destination-by-volume.md). A library on a
# disk image mounted inside the sandbox home therefore trashes inside the sandbox, through
# exactly the path a user's Move to Trash takes, and detaching the image takes every trashed
# file with it. The app runs the tour's act steps only when every source's volume is mounted
# inside the sandbox home (`SmokeTour.trashStays`).
#
# The library is registered by the app itself, through the window's own Add Library intent,
# when the dev build is launched with OTOS_SANDBOX_LIBRARY=<library> in this home
# (`SandboxLibrary`); nothing here writes into a catalog.
#
# Every generated file's name starts with the run's own prefix and is listed in the home's
# manifest, so `check-trash` can test the account's Trash for each one by path (it never
# lists that Trash), remove any it finds, and fail loudly.
#
# hdiutil and diskutil cannot run inside the agent's sandbox: there `create` refuses, and
# with no volume no act step can run anywhere. Run it unsandboxed or as a person.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER=".otos-sandbox-library"
FILES=".otos-sandbox-library-files"
IMAGE=".otos-sandbox-library.sparseimage"
MOUNT_NAME="TourLibrary"
LIBRARY_NAME="Photos"

usage() {
  cat <<'EOF'
usage:
  script/sandbox-library.sh create --home <dir> --count <photos> [--videos <n>] [--media camera|small]
      Makes <dir> (it must not exist), a sparse APFS image inside it mounted at
      <dir>/TourLibrary without Finder seeing it, and <photos> generated photos (some with
      words, some skies, a few near-duplicates, some with GPS) and <n> short videos (default
      2) in <dir>/TourLibrary/Photos. Prints the environment the dev build needs.
      --media camera (the default): camera-size photos (48/12 MP HEIC, 24/12 MP JPEG) in one
      folder, about 2 MB each. --media small: a library of the owner's size, 64 x 64 JPEGs of
      a few KB in a year/month/ten-day folder tree, written in parallel (160,000 in a few
      minutes, a few hundred MB).
  script/sandbox-library.sh check-trash --home <dir>
      Tests the account's own Trash for every file this home generated, by name; removes
      any it finds there and exits 1, loudly. Exits 0 only when none is there.
  script/sandbox-library.sh destroy --home <dir>
      check-trash, then detaches the volume (never forced), confirms it is gone and removes
      <dir>. Refuses a folder this script did not make; a volume an app still holds is
      reported and left mounted.
EOF
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] && shift
HOME_DIR=""
COUNT=""
VIDEOS=2
MEDIA=camera
while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) HOME_DIR="${2:?}"; shift 2 ;;
    --count) COUNT="${2:?}"; shift 2 ;;
    --videos) VIDEOS="${2:?}"; shift 2 ;;
    --media) MEDIA="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# The account's own home, from the user database: HOME may be a sandbox's.
account_home() {
  /usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory | /usr/bin/awk '{print $2}'
}

require_home() {
  [[ -n "$HOME_DIR" ]] || { echo "--home is required" >&2; usage >&2; exit 2; }
  case "$HOME_DIR" in /*) ;; *) HOME_DIR="$PWD/$HOME_DIR" ;; esac
}

mounted() {
  /sbin/mount | /usr/bin/grep -qF " on $1 ("
}

create() {
  require_home
  [[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || { echo "--count <photos> is required" >&2; exit 2; }
  [[ "$VIDEOS" =~ ^[0-9]+$ ]] || { echo "--videos takes a number" >&2; exit 2; }
  [[ "$MEDIA" == camera || "$MEDIA" == small ]] || { echo "--media is camera or small" >&2; exit 2; }
  if [[ -e "$HOME_DIR" ]]; then
    echo "op=sandboxLibrary.create phase=refused reason=homeExists home=$HOME_DIR — a sandbox home is made fresh" >&2
    exit 1
  fi
  local account
  account="$(account_home)"
  mkdir -p "$HOME_DIR"
  HOME_DIR="$(cd "$HOME_DIR" && pwd -P)"
  if [[ "$HOME_DIR" == "$account" || "$account" == "$HOME_DIR"/* ]]; then
    rmdir "$HOME_DIR"
    echo "op=sandboxLibrary.create phase=refused reason=accountHome — a sandbox home is never the account's home or a folder holding it" >&2
    exit 1
  fi
  local token prefix mount image library
  token="$(/usr/bin/uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-12)"
  prefix="otos-tour-$token"
  mount="$HOME_DIR/$MOUNT_NAME"
  image="$HOME_DIR/$IMAGE"
  library="$mount/$LIBRARY_NAME"
  {
    echo "token=$token"
    echo "mount=$mount"
    echo "image=$image"
    echo "library=$library"
  } > "$HOME_DIR/$MARKER"
  : > "$HOME_DIR/$FILES"
  # Room for every file (two megabytes a camera photo; a small one fills one 4 KB block, a
  # sign with words a few, plus its folder's share); a sparse image takes only what is written.
  local size_mb=$(( COUNT * 2 + VIDEOS * 4 + 256 ))
  [[ "$MEDIA" == small ]] && size_mb=$(( COUNT / 50 + VIDEOS * 4 + 256 ))
  mkdir -p "$mount"
  if ! /usr/bin/hdiutil create -quiet -type SPARSE -fs APFS -volname OtosTourLibrary -size "${size_mb}m" "$image" \
    || ! /usr/sbin/diskutil image attach --mountOptions nobrowse --mountPoint "$mount" "$image" >/dev/null; then
    echo "op=sandboxLibrary.create phase=refused reason=noVolume — hdiutil or diskutil could not make the library's volume (the agent sandbox cannot run them: run unsandboxed or as a person). Without a volume of its own no act step can keep its files out of the account's Trash." >&2
    destroy_quietly
    exit 1
  fi
  mounted "$mount" || { echo "op=sandboxLibrary.create phase=refused reason=notMounted mount=$mount" >&2; destroy_quietly; exit 1; }
  mkdir -p "$library"
  local generator="$HOME_DIR/.otos-sandbox-library-media"
  /usr/bin/xcrun swiftc -O -suppress-warnings "$ROOT_DIR/script/sandbox-library-media.swift" -o "$generator"
  echo "op=sandboxLibrary.create phase=generating photos=$COUNT videos=$VIDEOS media=$MEDIA library=$library" >&2
  local started=$SECONDS
  "$generator" "$library" "$prefix" "$COUNT" "$VIDEOS" "$MEDIA" >> "$HOME_DIR/$FILES"
  rm -f "$generator"
  local made library_kb
  made="$(/usr/bin/wc -l < "$HOME_DIR/$FILES" | tr -d ' ')"
  library_kb="$(/usr/bin/du -sk "$library" | /usr/bin/awk '{print $1}')"
  echo "op=sandboxLibrary.create phase=finish home=$HOME_DIR library=$library files=$made media=$MEDIA seconds=$((SECONDS - started)) libraryMB=$((library_kb / 1024)) prefix=$prefix"
  echo "env CFFIXED_USER_HOME=$HOME_DIR HOME=$HOME_DIR OTOS_SANDBOX_LIBRARY=$library"
}

# Reads the home's manifest into MOUNT, IMAGE and LIBRARY; refuses a folder without one.
read_marker() {
  require_home
  if [[ ! -f "$HOME_DIR/$MARKER" ]]; then
    echo "op=sandboxLibrary phase=refused reason=notASandboxLibrary home=$HOME_DIR — no $MARKER: this script did not make it" >&2
    exit 1
  fi
  MOUNT="$(/usr/bin/sed -n 's/^mount=//p' "$HOME_DIR/$MARKER")"
  IMAGE_PATH="$(/usr/bin/sed -n 's/^image=//p' "$HOME_DIR/$MARKER")"
}

check_trash() {
  read_marker
  local trash
  trash="$(account_home)/.Trash"
  /usr/bin/python3 -I "$ROOT_DIR/script/lib/scorecard.py" --trash-leftovers "$HOME_DIR/$FILES" "$trash"
}

detach_volume() {
  if mounted "$MOUNT"; then
    # Never forced: a volume an app still holds stays mounted and is reported.
    /usr/sbin/diskutil eject "$MOUNT" >/dev/null 2>&1 || /usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  fi
  if mounted "$MOUNT"; then
    echo "op=sandboxLibrary.destroy phase=failed reason=stillMounted mount=$MOUNT — something holds the volume (an Otos still running?); quit it and run destroy again" >&2
    return 1
  fi
}

# For a create that failed part way: its own folder only, whatever state it reached.
destroy_quietly() {
  MOUNT="$HOME_DIR/$MOUNT_NAME"
  detach_volume || return 1
  rm -rf "$HOME_DIR"
}

destroy() {
  read_marker
  local trash_status=0
  check_trash || trash_status=$?
  detach_volume
  rm -f "$IMAGE_PATH"
  rm -rf "$HOME_DIR"
  if [[ -e "$HOME_DIR" ]]; then
    echo "op=sandboxLibrary.destroy phase=failed reason=homeRemains home=$HOME_DIR" >&2
    exit 1
  fi
  echo "op=sandboxLibrary.destroy phase=finish home=$HOME_DIR removed=true trashClean=$([[ $trash_status == 0 ]] && echo true || echo false)"
  exit "$trash_status"
}

case "$COMMAND" in
  create) create ;;
  check-trash) check_trash ;;
  destroy) destroy ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
