#!/usr/bin/env bash
# The Mac's updater: installs main's newest commit once CI has proven it (ADR 0030). A
# per-user launchd agent (net.melisma.Otos.updater, set up by script/updater-setup.sh)
# starts it every 15 minutes, at login, and whenever a file appears in its requests
# folder. It runs as the user in the GUI session, so install.sh's normal Quit of the
# installed app (osascript) works from it.
#
# One run:
#   1. The primary checkout ($OTOS_UPDATER_CHECKOUT, ~/Development/Otos) must be on main
#      and clean, and its main must not hold commits origin/main lacks. Anything else is a
#      session's work, never touched: the run says why and waits for the next one.
#   2. It fetches origin/main. When that commit is the one it last installed, it is done.
#   3. It asks GitHub for that commit's `Required CI Gate` check run (REST, unauthenticated:
#      the repository is public, and four reads an hour sit far inside the anonymous
#      limit). Only a completed run that succeeded lets it go on; a run still going waits
#      for the next start, a red one is never installed.
#   4. It waits while a run in the checkout holds a build folder (a check, a bench, an
#      install) or the weekly performance run holds its lock: fast-forwarding under a check
#      fails that check (op=check.tree phase=changed), and an install mid-tour quits the
#      app the tour reads.
#   5. It fast-forwards the checkout's main to the commit and runs script/install.sh, which
#      defers with `op=install phase=pending` while an import or reorganization is in
#      flight. Pending: tried again on the next start. Failed: tried again after 6 hours,
#      or at once on a request. Finished: the commit is recorded as installed, and the
#      updater's own files are refreshed from the checkout (updater-setup.sh).
#
# Requests (files in $UPDATER_HOME/requests; any name and content): check now, and retry a
# failed install without waiting out its 6 hours.
# `auto-update.sh status` prints the state and the end of the log. Every line it logs is
# `op=updater …`, so the agent reads the log the way it reads the unified log.
# Settings (the agent sets them; script/updater-test.sh overrides them):
#   OTOS_UPDATER_HOME      state, requests, the agent's copy of this script
#   OTOS_UPDATER_CHECKOUT  the primary checkout it pulls and installs from
#   OTOS_UPDATER_LOG, OTOS_UPDATER_API, OTOS_UPDATER_CURL, OTOS_UPDATER_INSTALL
set -uo pipefail

UPDATER_HOME="${OTOS_UPDATER_HOME:-$HOME/Library/Application Support/net.melisma.Otos.updater}"
CHECKOUT="${OTOS_UPDATER_CHECKOUT:-$HOME/Development/Otos}"
LOG="${OTOS_UPDATER_LOG:-$HOME/Library/Logs/Otos Updater.log}"
API="${OTOS_UPDATER_API:-https://api.github.com/repos/tonimelisma/Otos}"
CURL="${OTOS_UPDATER_CURL:-curl}"
INSTALL="${OTOS_UPDATER_INSTALL:-script/install.sh}"
REQUESTS="$UPDATER_HOME/requests"
GATE_NAME="Required CI Gate"
RETRY_FAILED_SECONDS=21600

if [[ "${1:-}" == status ]]; then
  echo "checkout: $CHECKOUT ($(git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD 2> /dev/null) $(git -C "$CHECKOUT" rev-parse --short HEAD 2> /dev/null))"
  echo "installed by the updater: $(cat "$UPDATER_HOME/installed" 2> /dev/null || echo none)"
  [[ -f "$UPDATER_HOME/failed" ]] && echo "last failure (commit, time): $(cat "$UPDATER_HOME/failed")"
  [[ -n "$(ls -A "$REQUESTS" 2> /dev/null)" ]] && echo "requests waiting: $(ls -A "$REQUESTS" | tr '\n' ' ')"
  tail -20 "$LOG" 2> /dev/null
  exit 0
fi

mkdir -p "$UPDATER_HOME" "$REQUESTS" "$(dirname "$LOG")"
# One run at a time; a run that finds another running leaves the requests for it.
if [[ "${OTOS_UPDATER_LOCKED:-}" != 1 ]]; then
  if [[ -x /usr/bin/lockf ]]; then
    OTOS_UPDATER_LOCKED=1 exec /usr/bin/lockf -t 0 "$UPDATER_HOME/lock" /bin/bash "$0" "$@" 2> /dev/null
  elif command -v flock > /dev/null 2>&1; then
    OTOS_UPDATER_LOCKED=1 exec flock -n "$UPDATER_HOME/lock" /bin/bash "$0" "$@"
  fi
fi
# The log stays small: one older copy is kept.
if [[ -f "$LOG" ]] && (($(wc -c < "$LOG") > 1000000)); then mv -f "$LOG" "$LOG.1"; fi
log() { printf '%s op=updater %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }
# A reason to wait is logged when it changes, not every 15 minutes it stays true.
waiting() {
  if [[ "$(cat "$UPDATER_HOME/waiting" 2> /dev/null)" != "$1" ]]; then
    log "$1"
    printf '%s\n' "$1" > "$UPDATER_HOME/waiting"
  fi
  exit 0
}

requested=""
for request in "$REQUESTS"/* "$REQUESTS"/.[!.]*; do
  [[ -e "$request" ]] || continue
  requested=1
  rm -f "$request"
done
if [[ -n "$requested" ]]; then
  log "phase=request"
  rm -f "$UPDATER_HOME/waiting"
fi

git -C "$CHECKOUT" rev-parse --git-dir > /dev/null 2>&1 || waiting "phase=waiting reason=noCheckout checkout=\"$CHECKOUT\""
branch="$(git -C "$CHECKOUT" symbolic-ref --short -q HEAD)"
[[ "$branch" == main ]] || waiting "phase=waiting reason=notOnMain branch=${branch:-detached}"
[[ -z "$(git -C "$CHECKOUT" status --porcelain)" ]] || waiting "phase=waiting reason=dirtyTree"
if ! git -C "$CHECKOUT" fetch -q origin '+refs/heads/main:refs/remotes/origin/main' 2>> "$LOG"; then
  waiting "phase=waiting reason=fetchFailed"
fi
target="$(git -C "$CHECKOUT" rev-parse refs/remotes/origin/main)"
head="$(git -C "$CHECKOUT" rev-parse HEAD)"
short="${target:0:8}"
git -C "$CHECKOUT" merge-base --is-ancestor "$head" "$target" \
  || waiting "phase=waiting reason=localCommits head=${head:0:8} target=$short"
if [[ "$head" == "$target" && "$(cat "$UPDATER_HOME/installed" 2> /dev/null)" == "$target" ]]; then
  rm -f "$UPDATER_HOME/failed"
  [[ -z "$requested" ]] || log "phase=current revision=$short"
  exit 0
fi
if [[ -z "$requested" && -f "$UPDATER_HOME/failed" ]]; then
  read -r failed_revision failed_at < "$UPDATER_HOME/failed" || true
  [[ "${failed_at:-}" =~ ^[0-9]+$ ]] || failed_at=0
  # time: backoff — a failed install is retried after 6 hours, or at once on a request
  if [[ "${failed_revision:-}" == "$target" ]] && (($(date +%s) - failed_at < RETRY_FAILED_SECONDS)); then
    exit 0
  fi
fi

# The gate's verdict for the commit: success, pending, none, or the conclusion that failed.
if ! checks="$("$CURL" -fsS -H 'Accept: application/vnd.github+json' -H 'User-Agent: otos-updater' \
  "$API/commits/$target/check-runs?check_name=Required%20CI%20Gate" 2>> "$LOG")"; then
  waiting "phase=waiting reason=githubUnreachable revision=$short"
fi
verdict="$(printf '%s' "$checks" | /usr/bin/python3 -I -c '
import json, sys
runs = [run for run in json.load(sys.stdin).get("check_runs", []) if run.get("name") == sys.argv[1]]
if any(run.get("conclusion") == "success" for run in runs):
    print("success")
elif any(run.get("status") != "completed" for run in runs):
    print("pending")
elif runs:
    print(runs[0].get("conclusion") or "unknown")
else:
    print("none")
' "$GATE_NAME" 2>> "$LOG")" || waiting "phase=waiting reason=unreadableChecks revision=$short"
case "$verdict" in
  success) ;;
  pending | none) waiting "phase=waiting reason=gatePending revision=$short" ;;
  *) waiting "phase=skipped reason=gateRed conclusion=$verdict revision=$short" ;;
esac

# A run in the checkout that a pull or an install would break (header, step 4).
source "$CHECKOUT/script/lib/build-folder.sh"
common_dir="$(git -C "$CHECKOUT" rev-parse --path-format=absolute --git-common-dir)"
for lock in "$CHECKOUT"/build/*.lock "$common_dir/otos-perf.flock"; do
  [[ -e "$lock" ]] || continue
  state="$(otos_lock_state "$lock" 2> /dev/null)"
  [[ "$state" == held* ]] && waiting "phase=waiting reason=checkoutBusy lock=$(basename "$lock") revision=$short"
done

rm -f "$UPDATER_HOME/waiting"
if [[ "$head" != "$target" ]]; then
  if ! git -C "$CHECKOUT" merge -q --ff-only "$target" 2>> "$LOG"; then
    log "phase=failed reason=fastForwardFailed revision=$short"
    printf '%s %s\n' "$target" "$(date +%s)" > "$UPDATER_HOME/failed"
    exit 0
  fi
  log "phase=pulled from=${head:0:8} revision=$short"
fi

log "phase=install revision=$short"
output="$(mktemp)"
status=0
(cd "$CHECKOUT" && OTOS_UPDATER=1 /bin/bash "$INSTALL") > "$output" 2>&1 || status=$?
cat "$output" >> "$LOG"
result="$(grep -E '^op=install phase=' "$output" | tail -1)"
rm -f "$output"
case "$result" in
  "op=install phase=finish"*)
    printf '%s\n' "$target" > "$UPDATER_HOME/installed"
    rm -f "$UPDATER_HOME/failed"
    log "phase=installed revision=$short"
    # The agent runs a copy of this script; the commit just installed may carry a new one.
    OTOS_UPDATER=1 /bin/bash "$CHECKOUT/script/updater-setup.sh" >> "$LOG" 2>&1 \
      || log "phase=refreshFailed revision=$short"
    ;;
  "op=install phase=pending"*)
    log "phase=pending reason=appBusy revision=$short"
    ;;
  *)
    log "phase=failed reason=installFailed exit=$status revision=$short"
    printf '%s %s\n' "$target" "$(date +%s)" > "$UPDATER_HOME/failed"
    ;;
esac
exit 0
