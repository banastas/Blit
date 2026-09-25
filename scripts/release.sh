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

if [[ "${INSTALL:-0}" == 1 ]]; then
  echo "==> Installing to /Applications"
  osascript -e 'tell application id "com.banastas.Blit" to quit' 2>/dev/null || true
  sleep 2
  rm -rf /Applications/Blit.app
  ditto "$APP" /Applications/Blit.app
  open /Applications/Blit.app
fi
