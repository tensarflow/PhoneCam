#!/bin/zsh
# Builds a notarized, ready-to-download PhoneCam DMG.
#
#   Scripts/release.sh 1.0.0            build, sign, notarize -> build/release/PhoneCam-1.0.0.dmg
#   Scripts/release.sh 1.0.0 --publish  ...and create the GitHub release v1.0.0 with the DMG
#
# Needs: a team with Developer ID signing in Config/Signing.local.xcconfig, Xcode signed in
# to that team, and notarization credentials stored once with:
#   xcrun notarytool store-credentials PhoneCam-notary --apple-id YOU@example.com --team-id TEAMID
set -euo pipefail

VERSION=${1:?usage: Scripts/release.sh VERSION [--publish]}
PUBLISH=${2:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-PhoneCam-notary}

cd "${0:A:h}/.."
OUT=build/release
ARCHIVE=$OUT/PhoneCam.xcarchive
TEAM=$(awk -F' *= *' '/^DEVELOPMENT_TEAM/ {print $2}' Config/Signing.local.xcconfig 2>/dev/null || true)
[[ -n "$TEAM" ]] || { echo "Set DEVELOPMENT_TEAM in Config/Signing.local.xcconfig"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate --quiet

echo "==> Archiving PhoneCam $VERSION"
xcodebuild -project PhoneCam.xcodeproj -scheme PhoneCam -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates MARKETING_VERSION="$VERSION" archive -quiet

echo "==> Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet
APP=$OUT/export/PhoneCam.app
codesign --verify --deep --strict "$APP"

echo "==> Notarizing (takes a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/PhoneCam.zip"
xcrun notarytool submit "$OUT/PhoneCam.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"

echo "==> Building DMG"
STAGE=$OUT/dmg
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PhoneCam.app"
ln -s /Applications "$STAGE/Applications"
DMG=$OUT/PhoneCam-$VERSION.dmg
hdiutil create -volname "PhoneCam $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG" -quiet
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$DMG"
echo "sha256 $SHA"

if [[ "$PUBLISH" == "--publish" ]]; then
  echo "==> Publishing GitHub release v$VERSION"
  gh release create "v$VERSION" "$DMG" --title "PhoneCam $VERSION" --notes-file - <<EOF
Download **PhoneCam-$VERSION.dmg**, open it and drag PhoneCam to Applications — or install with Homebrew:

\`\`\`sh
brew install --cask tensarflow/tap/phonecam
\`\`\`

Then follow [Get started](https://github.com/tensarflow/PhoneCam#get-started).

SHA-256: \`$SHA\`
EOF
fi
