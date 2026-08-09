#!/bin/bash
# Build CalendarMac and wrap it in a minimal .app bundle, then launch it.
#
# A bare SwiftPM executable isn't a macOS .app bundle, so LaunchServices won't
# treat it as a GUI app and the window may never appear. Wrapping it in a bundle
# (Info.plist + Contents/MacOS/) fixes that — no Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP=".build/CalendarMac.app"

echo "Building ($CONFIG)..."
swift build -c "$CONFIG" >/dev/null
BIN=".build/$CONFIG/CalendarMac"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CalendarMac"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MagnifiCal</string>
  <key>CFBundleDisplayName</key><string>MagnifiCal</string>
  <key>CFBundleExecutable</key><string>CalendarMac</string>
  <key>CFBundleIdentifier</key><string>dev.magnifical.calendar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Calendar reads your Apple Calendar events so it can show them alongside your libirabu calendar.</string>
  <key>NSCalendarsUsageDescription</key><string>Calendar reads your Apple Calendar events so it can show them alongside your libirabu calendar.</string>
</dict>
</plist>
PLIST

# Sign the bundle. The notification daemon (usernoted) refuses to register an UNSIGNED bundle —
# UNUserNotificationCenter errors with a "needs code signature" complaint. Prefer a real Apple
# Development identity: its signature is STABLE across rebuilds, so the user's one-time
# notification permission sticks. Ad-hoc fallback works too, but every rebuild changes the
# ad-hoc identity and macOS may treat it as a new app (permission re-prompt).
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development/ {print $2; exit}')
echo "Signing (${IDENTITY:-ad-hoc})..."
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "Launching..."
# `open` on a RUNNING app just activates the old instance — the fresh binary would never start.
pkill -x CalendarMac 2>/dev/null && sleep 1 || true
open "$APP"
echo "Done. (Relaunch anytime: open $PWD/$APP)"
