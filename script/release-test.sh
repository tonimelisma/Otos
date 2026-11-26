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

if ((failures > 0)); then
  echo "op=release.test phase=fail cases=$cases failures=$failures" >&2
  exit 1
fi
echo "op=release.test phase=pass cases=$cases"
