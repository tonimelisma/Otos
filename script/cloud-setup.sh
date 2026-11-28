#!/usr/bin/env bash
# SessionStart hook (.claude/settings.json). Its output is added to the session's context,
# so it says where the session runs and what that changes (CLAUDE.md, "Where sessions run"), in the few lines that apply there and nowhere else.
#
# In a Claude Code cloud session — an Ubuntu VM with no Xcode, `CLAUDE_CODE_REMOTE=true` —
# it also installs what the Linux-runnable gates need: the commands they call and the
# pinned Linux lint binaries (CLAUDE.md, "Where sessions run"). On a Mac it installs nothing:
# a Mac has its tools from Xcode and `brew bundle`.
#
# It prints op= lines and always exits 0. A setup that fails must not stop the session
# from starting; the gate that needed the missing tool fails by name when it runs.
set -uo pipefail

if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "op=session.where place=mac — a local session on a Mac: it may build and test natively, run the visual and end-to-end checks on generated libraries, and inspect the installed app read-only; it works in a dedicated worktree with dev builds, never installs (Sparkle installs), and verifies through CI; live checks on real data only when the person running the session asks. Procedures: the mac-session skill."
  fi
  exit 0
fi
echo "op=session.where place=cloud — a cloud VM with no Xcode: check.sh runs every gate in seconds; a full-tier change is verified by CI's Build And Test (the ci skill). No Mac is reached from here."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The commands the gates call, each with the Ubuntu package that provides it.
# `/usr/bin/python3` by path: the gates run it as `/usr/bin/python3 -I`.
missing=()
for pair in git:git /usr/bin/python3:python3 ruby:ruby curl:curl unzip:unzip shasum:perl sqlite3:sqlite3; do
  command -v "${pair%%:*}" > /dev/null 2>&1 || missing+=("${pair#*:}")
done
if (( ${#missing[@]} > 0 )); then
  sudo_cmd=()
  [[ "$(id -u)" == "0" ]] || sudo_cmd=(sudo -n)
  if "${sudo_cmd[@]}" apt-get update -qq > /dev/null \
    && DEBIAN_FRONTEND=noninteractive "${sudo_cmd[@]}" apt-get install -y -qq --no-install-recommends \
      ca-certificates "${missing[@]}" > /dev/null; then
    echo "op=cloud.setup phase=installed packages=\"${missing[*]}\""
  else
    echo "op=cloud.setup phase=installFailed packages=\"${missing[*]}\"" >&2
  fi
fi

for tool in swiftformat swiftlint; do
  if binary="$("$ROOT_DIR/script/lint-tools.sh" "$tool")"; then
    echo "op=cloud.setup phase=ready tool=$tool path=$binary"
  else
    echo "op=cloud.setup phase=toolFailed tool=$tool" >&2
  fi
done
exit 0
