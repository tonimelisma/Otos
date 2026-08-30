#!/usr/bin/env bash
# PreToolUse(Bash) guard. There is exactly one way to verify a change —
# script/check.sh — and this makes the wrong ways impossible rather than
# discouraged.
#
# Prose in AGENTS.md did not stop an agent running verify.sh in the foreground and
# then waiting 9 h 40 m on a completion event a hung process never sends; did not
# stop it running script/test.sh (which skips the gates, so nothing it produces is
# verification evidence); and did not stop it redirecting a run into /tmp where
# script/test.sh's own tee meant the redirect captured a single header line and any
# pass count read from it was meaningless. A hook runs in the harness, outside the
# agent's judgement, so those stop being available moves.
set -uo pipefail

payload="$(cat)"

full_command="$(printf '%s' "$payload" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print(((d.get("tool_input") or {}).get("command") or "").replace("\n", " "))
')"

background="$(printf '%s' "$payload" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("false"); raise SystemExit
print(str((d.get("tool_input") or {}).get("run_in_background", False)).lower())
')"

# Match only the *invocation* part of the command. A heredoc body is text — a PR
# description or commit message that documents these scripts is not a run of them,
# and matching it denied a `gh pr create` whose body explained script/check.sh.
invocation_text="${full_command%%<<*}"

is_run_of() {
  printf '%s' "$invocation_text" | grep -qE "(^|[;&|[:space:]])(\./)?script/$1( |$|[;&|>])"
}

# Reading about the scripts is fine; running the wrong one is not.
case "$full_command" in
  *grep*|*"git diff"*|*"git log"*|*"cat script/"*|*"bash -n"*|*chmod*) exit 0 ;;
esac

if is_run_of "verify.sh" || is_run_of "test.sh" || is_run_of "build.sh"; then
  cat >&2 <<'MSG'
Denied: run script/check.sh instead.

script/check.sh is the single entry point. It runs the seconds-long gates first so
a formatting nit never costs a full build, then runs the whole verification, and
prints a heartbeat every 60 s carrying elapsed time and the running test count.

Running verify.sh / test.sh / build.sh directly loses that:
  • test.sh and build.sh skip the gates, so nothing they produce is evidence.
  • Nothing emits a heartbeat, so a hang is indistinguishable from slow work —
    which is how one run stalled for 9 h 40 m unnoticed.

  script/check.sh        with run_in_background: true
then read the tail of its log every 60 s. tests= climbing is healthy; tests=
unchanged three times running is hung — sample the xctest pid, do not wait it out.
MSG
  exit 2
fi

if is_run_of "check.sh"; then
  if [[ "$background" != "true" ]]; then
    cat >&2 <<'MSG'
Denied: script/check.sh must run with run_in_background: true.

It takes about 7 minutes, which exceeds the foreground timeout — and a foreground
run that is auto-backgrounded leaves you waiting on a completion event that a hung
process never sends. Re-issue with run_in_background: true, then read the tail of
its log every 60 seconds.
MSG
    exit 2
  fi
  if printf '%s' "$invocation_text" | grep -qE '>[[:space:]]*/tmp/'; then
    cat >&2 <<'MSG'
Denied: write the log to the session scratchpad, not /tmp.

Your environment names a scratchpad directory; use it so the log is still there
when you read the result.
MSG
    exit 2
  fi
fi
exit 0
