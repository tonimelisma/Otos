#!/usr/bin/env bash
# One run at a time per build folder, and the identity of the tree a run measured
# (ADR 0044).
#
# Several sessions share the primary checkout: one installs, one benchmarks, one checks,
# and any of them may pull. Two xcodebuild runs against one DerivedData fail on its
# locked build database (exit 65) or deadlock the suite, and a pull during a build makes
# the result describe neither tree. These two helpers turn both into facts a run
# reports. Sourced; each reports failure by status and leaves the caller's shell
# options alone (check.sh runs without -e on purpose).

# Holds <folder> for the rest of the calling script. A second run against the same folder
# waits for the first to finish — the kernel reports the release — and says whom it waits
# for. A nested script (check.sh → verify.sh → build.sh) inherits the hold through
# OTOS_HELD_BUILD_FOLDERS instead of waiting on its own parent.
otos_hold_build_folder() {
  local folder="$1" op="$2"
  if [[ " ${OTOS_HELD_BUILD_FOLDERS:-} " == *" $folder "* ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$folder")"
  otos_hold_lock wait "$folder.lock" "$op" "folder=$folder"
  if [[ "$OTOS_LOCK_OUTCOME" != "held" ]]; then
    echo "op=$op phase=failed reason=buildFolderLock folder=$folder" >&2
    return 1
  fi
  export OTOS_HELD_BUILD_FOLDERS="${OTOS_HELD_BUILD_FOLDERS:-} $folder"
}

# Holds <lock file> for the rest of the calling script: `wait` waits for another holder to
# finish, `try` gives up at once. Sets OTOS_LOCK_OUTCOME to "held" once held, to
# "busy <holder>" when `try` found it held, or to "" when the holder failed; a wait prints
# `op=<op>.wait reason=buildFolderBusy <context> <holder>` as it starts waiting. A variable,
# not printed output: a command substitution would make the holder a child of a subshell
# whose output the caller reads to its end.
#
# The lock lives in a holder process of its own (script/lib/hold-lock.py), not in an
# inherited descriptor: every process xcodebuild starts would inherit one, and a build
# service outliving the run would hold the lock forever. The holder exits when the calling
# script does, however it ends, so no lock outlives its run.
otos_hold_lock() {
  local mode="$1" lock="$2" op="$3" context="${4:-}"
  local line=""
  OTOS_LOCK_OUTCOME=""
  # Descriptor 8 carries the holder's report; macOS bash 3.2 has no {var} allocation.
  exec 8< <(/usr/bin/python3 -I "$(dirname "${BASH_SOURCE[0]}")/hold-lock.py" "$mode" "$lock" "$$" "$op")
  while IFS= read -r line <&8; do
    case "$line" in
      busy*)
        OTOS_LOCK_OUTCOME="$line"
        if [[ "$mode" == "wait" ]]; then
          echo "op=$op.wait reason=buildFolderBusy ${context:+$context }${line#busy }"
        fi
        ;;
      held)
        OTOS_LOCK_OUTCOME="held"
        break
        ;;
    esac
  done
  exec 8<&-
  return 0
}

# "free", or "held <holder>" for a lock otos_hold_lock holds. It takes nothing, so asking
# never makes a holder wait or give up.
otos_lock_state() {
  /usr/bin/python3 -I "$(dirname "${BASH_SOURCE[0]}")/hold-lock.py" query "$1"
}

# The git tree id of the checkout as it stands, uncommitted and untracked files included
# (ignored ones excluded). Equal ids at a run's start and end mean the run measured one
# tree. Built in a private copy of the index, so nothing the checkout's own index or
# working files hold changes.
otos_tree_identity() {
  local root_dir="$1" index
  index="$(mktemp)"
  local status=0
  cp "$(git -C "$root_dir" rev-parse --path-format=absolute --git-path index)" "$index" \
    && GIT_INDEX_FILE="$index" git -C "$root_dir" add -A \
    && GIT_INDEX_FILE="$index" git -C "$root_dir" write-tree \
    || status=$?
  rm -f "$index"
  return "$status"
}
