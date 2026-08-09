#!/usr/bin/env bash
# Build a signed, notarized, distributable macOS .app + .dmg of the Calendar app.
#
#   archive → export (Developer ID) → notarize → staple → DMG → staple DMG
#
# Prerequisites (one-time — see native/CalendarApp/DISTRIBUTE.md for the full runbook):
#   • A "Developer ID Application" certificate in your login keychain
#       security find-identity -v -p codesigning   # should list "Developer ID Application: …"
#   • A stored notarytool credential profile:
#       xcrun notarytool store-credentials libirabu-notary \
#         --apple-id "you@example.com" --team-id X84ZG75WAM --password <app-specific-password>
#   • The CloudKit schema DEPLOYED TO PRODUCTION (CloudKit Console → Deploy Schema Changes),
#     because a Developer-ID build talks to the CloudKit *production* environment.
#
# Usage:
#   native/CalendarApp/scripts/package.sh              # full signed+notarized build
#   NOTARIZE=0 native/CalendarApp/scripts/package.sh   # skip notarization (local smoke test)
#   NOTARY_PROFILE=my-profile native/CalendarApp/scripts/package.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(cd "$HERE/.." && pwd)"
cd "$PROJ_DIR"

SCHEME="MagnifiCalRelease"   # shared Release scheme defined in project.yml (archives the CalendarApp target)
APP_NAME="${APP_NAME:-MagnifiCal}"   # must match PRODUCT_NAME in project.yml
TEAM_ID="${TEAM_ID:-X84ZG75WAM}"
NOTARY_PROFILE="${NOTARY_PROFILE:-libirabu-notary}"
NOTARIZE="${NOTARIZE:-1}"

BUILD="$PROJ_DIR/build"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/$APP_NAME.app"
DMG="$BUILD/$APP_NAME.dmg"

echo "▸ clean"
rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "▸ regenerate Xcode project from project.yml"
xcodegen generate >/dev/null

echo "▸ archive (Release)"
xcodebuild -project "CalendarApp.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates archive >/dev/null

echo "▸ export (Developer ID, automatic signing)"
# -allowProvisioningUpdates lets xcodebuild create/download the Developer ID provisioning
# profile that carries the iCloud/CloudKit entitlement (automatic signing won't otherwise).
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$HERE/ExportOptions.plist" \
  -exportPath "$EXPORT" -allowProvisioningUpdates >/dev/null

[ -d "$APP" ] || { echo "✗ export produced no $APP_NAME.app"; exit 1; }
echo "  → $APP  ($(du -sh "$APP" | cut -f1))"

if [ "$NOTARIZE" = "1" ]; then
  echo "▸ notarize (this uploads the app to Apple and waits)"
  ZIP="$BUILD/$APP_NAME.zip"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▸ staple ticket to the .app"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
else
  echo "▸ skipping notarization (NOTARIZE=0) — Gatekeeper will warn on other Macs"
fi

echo "▸ render DMG volume icon (system disk-image icon + app icon composite)"
DMGICON="$BUILD/dmg-icon.icns"
swift "$HERE/make-dmg-icon.swift" "$APP/Contents/Resources/AppIcon.icns" "$DMGICON" >/dev/null

echo "▸ build DMG"
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$DMGICON" "$STAGE/.VolumeIcon.icns"
# Volume icon: .VolumeIcon.icns only shows once the volume ROOT carries the Finder custom-icon
# flag, and the flag can only be set on a WRITABLE volume — so build read-write first, set the
# flag on the mounted root, then compress to the read-only UDZO users download.
RWDMG="$BUILD/$APP_NAME-rw.dmg"
rm -f "$RWDMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW "$RWDMG" >/dev/null
MNT=$(hdiutil attach "$RWDMG" -nobrowse -readwrite | awk -F'\t' '/\/Volumes\//{print $3; exit}')
[ -d "$MNT" ] || { echo "✗ could not mount RW dmg"; exit 1; }
SetFile -a C "$MNT"
hdiutil detach "$MNT" >/dev/null
rm -f "$DMG"
hdiutil convert "$RWDMG" -format UDZO -o "$DMG" >/dev/null
rm -f "$RWDMG"; rm -rf "$STAGE"

if [ "$NOTARIZE" = "1" ]; then
  # Sign the DMG too so it verifies with a real signature (not just the stapled ticket),
  # then notarize + staple the DMG itself — the ticket must be attached to the .dmg the
  # user downloads, since quarantine lands on the DMG.
  SIGN_ID="${SIGN_ID:-Developer ID Application}"
  echo "▸ sign the .dmg"
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  echo "▸ notarize the .dmg (second upload)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▸ staple ticket to the .dmg"
  xcrun stapler staple "$DMG"
fi

# Give the .dmg FILE itself the composite icon too (nice locally / on AirDrop; note it rides in
# extended attributes, which a plain HTTP download strips — the VOLUME icon above is the one
# every user sees after mounting). After signing/stapling: xattrs aren't part of either.
swift -e 'import AppKit
let a = CommandLine.arguments
_ = NSWorkspace.shared.setIcon(NSImage(contentsOfFile: a[1]), forFile: a[2])' "$DMGICON" "$DMG" || true

echo ""
echo "✓ done"
echo "  app: $APP"
echo "  dmg: $DMG  ($(du -sh "$DMG" | cut -f1))"
if [ "$NOTARIZE" = "1" ]; then
  echo "  verify: spctl -a -vvv -t install \"$APP\"   (should say: source=Notarized Developer ID)"
fi
