#!/usr/bin/env bash
# The Mac updater's rules (script/auto-update.sh, script/updater-setup.sh), against a
# generated repository, a fake GitHub (OTOS_UPDATER_CURL), a fake install
# (OTOS_UPDATER_INSTALL) and a fake launchctl (LAUNCHCTL). Nothing here reaches GitHub,
# launchd, the installed app or a real checkout; everything it makes is under one temporary
# folder, removed when it ends however it ends. script/check.sh runs it with the fast gates.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
cases=0

fail() {
  echo "op=updater.test phase=fail case=$1 detail=\"$2\"" >&2
  failures=$((failures + 1))
}

git_quiet() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@" > /dev/null 2>&1; }

# The fakes. GitHub answers from $WORK/checks/<sha>.json (no file: unreachable); the install
# prints the op=install line $WORK/install-phase names and counts its runs; launchctl
# records its calls.
mkdir -p "$WORK/bin" "$WORK/checks"
cat > "$WORK/bin/curl" << 'EOF'
#!/usr/bin/env bash
url="${*: -1}"
sha="${url#*/commits/}"; sha="${sha%%/*}"
cat "$FAKE_WORK/checks/$sha.json" 2> /dev/null || exit 22
EOF
cat > "$WORK/bin/install" << 'EOF'
#!/usr/bin/env bash
echo "$(git rev-parse HEAD)" >> "$FAKE_WORK/installs"
echo "op=install phase=$(cat "$FAKE_WORK/install-phase") revision=$(git rev-parse --short HEAD)"
EOF
cat > "$WORK/bin/launchctl" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_WORK/launchctl"
case "$1" in
  print) [[ -f "$FAKE_WORK/loaded" ]] ;;
  bootstrap) touch "$FAKE_WORK/loaded" ;;
  bootout) rm -f "$FAKE_WORK/loaded" ;;
esac
EOF
chmod +x "$WORK/bin/"*
export FAKE_WORK="$WORK"

# A remote with the updater's own scripts on main, and the primary checkout cloned from it.
git_quiet init -b main "$WORK/seed"
mkdir -p "$WORK/seed/script/lib"
cp "$ROOT_DIR/script/auto-update.sh" "$ROOT_DIR/script/updater-setup.sh" "$WORK/seed/script/"
cp "$ROOT_DIR/script/lib/build-folder.sh" "$ROOT_DIR/script/lib/hold-lock.py" "$WORK/seed/script/lib/"
printf 'build/\n' > "$WORK/seed/.gitignore"
git_quiet -C "$WORK/seed" add -A
git_quiet -C "$WORK/seed" commit -m first
git_quiet clone --bare "$WORK/seed" "$WORK/remote.git"
git_quiet clone "$WORK/remote.git" "$WORK/checkout"

export OTOS_UPDATER_HOME="$WORK/home"
export OTOS_UPDATER_CHECKOUT="$WORK/checkout"
export OTOS_UPDATER_LOG="$WORK/updater.log"
export OTOS_UPDATER_CURL="$WORK/bin/curl"
export OTOS_UPDATER_INSTALL="$WORK/bin/install"
export OTOS_LAUNCH_AGENTS="$WORK/agents"
export LAUNCHCTL="$WORK/bin/launchctl"
export OTOS_DEVELOPMENT_TEAM=TESTTEAM

# Pushes a new commit to the remote's main and prints its sha.
push_commit() {
  git_quiet -C "$WORK/seed" commit --allow-empty -m "$1"
  git_quiet -C "$WORK/seed" push "$WORK/remote.git" main
  git -C "$WORK/seed" rev-parse HEAD
}
gate() { # <sha> <status> <conclusion>
  printf '{"check_runs":[{"name":"Required CI Gate","status":"%s","conclusion":%s}]}' "$2" "$3" > "$WORK/checks/$1.json"
}
run() { /bin/bash "$ROOT_DIR/script/auto-update.sh" > /dev/null 2>&1; }
installs() { if [[ -f "$WORK/installs" ]]; then wc -l < "$WORK/installs" | tr -d ' '; else echo 0; fi; }
expect_log() { grep -q -- "$2" "$WORK/updater.log" || fail "$1" "log lacks: $2"; }
expect_installs() { [[ "$(installs)" == "$2" ]] || fail "$1" "installs=$(installs), expected $2"; }
case_start() { cases=$((cases + 1)); }

case_start
first="$(git -C "$WORK/seed" rev-parse HEAD)"
gate "$first" in_progress null
echo finish > "$WORK/install-phase"
run
expect_log gatePending "reason=gatePending revision=${first:0:8}"
expect_installs gatePending 0

case_start
gate "$first" completed '"success"'
run
expect_installs greenInstalls 1
expect_log greenInstalls "phase=installed revision=${first:0:8}"
[[ "$(cat "$WORK/home/installed")" == "$first" ]] || fail greenInstalls "installed state is not $first"
cmp -s "$WORK/home/auto-update.sh" "$ROOT_DIR/script/auto-update.sh" || fail greenInstalls "the install did not refresh the agent's script"

case_start
run
expect_installs alreadyInstalled 1

case_start
second="$(push_commit second)"
gate "$second" completed '"failure"'
run
expect_installs redNeverInstalls 1
expect_log redNeverInstalls "phase=skipped reason=gateRed conclusion=failure revision=${second:0:8}"
[[ "$(git -C "$WORK/checkout" rev-parse HEAD)" == "$first" ]] || fail redNeverInstalls "a red commit was pulled"

case_start
third="$(push_commit third)"
gate "$third" completed '"success"'
echo pending > "$WORK/install-phase"
run
expect_installs pendingRetries 2
expect_log pendingRetries "phase=pulled from=${first:0:8} revision=${third:0:8}"
expect_log pendingRetries "phase=pending reason=appBusy revision=${third:0:8}"
echo finish > "$WORK/install-phase"
run
expect_installs pendingRetries 3
[[ "$(cat "$WORK/home/installed")" == "$third" ]] || fail pendingRetries "the retried install was not recorded"

case_start
fourth="$(push_commit fourth)"
gate "$fourth" completed '"success"'
echo failed > "$WORK/install-phase"
run
expect_installs failureBacksOff 4
expect_log failureBacksOff "phase=failed reason=installFailed exit=0 revision=${fourth:0:8}"
run
expect_installs failureBacksOff 4
touch "$WORK/home/requests/now"
echo finish > "$WORK/install-phase"
run
expect_installs failureBacksOff 5
[[ ! -e "$WORK/home/failed" ]] || fail failureBacksOff "a finished install left the failure recorded"

case_start
fifth="$(push_commit fifth)"
gate "$fifth" completed '"success"'
touch "$WORK/checkout/untracked"
run
expect_installs dirtyTreeWaits 5
expect_log dirtyTreeWaits "reason=dirtyTree"
rm "$WORK/checkout/untracked"

case_start
git_quiet -C "$WORK/checkout" checkout -b feature
run
expect_installs otherBranchWaits 5
expect_log otherBranchWaits "reason=notOnMain branch=feature"
git_quiet -C "$WORK/checkout" checkout main

case_start
git_quiet -C "$WORK/checkout" commit --allow-empty -m local
run
expect_installs localCommitsWait 5
expect_log localCommitsWait "reason=localCommits"
git_quiet -C "$WORK/checkout" reset --hard "$fourth"

# The lock query reads macOS's struct flock (script/lib/hold-lock.py); Linux has no
# equivalent for a flock(2) lock, so the busy checkout is checked on the Mac only.
case_start
if [[ "$(uname -s)" == Darwin ]]; then
  # A run holding the checkout's build folder: a stand-in owner process, and the holder
  # script/lib/build-folder.sh starts for a run, as this script's own children. The holder
  # releases once the kernel reports its owner's exit, and exits, so waiting for it is the
  # release.
  mkdir -p "$WORK/checkout/build"
  mkfifo "$WORK/held"
  tail -f /dev/null &
  owner=$!
  /usr/bin/python3 -I "$WORK/checkout/script/lib/hold-lock.py" try "$WORK/checkout/build/DerivedData.lock" "$owner" test > "$WORK/held" &
  holder=$!
  read -r held < "$WORK/held"
  [[ "$held" == held ]] || fail busyCheckoutWaits "the stand-in run did not get the lock: $held"
  run
  kill "$owner"
  wait "$owner" 2> /dev/null || true
  wait "$holder" || true
  expect_installs busyCheckoutWaits 5
  expect_log busyCheckoutWaits "reason=checkoutBusy lock=DerivedData.lock"
else
  echo "op=updater.test phase=skipped case=busyCheckoutWaits reason=noFlockQueryOffDarwin"
fi
run
expect_installs busyCheckoutWaits 6
[[ "$(cat "$WORK/home/installed")" == "$fifth" ]] || fail busyCheckoutWaits "the free checkout did not install $fifth"

case_start
rm -f "$WORK/launchctl" "$WORK/loaded"
/bin/bash "$ROOT_DIR/script/updater-setup.sh" > /dev/null
plist="$WORK/agents/net.melisma.Otos.updater.plist"
grep -q "<string>$WORK/checkout</string>" "$plist" || fail setupStarts "the agent does not name the checkout"
grep -q "^bootstrap gui/$(id -u) $plist" "$WORK/launchctl" || fail setupStarts "the agent was not bootstrapped"
[[ "$(/bin/bash "$ROOT_DIR/script/updater-setup.sh")" == *phase=current* ]] || fail setupStarts "a second setup reloaded an unchanged agent"
/bin/bash "$ROOT_DIR/script/updater-setup.sh" remove > /dev/null
grep -q "^bootout gui/$(id -u)/net.melisma.Otos.updater" "$WORK/launchctl" || fail setupRemoves "the agent was not booted out"
[[ ! -e "$plist" && ! -e "$WORK/home" ]] || fail setupRemoves "the agent file or its state is left"

case_start
if OTOS_DEVELOPMENT_TEAM="" XDG_CONFIG_HOME="$WORK/no-config" /bin/bash "$ROOT_DIR/script/updater-setup.sh" > /dev/null 2>&1; then
  fail setupNeedsTeam "set up without a signing team"
fi

if ((failures > 0)); then
  echo "op=updater.test phase=fail cases=$cases failures=$failures" >&2
  exit 1
fi
echo "op=updater.test phase=pass cases=$cases"
