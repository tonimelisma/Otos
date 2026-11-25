#!/usr/bin/env bash
# Sets up the Mac's updater (script/auto-update.sh) as a per-user launchd agent,
# net.melisma.Otos.updater: every 15 minutes, at login, and when a file appears in its
# requests folder (ADR 0030). The owner runs it once, from the primary checkout:
#   script/updater-setup.sh            sets the agent up and starts it
#   script/updater-setup.sh remove     stops the agent and removes it and its state
# The updater pulls and installs from the checkout this script lives in (its main worktree),
# or OTOS_UPDATER_CHECKOUT. Run by the updater itself after an install (OTOS_UPDATER=1), it
# only refreshes the agent's copy of auto-update.sh and its agent file: reloading the agent
# would stop the run in progress, and launchd reads a changed agent file at the next login.
# Tested by script/updater-test.sh (LAUNCHCTL replaces launchctl there).
set -euo pipefail

LABEL=net.melisma.Otos.updater
UPDATER_HOME="${OTOS_UPDATER_HOME:-$HOME/Library/Application Support/net.melisma.Otos.updater}"
AGENTS="${OTOS_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS/$LABEL.plist"
LOG="${OTOS_UPDATER_LOG:-$HOME/Library/Logs/Otos Updater.log}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
TEAM_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/otos/development-team"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
domain="gui/$(id -u)"

if [[ "${1:-}" == remove ]]; then
  "$LAUNCHCTL" bootout "$domain/$LABEL" 2> /dev/null || true
  rm -f "$PLIST"
  rm -rf "$UPDATER_HOME"
  echo "op=updater.setup phase=removed log=\"$LOG\""
  exit 0
fi

checkout="${OTOS_UPDATER_CHECKOUT:-$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")}"
# An install without the signing team builds an app signed to run locally only: the
# installed app's TCC grants and Keychain items belong to the team-signed identity.
if [[ -z "${OTOS_DEVELOPMENT_TEAM:-}" && ! -r "$TEAM_FILE" ]]; then
  echo "op=updater.setup phase=refused reason=noDevelopmentTeam file=\"$TEAM_FILE\"" >&2
  exit 1
fi

mkdir -p "$UPDATER_HOME/requests" "$AGENTS" "$(dirname "$LOG")"
# Replaced by a rename: a run in progress keeps reading the file it opened.
cp "$here/auto-update.sh" "$UPDATER_HOME/auto-update.sh.new"
chmod 755 "$UPDATER_HOME/auto-update.sh.new"
mv -f "$UPDATER_HOME/auto-update.sh.new" "$UPDATER_HOME/auto-update.sh"

xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
cat > "$PLIST.new" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$(xml "$UPDATER_HOME/auto-update.sh")</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>OTOS_UPDATER_HOME</key>
		<string>$(xml "$UPDATER_HOME")</string>
		<key>OTOS_UPDATER_CHECKOUT</key>
		<string>$(xml "$checkout")</string>
		<key>OTOS_UPDATER_LOG</key>
		<string>$(xml "$LOG")</string>
	</dict>
	<key>StartInterval</key>
	<integer>900</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>QueueDirectories</key>
	<array>
		<string>$(xml "$UPDATER_HOME/requests")</string>
	</array>
	<key>ProcessType</key>
	<string>Standard</string>
	<key>StandardOutPath</key>
	<string>$(xml "$LOG")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$LOG")</string>
</dict>
</plist>
EOF
changed=1
if [[ -f "$PLIST" ]] && cmp -s "$PLIST" "$PLIST.new"; then changed=""; fi
mv -f "$PLIST.new" "$PLIST"
if [[ "${OTOS_UPDATER:-}" == 1 ]]; then
  echo "op=updater.setup phase=refreshed agentFileChanged=${changed:-0}"
  exit 0
fi
if "$LAUNCHCTL" print "$domain/$LABEL" > /dev/null 2>&1; then
  if [[ -z "$changed" ]]; then
    echo "op=updater.setup phase=current checkout=\"$checkout\""
    exit 0
  fi
  # Reloading stops a run in progress, which may be in the middle of an install.
  if [[ -x /usr/bin/lockf ]] && ! /usr/bin/lockf -t 0 "$UPDATER_HOME/lock" true 2> /dev/null; then
    echo "op=updater.setup phase=deferred reason=runInProgress detail=\"the new agent file is used from the next login\""
    exit 0
  fi
  "$LAUNCHCTL" bootout "$domain/$LABEL" 2> /dev/null || true
fi
"$LAUNCHCTL" bootstrap "$domain" "$PLIST"
echo "op=updater.setup phase=started checkout=\"$checkout\" log=\"$LOG\""
