#!/usr/bin/env bash
# The owner's one-time setup of the installed app's self-update (ADR 0059), on the Mac, in
# the primary checkout on a clean `main`:
#   script/release-setup.sh
# 1. Makes Otos's EdDSA update key in the login keychain with Sparkle's generate_keys, from
#    Sparkle's release archive, or uses the one already there.
# 2. Creates the repository's environment `release` and sets its four secrets with the owner's
#    own `gh` login: the update key, the team's newest Apple Development certificate that
#    Apple's revocation service accepts (team from ~/.config/otos/development-team; only that
#    identity, exported from the login keychain; macOS asks to allow the export), a random
#    password for that export, and the team ID.
# 3. Commits the public key as OTOS_SPARKLE_PUBLIC_ED_KEY and opens its pull request, which
#    merges once CI passes.
# It builds and installs nothing: CI builds every release, and the first install is the disk
# image of the first release, https://github.com/tonimelisma/Otos/releases/latest/download/Otos.dmg.
# Every secret value goes from a private temporary folder, removed however the script ends,
# to `gh secret set` on standard input: nothing is printed, logged or committed. Safe to run
# again: it reuses the key, sets the secrets anew and skips what is done.
# Tested by script/release-test.sh with fakes for every tool (OTOS_SETUP_* below).
set -euo pipefail

ROOT_DIR="${OTOS_SETUP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="${OTOS_SETUP_REPO:-tonimelisma/Otos}"
GH="${OTOS_SETUP_GH:-gh}"
SECURITY="${OTOS_SETUP_SECURITY:-/usr/bin/security}"
OPENSSL="${OTOS_SETUP_OPENSSL:-/usr/bin/openssl}"
TEAM_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/otos/development-team"
PROJECT="$ROOT_DIR/Otos.xcodeproj/project.pbxproj"
LOGIN_KEYCHAIN="${OTOS_SETUP_LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
BRANCH="chore/sparkle-update-key"
KEY_ACCOUNT="net.melisma.Otos"

say() { echo "op=release.setup $*"; }
refuse() {
  echo "op=release.setup phase=refused $*" >&2
  exit 1
}

# The checkout and the tools.
[[ -r "$TEAM_FILE" ]] || refuse "reason=noDevelopmentTeam file=\"$TEAM_FILE\""
TEAM="$(tr -d '[:space:]' < "$TEAM_FILE")"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || refuse "reason=developmentTeamNotATeamID file=\"$TEAM_FILE\""
"$GH" auth status > /dev/null 2>&1 || refuse "reason=ghNotSignedIn detail=\"run: gh auth login\""
[[ "$(git -C "$ROOT_DIR" symbolic-ref --short -q HEAD)" == main ]] || refuse "reason=notOnMain"
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || refuse "reason=dirtyTree"
git -C "$ROOT_DIR" pull -q --ff-only origin main || refuse "reason=pullFailed"

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"; git -C "$ROOT_DIR" checkout -q main 2> /dev/null || true' EXIT

# 1. The update key, with Sparkle's own generate_keys from its release archive (the version
# the project pins, checked by its SHA-256): nothing is built here.
SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
if [[ -z "${OTOS_SETUP_GENERATE_KEYS:-}" ]]; then
  curl -sSfL -o "$work/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    || refuse "reason=sparkleDownloadFailed"
  echo "$SPARKLE_SHA256  $work/sparkle.tar.xz" | shasum -a 256 -c - > /dev/null || refuse "reason=sparkleChecksumMismatch"
  mkdir "$work/sparkle"
  tar -xJf "$work/sparkle.tar.xz" -C "$work/sparkle" ./bin/generate_keys
fi
GENERATE_KEYS="${OTOS_SETUP_GENERATE_KEYS:-$work/sparkle/bin/generate_keys}"
[[ -x "$GENERATE_KEYS" ]] || refuse "reason=noGenerateKeys path=\"$GENERATE_KEYS\""
# Otos's own keychain account: without one, generate_keys uses a default account every app
# signed this way shares, and two apps would then sign their updates with one key.
if ! public_key="$("$GENERATE_KEYS" --account "$KEY_ACCOUNT" -p 2> /dev/null)" || [[ -z "$public_key" ]]; then
  "$GENERATE_KEYS" --account "$KEY_ACCOUNT" > /dev/null
  public_key="$("$GENERATE_KEYS" --account "$KEY_ACCOUNT" -p)"
fi
public_key="$(printf '%s' "$public_key" | tr -d '[:space:]')"
[[ "$public_key" =~ ^[A-Za-z0-9+/=]{40,}$ ]] || refuse "reason=publicKeyUnreadable"
say "phase=updateKey publicKey=$public_key"

# 2. The environment and its secrets.
"$GH" api -X PUT "repos/$REPO/environments/release" > /dev/null
secret() { # <name> <file>
  "$GH" secret set "$1" --env release --repo "$REPO" < "$2" > /dev/null
  say "phase=secretSet name=$1"
}
"$GENERATE_KEYS" --account "$KEY_ACCOUNT" -x "$work/sparkle.key" > /dev/null
secret OTOS_SPARKLE_PRIVATE_KEY "$work/sparkle.key"
printf '%s' "$TEAM" > "$work/team"
secret OTOS_DEVELOPMENT_TEAM "$work/team"

# The team's Apple Development identity: of those whose certificate's organizational unit is
# the team, the newest that Apple's revocation service (OCSP) still accepts for code signing.
# A revoked or expired one can still read as valid in the login keychain, and Xcode on the
# release runner refuses it. The login keychain exports every identity at once, so they go
# into a keychain of this run's own, every other identity is deleted there, and that keychain
# is exported.
"$SECURITY" find-certificate -a -Z -p "$LOGIN_KEYCHAIN" > "$work/certs.pem"
certificate_of() { # <sha-1>: its PEM
  awk -v sha="$1" '
    /^SHA-1 hash:/ { keep = ($3 == sha) }
    keep && /BEGIN CERTIFICATE/ { inside = 1 }
    keep && inside { print }
    keep && /END CERTIFICATE/ { exit }' "$work/certs.pem"
}
chosen=""
chosen_start=0
while read -r sha; do
  certificate_of "$sha" > "$work/candidate.pem"
  subject="$("$OPENSSL" x509 -noout -subject < "$work/candidate.pem" 2> /dev/null || true)"
  [[ "$subject" == *"OU=$TEAM"* || "$subject" == *"OU = $TEAM"* ]] || continue
  if ! "$SECURITY" verify-cert -q -c "$work/candidate.pem" -p codeSign -R ocsp -R require > /dev/null 2>&1; then
    say "phase=certificate identity=$sha state=revokedOrExpired"
    continue
  fi
  start="$("$OPENSSL" x509 -noout -startdate < "$work/candidate.pem" | sed 's/^notBefore=//')"
  start="$(/usr/bin/env python3 -I -c '
import calendar, sys, time
print(calendar.timegm(time.strptime(" ".join(sys.argv[1].split()), "%b %d %H:%M:%S %Y %Z")))
' "$start")" || refuse "reason=certificateDateUnreadable identity=$sha"
  if ((start > chosen_start)); then
    chosen="$sha"
    chosen_start="$start"
  fi
done < <("$SECURITY" find-identity -v -p codesigning "$LOGIN_KEYCHAIN" | awk '/"Apple Development/ { print $2 }')
[[ -n "$chosen" ]] || refuse "reason=noValidAppleDevelopmentIdentity team=$TEAM detail=\"make one in Xcode, Settings, Accounts, Manage Certificates, then run this again\""
"$OPENSSL" rand -base64 24 | tr -d '\n' > "$work/p12-password"
kc="$work/export.keychain-db"
kc_password="$("$OPENSSL" rand -hex 16)"
"$SECURITY" export -k "$LOGIN_KEYCHAIN" -t identities -f pkcs12 -P "$(cat "$work/p12-password")" -o "$work/all.p12" > /dev/null
"$SECURITY" create-keychain -p "$kc_password" "$kc"
"$SECURITY" unlock-keychain -p "$kc_password" "$kc"
"$SECURITY" import "$work/all.p12" -k "$kc" -P "$(cat "$work/p12-password")" > /dev/null
# Every identity, the invalid ones too (`-v` would hide a revoked one, and it would be
# exported); find-identity lists a valid one twice.
while read -r sha; do
  [[ "$sha" == "$chosen" ]] || "$SECURITY" delete-identity -Z "$sha" "$kc" > /dev/null
done < <("$SECURITY" find-identity "$kc" | awk '/^ *[0-9]+\)/ && !seen[$2]++ { print $2 }')
"$SECURITY" export -k "$kc" -t identities -f pkcs12 -P "$(cat "$work/p12-password")" -o "$work/identity.p12" > /dev/null
"$SECURITY" delete-keychain "$kc"
base64 < "$work/identity.p12" | tr -d '\n' > "$work/identity.p12.base64"
secret OTOS_CERTIFICATE_P12 "$work/identity.p12.base64"
secret OTOS_CERTIFICATE_PASSWORD "$work/p12-password"
say "phase=certificate identity=$chosen"

# 3. The public key in the project, by pull request; main takes no direct pushes.
if grep -q "OTOS_SPARKLE_PUBLIC_ED_KEY = \"$public_key\";" "$PROJECT"; then
  say "phase=publicKey state=committed"
else
  git -C "$ROOT_DIR" checkout -q -B "$BRANCH"
  sed -i '' "s|OTOS_SPARKLE_PUBLIC_ED_KEY = \"[^\"]*\";|OTOS_SPARKLE_PUBLIC_ED_KEY = \"$public_key\";|" "$PROJECT" 2> /dev/null \
    || sed -i "s|OTOS_SPARKLE_PUBLIC_ED_KEY = \"[^\"]*\";|OTOS_SPARKLE_PUBLIC_ED_KEY = \"$public_key\";|" "$PROJECT"
  [[ "$(grep -c "OTOS_SPARKLE_PUBLIC_ED_KEY = \"$public_key\";" "$PROJECT")" == 2 ]] || refuse "reason=projectNotUpdated"
  git -C "$ROOT_DIR" commit -q -m "chore: the installed app carries Otos's Sparkle update key (ADR 0059)" -- "$PROJECT"
  # The branch is this script's own: a run again replaces what an earlier run pushed there.
  git -C "$ROOT_DIR" push -q -u --force origin "$BRANCH"
  url="$("$GH" pr list --repo "$REPO" --head "$BRANCH" --state open --json url --jq '.[0].url // empty')"
  if [[ -z "$url" ]]; then
    url="$("$GH" pr create --repo "$REPO" --head "$BRANCH" --base main \
      --title "chore: the installed app carries Otos's Sparkle update key" \
      --body "The public half of Otos's Sparkle update key (ADR 0059), made by script/release-setup.sh. The private half is in the owner's login keychain, under the account net.melisma.Otos, and the environment release.")"
  fi
  "$GH" pr merge "$url" --squash --auto > /dev/null 2>&1 \
    && say "phase=publicKey state=mergesWhenCIPasses pr=$url" \
    || say "phase=publicKey state=awaitingMerge pr=$url"
fi

# Nothing is built or installed here: CI builds every release. Once the key's pull request is
# merged, the first release's disk image is the one install made by hand.
say "phase=done next=\"once the pull request above is merged, install from https://github.com/$REPO/releases/latest/download/Otos.dmg; it updates itself from then on\""
