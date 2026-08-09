#!/usr/bin/env bash
# Build the EventKit bridge (docs/calendar-import-design.md §5). Output binary sits next to this
# script; the server invokes it by that path. The Electron build bundles the binary + the Calendars
# entitlement (NSCalendarsUsageDescription) so the packaged app owns the permission.
set -euo pipefail
cd "$(dirname "$0")"
# Embed Info.plist (NSCalendars*UsageDescription) into the binary's __TEXT,__info_plist section so
# macOS will show the Calendars permission prompt for this CLI (required on macOS 14+).
swiftc -O main.swift -o eventkit-bridge \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
# Ad-hoc code signature (stabilizes the TCC identity so the grant sticks across rebuilds is best-effort).
codesign --force --sign - eventkit-bridge 2>/dev/null || true
echo "built: $(pwd)/eventkit-bridge"
