#!/usr/bin/env bash
# release.sh — builds Blit.app signed with Developer ID, notarizes it with
# Apple, staples the ticket, and zips it. Optionally installs to /Applications.
#
# One-time setup (you enter your own credentials; they stay in your Keychain):
#   xcrun notarytool store-credentials blit-notary \
#     --apple-id you@example.com --team-id F87BNUZAVJ
#   (it asks for an app-specific password from account.apple.com)
#
# Usage:
#   scripts/release.sh                 # build, notarize, staple → build/release/
#   INSTALL=1 scripts/release.sh       # …then replace /Applications/Blit.app
#   SKIP_NOTARIZE=1 scripts/release.sh # sign and export only
#   PUBLISH=1 INSTALL=1 NOTES="What changed" scripts/release.sh
#                                      # …then publish it as an update: sign the zip for
#                                      # Sparkle, put it on the site (site/downloads/),
#                                      # write site/appcast.xml, commit and push (Cloudflare
#                                      # Pages deploys it to blit.banast.as)
#
# Environment: NOTARY_PROFILE (default blit-notary), OUT (default build/release)

set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=F87BNUZAVJ
PROFILE=${NOTARY_PROFILE:-blit-notary}
OUT=${OUT:-build/release}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archiving (Release)"
xcodebuild -project Blit.xcodeproj -scheme Blit -configuration Release \
  -archivePath "$OUT/Blit.xcarchive" -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates -quiet archive

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/Blit.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT" -allowProvisioningUpdates -quiet

APP="$OUT/Blit.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^Authority=Developer ID|^TeamIdentifier|runtime" || true

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  echo "==> Notarizing (this usually takes a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/Blit-notarize.zip"
  xcrun notarytool submit "$OUT/Blit-notarize.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$OUT/Blit-notarize.zip"
  spctl --assess --type execute -vv "$APP"
fi

ZIP="$OUT/Blit-$VERSION-$BUILD.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> $ZIP"

if [[ "${PUBLISH:-0}" == 1 ]]; then
  [[ "${SKIP_NOTARIZE:-0}" == 1 ]] && { echo "PUBLISH needs a notarized build"; exit 1; }
  echo "==> Publishing $VERSION ($BUILD) as an update"
  # Sparkle's tools come with the Sparkle package Xcode resolved for this project.
  SPARKLE_BIN=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Blit-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)
  [[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle's sign_update not found (build the project in Xcode once)"; exit 1; }
  # EdDSA signature and length, signed with the private key in the Keychain.
  SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP")
  MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "27.0")
  mkdir -p site/downloads
  rm -f site/downloads/Blit-*.zip            # the site keeps the current release only
  cp "$ZIP" "site/downloads/Blit-$VERSION.zip"
  cp "$ZIP" site/downloads/Blit.zip          # stable name for the Download button
  NOTES_HTML=$(printf '%s' "${NOTES:-Bug fixes and improvements.}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  cat > site/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Blit</title>
    <link>https://blit.banast.as/appcast.xml</link>
    <description>Updates for Blit</description>
    <language>en</language>
    <item>
      <title>Blit $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES_HTML</p>]]></description>
      <enclosure url="https://blit.banast.as/downloads/Blit-$VERSION.zip" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
  git add site/downloads site/appcast.xml
  git commit -q -m "Publish Blit $VERSION ($BUILD)" -- site/downloads site/appcast.xml
  git push -q
  echo "==> Published: https://blit.banast.as/downloads/Blit-$VERSION.zip (deploys in about a minute)"
fi

if [[ "${INSTALL:-0}" == 1 ]]; then
  echo "==> Installing to /Applications"
  osascript -e 'tell application id "com.banastas.Blit" to quit' 2>/dev/null || true
  # Mid-transfer, Blit saves the queue and closes connections before it exits:
  # wait for it (up to 60 s) so the new copy doesn't launch into the old one.
  for _ in $(seq 60); do
    pgrep -f "/Applications/Blit.app/Contents/MacOS/Blit" >/dev/null || break
    sleep 1
  done
  rm -rf /Applications/Blit.app
  ditto "$APP" /Applications/Blit.app
  open /Applications/Blit.app || { sleep 3; open /Applications/Blit.app; }
fi

# Only the installed app should stay registered under Blit's bundle ID: build
# copies left in Launch Services can end up supplying Notification Center's icon.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in "$APP" "$HOME"/Library/Developer/Xcode/DerivedData/Blit-*/Build/Products/Release/Blit.app \
            "$HOME"/Library/Developer/Xcode/DerivedData/Blit-*/Build/Intermediates.noindex/ArchiveIntermediates/Blit/InstallationBuildProductsLocation/Applications/Blit.app; do
  if [[ -d "$copy" ]]; then "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true; fi
done
