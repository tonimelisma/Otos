#!/usr/bin/env bash
# The installed app (/Applications/Otos.app, ADR 0030), quit and reopened the one way every
# script that needs it to itself does: script/install.sh and the weekly performance run
# (script/perf.sh).
source "$(dirname "${BASH_SOURCE[0]}")/operational-busy.sh"

OTOS_INSTALLED_APP="/Applications/Otos.app"
OTOS_INSTALLED_EXECUTABLE="$OTOS_INSTALLED_APP/Contents/MacOS/Otos"
OTOS_INSTALLED_CATALOG="$HOME/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite"

# Quits a running installed Otos and returns once the kernel reports its exit. Never while
# its catalog proves an import or reorganization in flight: then it quits nothing, sets
# OTOS_INSTALLED_BUSY_ROOT and returns 1. Sets OTOS_INSTALLED_WAS_RUNNING (1 when it quit
# the app). A normal Quit, the same as ⌘Q, never a kill: the app takes its own termination
# path, device-staging cleanup included.
otos_quit_installed_app() {
  OTOS_INSTALLED_WAS_RUNNING=0
  OTOS_INSTALLED_BUSY_ROOT=""
  pgrep -fx "$OTOS_INSTALLED_EXECUTABLE" >/dev/null || return 0
  if OTOS_INSTALLED_BUSY_ROOT="$(has_active_operational_work "$OTOS_INSTALLED_CATALOG")"; then
    return 1
  fi
  OTOS_INSTALLED_WAS_RUNNING=1
  /usr/bin/osascript -e "tell application \"$OTOS_INSTALLED_APP\" to quit" >/dev/null || return 2
  # `caffeinate -w` returns when that process exits — the kernel reports the exit, so
  # nothing here guesses how long termination takes.
  local pid
  for pid in $(pgrep -fx "$OTOS_INSTALLED_EXECUTABLE" || true); do
    /usr/bin/caffeinate -w "$pid"
  done
  return 0
}

# Reopens the installed app in the background, as the user had it, when
# otos_quit_installed_app quit it and nothing has opened it since.
otos_reopen_installed_app() {
  if [[ "${OTOS_INSTALLED_WAS_RUNNING:-0}" == 1 ]] && ! pgrep -fx "$OTOS_INSTALLED_EXECUTABLE" >/dev/null; then
    /usr/bin/open -g "$OTOS_INSTALLED_APP"
  fi
  OTOS_INSTALLED_WAS_RUNNING=0
}
