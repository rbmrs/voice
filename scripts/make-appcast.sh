#!/bin/zsh
# Generate dist/appcast.xml — the Sparkle update feed — for the current DMG.
# The DMG is EdDSA-signed and its signature embedded in the feed's enclosure.
#
# Env:
#   VERSION              (required) marketing version, e.g. 0.1.13 — matches CFBundleShortVersionString
#   BUILD                (required) build number, must equal the app's CFBundleVersion
#   SUMMARY              (optional) one-line release note shown in the updater
#   SPARKLE_PRIVATE_KEY  (optional) base64 key seed from `generate_keys -x`. In CI this comes
#                        from the repo secret; locally, omit it and the key is read from your
#                        Keychain instead.
#
# Output: dist/appcast.xml  (upload alongside the DMG as a release asset)

set -euo pipefail

root=${0:A:h:h}
cd "$root"

VERSION=${VERSION:?set VERSION}
BUILD=${BUILD:?set BUILD}
SUMMARY=${SUMMARY:-"Voice $VERSION"}

dmg="dist/Voice-$VERSION.dmg"
[[ -f "$dmg" ]] || { echo "missing $dmg — run scripts/make-dmg.sh first"; exit 1; }

sign_bin=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$sign_bin" ]] || { echo "missing $sign_bin — run swift build first"; exit 1; }

# EdDSA-sign the DMG. Key from env (CI, via stdin) or Keychain (local).
# sign_update prints ready-to-use enclosure attributes: sparkle:edSignature="..." length="..."
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  enclosure_attrs=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_bin" --ed-key-file - "$dmg")
else
  echo "==> no SPARKLE_PRIVATE_KEY in env; signing with Keychain key"
  enclosure_attrs=$("$sign_bin" "$dmg")
fi

pubdate=$(date "+%a, %d %b %Y %H:%M:%S %z")
url="https://github.com/rbmrs/voice/releases/download/v${VERSION}/Voice-${VERSION}.dmg"

mkdir -p dist
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Voice</title>
    <link>https://github.com/rbmrs/voice/releases/latest/download/appcast.xml</link>
    <description>Voice updates</description>
    <language>en</language>
    <item>
      <title>${VERSION}</title>
      <description><![CDATA[${SUMMARY}]]></description>
      <pubDate>${pubdate}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/rbmrs/voice/releases/tag/v${VERSION}</link>
      <enclosure url="${url}" ${enclosure_attrs} type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "==> wrote dist/appcast.xml"
cat dist/appcast.xml
