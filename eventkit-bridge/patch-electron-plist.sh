#!/usr/bin/env bash
# DEV-ONLY probe helper: add the Calendar usage strings to the prebuilt Electron.app in node_modules
# and re-sign it ad-hoc, so we can test whether a child bridge inherits Electron's Calendar grant
# when Electron (the responsible process) declares the usage string. A real packaged build sets
# these via electron-builder's `extendInfo` — this just simulates that for the throwaway probe.
#
# Safe to run: it only touches node_modules (reinstallable). Re-run `npm ci`/`npm rebuild` to revert.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

APP="node_modules/electron/dist/Electron.app"
PLIST="$APP/Contents/Info.plist"
[ -d "$APP" ] || { echo "Electron.app not found at $APP — is electron installed?"; exit 1; }

MSG="libirabu reads your calendars to import events."
set_key() {
  /usr/libexec/PlistBuddy -c "Add :$1 string $MSG" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :$1 $MSG" "$PLIST"
}
set_key NSCalendarsUsageDescription
set_key NSCalendarsFullAccessUsageDescription

echo "re-signing $APP (ad-hoc, --deep)…"
codesign --force --deep --sign - "$APP"

echo "done. Now: tccutil reset Calendar ; npm run electron:validate"
