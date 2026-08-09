#!/usr/bin/env bash
# Build EventKitBridge.app — a proper signed .app bundle so macOS attributes the Calendar (TCC)
# request to THIS app's own identity (com.libirabu.eventkit-bridge) and shows the permission prompt,
# instead of attributing it to the terminal (docs/calendar-import-design.md §5.2).
#
# A loose CLI binary inherits the terminal's TCC identity — which may already be write-only/denied,
# so it never prompts. A bundled, code-signed app gets its own fresh TCC state → prompt appears and
# it shows in System Settings › Privacy & Security › Calendars.
#
# Ad-hoc signing (default) works but the grant is keyed to the code hash, so it resets on each
# rebuild. For a grant that STICKS across rebuilds, sign with your Developer ID:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="EventKitBridge.app"
BIN="eventkit-bridge"
IDENTITY="${CODESIGN_IDENTITY:--}"   # "-" = ad-hoc

echo "compiling..."
swiftc -O main.swift -o "$BIN"

echo "assembling ${APP}..."
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
cp Info.plist "${APP}/Contents/Info.plist"
cp "$BIN" "${APP}/Contents/MacOS/${BIN}"

echo "signing (identity: ${IDENTITY})..."
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --identifier com.libirabu.eventkit-bridge "$APP"
else
  # Developer ID → enable the hardened runtime for a durable, notarizable identity.
  codesign --force --options runtime --sign "$IDENTITY" --identifier com.libirabu.eventkit-bridge "$APP"
fi

echo ""
echo "built: $(pwd)/$APP/Contents/MacOS/$BIN"
echo "test:  ./$APP/Contents/MacOS/$BIN list-calendars"
