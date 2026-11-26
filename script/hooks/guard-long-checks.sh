#!/usr/bin/env bash
# PreToolUse(Bash) guard. There is exactly one way to verify a change —
# script/check.sh — and this makes the wrong ways impossible rather than
# discouraged.
#
# Prose in AGENTS.md did not stop an agent running verify.sh in the foreground and
# then waiting 9 h 40 m on a completion event a hung process never sends; did not
# stop it running script/test.sh (which skips the gates, so nothing it produces is
# verification evidence). check.sh keeps its own whole log in logs/check/, so where a
# caller sends its output no longer decides what evidence survives. A hook runs in the harness, outside the
# agent's judgement, so those stop being available moves.
#
# What counts as "running" one is decided by *command position*, not by substring.
# Substring matching needed an allowlist of reader commands to stay usable, and an
# allowlist is only ever as complete as the last time someone remembered to extend
# it: it listed cat and grep but not sed, so `sed -n '100,165p' script/check.sh`
# — reading this very file — was denied as if it were a run. A path that is an
# argument to another program is never an invocation of it; a path in first
# position, after any env assignments and wrappers, always is.
set -uo pipefail

payload="$(cat)"

decision="$(printf '%s' "$payload" | /usr/bin/python3 -c '
import json, shlex, sys

try:
    d = json.load(sys.stdin)
except Exception:
    print("allow"); raise SystemExit

ti = d.get("tool_input") or {}
command = (ti.get("command") or "")
background = str(ti.get("run_in_background", False)).lower() == "true"

# A heredoc body is text, not commands. A PR description or commit message that
# documents these scripts is not a run of them, and matching it once denied a
# `gh pr create` whose body explained script/check.sh.
invocation = command.split("<<", 1)[0]

GUARDED = {"verify.sh", "test.sh", "build.sh", "check.sh"}
# Wrappers that delegate to their first non-flag argument, so the guarded script
# is still the thing being run.
WRAPPERS = {"nohup", "bash", "sh", "zsh", "env", "time", "exec", "command",
            "caffeinate", "sudo", "stdbuf"}

def segments(text):
    out, buf, i = [], "", 0
    while i < len(text):
        two = text[i:i + 2]
        if two in ("&&", "||"):
            out.append(buf); buf = ""; i += 2; continue
        if text[i] in ";|&\n":
            out.append(buf); buf = ""; i += 1; continue
        buf += text[i]; i += 1
    out.append(buf)
    return out

def invoked_script(segment):
    try:
        tokens = shlex.split(segment)
    except ValueError:
        tokens = segment.split()
    while tokens:
        head = tokens[0]
        # Leading environment assignments, then wrappers and their flags.
        if "=" in head and not head.startswith("/") and " " not in head.split("=")[0]:
            tokens = tokens[1:]; continue
        base = head.rsplit("/", 1)[-1]
        if base in WRAPPERS:
            tokens = tokens[1:]
            while tokens and tokens[0].startswith("-"):
                tokens = tokens[1:]
            continue
        break
    if not tokens:
        return None
    head = tokens[0]
    # Only this repo scripts/ directory is guarded; an unrelated test.sh is not.
    if "script/" not in head:
        return None
    base = head.rsplit("/", 1)[-1]
    return base if base in GUARDED else None

invoked = set()
for segment in segments(invocation):
    name = invoked_script(segment)
    if name:
        invoked.add(name)

if invoked & {"verify.sh", "test.sh", "build.sh"}:
    print("wrong-entry-point")
elif "check.sh" in invoked:
    # Where there is no Xcode (the VM of a cloud session) check.sh builds and tests nothing:
    # it runs the gates for seconds and ends, so a foreground run cannot hang on a build.
    import shutil
    if not background and shutil.which("xcodebuild") is not None:
        print("foreground")
    else:
        print("allow")
else:
    print("allow")
')"

case "$decision" in
  wrong-entry-point)
    cat >&2 <<'MSG'
Denied: run script/check.sh instead.

script/check.sh is the single entry point. It runs the seconds-long gates first so
a formatting nit never costs a full build, then runs the whole verification, and
prints a heartbeat every 60 s carrying elapsed time and the running test count.

Running verify.sh / test.sh / build.sh directly loses that:
  • test.sh and build.sh skip the gates, so nothing they produce is evidence.
  • Nothing emits a heartbeat, so a hang is indistinguishable from slow work.

  script/check.sh        with run_in_background: true
then read the tail of its log every 60 s. tests= climbing is healthy; tests=
unchanged three times running is hung — run `xcrun swift-inspect dump-concurrency
<xctest pid>` to name the parked test; do not wait it out.
MSG
    exit 2
    ;;
  foreground)
    cat >&2 <<'MSG'
Denied: script/check.sh must run with run_in_background: true.

It runs for minutes, longer than a foreground command should wait — and a foreground
run that is auto-backgrounded leaves you waiting on a completion event that a hung
process never sends. Re-issue with run_in_background: true, then read the tail of
its log every 60 seconds.
MSG
    exit 2
    ;;
esac
exit 0
