#!/usr/bin/env bash
# Writes Sparkle's update feed for one build of the installed app (ADR 0059) to standard
# output:
#   script/appcast.sh <build> <version x.y.z> <archive URL> <archive length> <EdDSA signature>
# <build> is CFBundleVersion, the commit count Sparkle compares; <version> is the release's
# `v<x.y.z>` and CFBundleShortVersionString. The feed holds only the newest build, because
# Sparkle needs nothing older. The app reads it from
# https://github.com/tonimelisma/Otos/releases/latest/download/appcast.xml (SUFeedURL).
# Tested by script/release-test.sh.
set -euo pipefail

BUILD="${1:?usage: appcast.sh <build> <version> <url> <length> <signature>}"
SHORT="${2:?version}"
URL="${3:?archive URL}"
LENGTH="${4:?archive length}"
SIGNATURE="${5:?EdDSA signature}"
MINIMUM_SYSTEM="27.0"

[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "appcast: build $BUILD isn't a positive number" >&2; exit 1; }
[[ "$SHORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "appcast: version $SHORT isn't x.y.z" >&2; exit 1; }
[[ "$LENGTH" =~ ^[1-9][0-9]*$ ]] || { echo "appcast: length $LENGTH isn't a positive number" >&2; exit 1; }
case "$URL" in
  "https://github.com/tonimelisma/Otos/releases/download/v$SHORT/"*) ;;
  *) echo "appcast: the archive isn't in the release v$SHORT of tonimelisma/Otos" >&2; exit 1 ;;
esac
# A signature is base64 and the URL is checked above, so nothing written needs escaping in
# XML; anything else is refused.
[[ "$SIGNATURE" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "appcast: the signature isn't base64" >&2; exit 1; }
[[ "$URL" != *[\&\<\>\"]* ]] || { echo "appcast: the URL holds a character XML would need escaped" >&2; exit 1; }
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Otos</title>
    <item>
      <title>Otos $SHORT</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
