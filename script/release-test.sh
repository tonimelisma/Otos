#!/usr/bin/env bash
# The release's rules that need no Mac (ADR 0059): the feed script/appcast.sh writes for a
# build, the inputs it refuses, and that the advisory check asks about the Sparkle the project
# pins. script/check.sh runs it with the fast gates.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST="$ROOT_DIR/script/appcast.sh"
failures=0
cases=0
fail() {
  echo "op=release.test phase=fail case=$1 detail=\"$2\"" >&2
  failures=$((failures + 1))
}
url="https://github.com/tonimelisma/Otos/releases/download/build-1234/Otos-1234.zip"
signature="pGRm4pfxg2s1mJ3vyb0U2PsVfDNNGMzJ6sS9hHOsQ0PxN1yH4bVAw8yWKkS0oYvN5ZQy2kXmDbqk4z7ZcVg0Bw=="

cases=$((cases + 1))
feed="$("$APPCAST" 1234 1.0 "$url" 5678 "$signature")"
read -r version short enclosure length signed minimum < <(printf '%s' "$feed" | /usr/bin/python3 -I -c '
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.fromstring(sys.stdin.read()).findall("./channel/item")
assert len(items) == 1, "one item"
item = items[0]
e = item.find("enclosure")
key = "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"
print(item.find("sparkle:version", ns).text, item.find("sparkle:shortVersionString", ns).text,
      e.get("url"), e.get("length"), e.get(key), item.find("sparkle:minimumSystemVersion", ns).text)
')
[[ "$version" == 1234 ]] || fail feedNamesTheBuild "version=$version"
[[ "$short" == 1.0 ]] || fail feedNamesTheBuild "short=$short"
[[ "$enclosure" == "$url" && "$length" == 5678 ]] || fail feedNamesTheArchive "url=$enclosure length=$length"
[[ "$signed" == "$signature" ]] || fail feedCarriesTheSignature "signature=$signed"
[[ "$minimum" == 27.0 ]] || fail feedNamesTheSystem "minimum=$minimum"

refuses() { # <case> <args...>
  cases=$((cases + 1))
  local name="$1"
  shift
  if "$APPCAST" "$@" > /dev/null 2>&1; then fail "$name" "accepted: $*"; fi
}
refuses notANumber abc 1.0 "$url" 5678 "$signature"
refuses archiveOfAnotherBuild 1235 1.0 "$url" 5678 "$signature"
refuses archiveElsewhere 1234 1.0 "https://example.com/build-1234/Otos-1234.zip" 5678 "$signature"
refuses emptyArchive 1234 1.0 "$url" 0 "$signature"
refuses signatureNotBase64 1234 1.0 "$url" 5678 'a"b<c'
refuses urlNeedsEscaping 1234 1.0 "${url}?a=1&b=2" 5678 "$signature"

# The advisory check asks about the version the project pins (ADR 0059).
cases=$((cases + 1))
resolved="$("$ROOT_DIR/script/sparkle-advisories.sh" version)"
pinned="$(awk '/XCRemoteSwiftPackageReference "Sparkle" \*\/ = \{/ { inside = 1 } inside && /version = / { gsub(/[ \t;]/, ""); sub(/version=/, ""); print; exit }' "$ROOT_DIR/Otos.xcodeproj/project.pbxproj")"
[[ -n "$resolved" && "$resolved" == "$pinned" ]] || fail sparklePinAgrees "Package.resolved=$resolved project=$pinned"

# The owner's one-time setup (script/release-setup.sh), against a generated checkout and
# fakes for gh, security, openssl and generate_keys: it sets the four secrets,
# exports only the team's identity, commits the public key by pull request, builds and
# installs nothing, and never prints a secret value.
cases=$((cases + 1))
setup_work="$(mktemp -d)"
(
  set -euo pipefail
  w="$setup_work"
  mkdir -p "$w/bin" "$w/config/otos" "$w/calls" "$w/secrets"
  printf 'TEAM123456\n' > "$w/config/otos/development-team"
  git init -q -b main "$w/seed"
  mkdir -p "$w/seed/Otos.xcodeproj"
  printf 'a\n\t\t\t\tOTOS_SPARKLE_PUBLIC_ED_KEY = "";\nb\n\t\t\t\tOTOS_SPARKLE_PUBLIC_ED_KEY = "";\n' > "$w/seed/Otos.xcodeproj/project.pbxproj"
  git -C "$w/seed" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$w/seed" -c user.name=t -c user.email=t@example.invalid commit -q -m seed
  git clone -q --bare "$w/seed" "$w/remote.git"
  git clone -q "$w/remote.git" "$w/checkout"
  git -C "$w/checkout" config user.name t
  git -C "$w/checkout" config user.email t@example.invalid
  cat > "$w/bin/gh" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/calls/gh"
case "$1 $2" in
  "auth status") exit 0 ;;
  "secret set") cat > "$FAKE/secrets/$3" ;;
  "pr list") ;;
  "pr create") echo "https://github.com/tonimelisma/Otos/pull/999" ;;
  "pr merge") exit 0 ;;
esac
EOF
  cat > "$w/bin/generate_keys" << 'EOF'
#!/usr/bin/env bash
# Otos's own keychain account, always: the shared default would sign with another app's key.
[[ "${1:-}" == --account && "${2:-}" == net.melisma.Otos ]] || exit 9
shift 2
case "${1:-}" in
  -p) [[ -f "$FAKE/key" ]] && echo "PUBLICKEYPUBLICKEYPUBLICKEYPUBLICKEYPUBLICKEY=" || exit 1 ;;
  -x) printf 'PRIVATESEEDSECRETVALUE' > "$2" ;;
  "") touch "$FAKE/key" ;;
esac
EOF
  cat > "$w/bin/security" << 'EOF'
#!/usr/bin/env bash
echo "$1" >> "$FAKE/calls/security"
case "$1" in
  find-identity)
    echo '  1) AAAA1111 "Apple Development: Other (X1)"'
    echo '  2) BBBB2222 "Apple Development: Owner (X2)"' ;;
  find-certificate)
    printf 'SHA-1 hash: AAAA1111\n-----BEGIN CERTIFICATE-----\nOTHERTEAM\n-----END CERTIFICATE-----\n'
    printf 'SHA-1 hash: BBBB2222\n-----BEGIN CERTIFICATE-----\nOWNERTEAM\n-----END CERTIFICATE-----\n' ;;
  export) while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && printf 'P12BYTES' > "$2"; shift; done ;;
  delete-identity) echo "deleted $3" >> "$FAKE/calls/deleted" ;;
esac
EOF
  cat > "$w/bin/openssl" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  x509) grep -q OWNERTEAM && echo "subject=UID=1, CN=Apple Development: Owner, OU=TEAM123456" || echo "subject=OU=OTHERTEAM0" ;;
  rand) [[ "$2" == -base64 ]] && echo "P12PASSWORDSECRETVALUE" || echo "0123abcd" ;;
esac
EOF
  chmod +x "$w/bin/"*
  FAKE="$w" XDG_CONFIG_HOME="$w/config" OTOS_SETUP_ROOT="$w/checkout" OTOS_SETUP_GH="$w/bin/gh" \
    OTOS_SETUP_SECURITY="$w/bin/security" OTOS_SETUP_OPENSSL="$w/bin/openssl" \
    OTOS_SETUP_GENERATE_KEYS="$w/bin/generate_keys" \
    OTOS_SETUP_LOGIN_KEYCHAIN="$w/login.keychain-db" \
    "$ROOT_DIR/script/release-setup.sh" > "$w/out" 2>&1 || { cat "$w/out" >&2; exit 10; }
  export FAKE="$w"
  for name in OTOS_SPARKLE_PRIVATE_KEY OTOS_DEVELOPMENT_TEAM OTOS_CERTIFICATE_P12 OTOS_CERTIFICATE_PASSWORD; do
    [[ -s "$w/secrets/$name" ]] || exit 11
  done
  [[ "$(cat "$w/secrets/OTOS_SPARKLE_PRIVATE_KEY")" == PRIVATESEEDSECRETVALUE ]] || exit 12
  [[ "$(cat "$w/secrets/OTOS_DEVELOPMENT_TEAM")" == TEAM123456 ]] || exit 13
  [[ "$(cat "$w/secrets/OTOS_CERTIFICATE_PASSWORD")" == P12PASSWORDSECRETVALUE ]] || exit 14
  ! grep -qE 'PRIVATESEEDSECRETVALUE|P12PASSWORDSECRETVALUE|UDEyQllURVM' "$w/out" || exit 15
  grep -q "environments/release" "$w/calls/gh" || exit 16
  grep -q "deleted AAAA1111" "$w/calls/deleted" && ! grep -q "deleted BBBB2222" "$w/calls/deleted" || exit 17
  grep -q 'phase=certificate identity=BBBB2222' "$w/out" || exit 18
  [[ "$(git -C "$w/remote.git" show chore/sparkle-update-key:Otos.xcodeproj/project.pbxproj | grep -c 'OTOS_SPARKLE_PUBLIC_ED_KEY = "PUBLICKEYPUBLICKEYPUBLICKEYPUBLICKEYPUBLICKEY=";')" == 2 ]] || exit 19
  grep -q 'phase=done next=.*releases/latest/download/Otos.dmg' "$w/out" || exit 20
  [[ "$(git -C "$w/checkout" symbolic-ref --short HEAD)" == main ]] || exit 21
  grep -q "pr merge https://github.com/tonimelisma/Otos/pull/999 --squash --auto" "$w/calls/gh" || exit 22
) || fail setupDoesItAll "exit $?"
rm -rf "$setup_work"

if ((failures > 0)); then
  echo "op=release.test phase=fail cases=$cases failures=$failures" >&2
  exit 1
fi
echo "op=release.test phase=pass cases=$cases"
