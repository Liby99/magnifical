#!/usr/bin/env bash
# Regenerate the app icon EVERYWHERE from make-icon.swift — the single command to run after any
# icon design change, so no consumer is left with a stale copy:
#   • Assets.xcassets/AppIcon.appiconset  (1024 master + all sips downscales — the app's icon)
#   • CalendarKit .../Resources/tutorial/app-icon.png  (the tutorial welcome slide's FALLBACK —
#     used only by the unsigned dev shell; the signed app shows its live icon at runtime)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$(cd "$HERE/.." && pwd)"
ICONSET="$APPDIR/Assets.xcassets/AppIcon.appiconset"
TUTORIAL="$APPDIR/../MagnifiCalKit/Sources/CalendarUI/Resources/tutorial/app-icon.png"

echo "▸ render 1024 master"
swift "$HERE/make-icon.swift" "$ICONSET/icon_1024.png"

echo "▸ render iOS full-bleed 1024 (no margin/rounding — iOS masks corners itself)"
swift "$HERE/make-icon.swift" "$ICONSET/icon_ios_1024.png" --ios

echo "▸ downscale iconset sizes"
for s in 512 256 128 64 32 16; do
  sips -z $s $s "$ICONSET/icon_1024.png" --out "$ICONSET/icon_$s.png" >/dev/null
done

echo "▸ refresh tutorial welcome-slide fallback"
cp "$ICONSET/icon_512.png" "$TUTORIAL"

echo "✓ iconset + tutorial app-icon.png refreshed"
