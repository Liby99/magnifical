#!/bin/bash
# Record a tutorial GIF by driving the app in a scripted "demo mode" and screen-capturing a fixed rect.
#
#   ./scripts/record-tutorial.sh <scene> [seconds]
#   scenes: drag-create | pinch-zoom   (see DemoController.swift)
#
# The app runs against a THROWAWAY data dir with Apple Calendar import OFF, so it never touches your real
# calendar. Requires: ffmpeg (brew install ffmpeg), and Screen Recording permission for your terminal
# (System Settings ▸ Privacy & Security ▸ Screen Recording) — a one-time grant.
set -euo pipefail
cd "$(dirname "$0")/.."

SCENE="${1:-drag-create}"
DUR="${2:-8}"
# THEME=light|dark → records that appearance and suffixes the filename (tutorial dual-theme sets).
OUT="Sources/CalendarUI/Resources/tutorial/${SCENE}${THEME:+-$THEME}.gif"
TMP="$(mktemp -d /tmp/cc-demo.XXXXXX)"
BIN=".build/debug/CalendarMac"

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }

echo "Building CalendarMac (debug)…"
swift build -c debug >/dev/null

echo "Launching demo scene '$SCENE' (throwaway data at $TMP)…"
# `env` so the optional ${…:+VAR=val} expansion still parses as an environment assignment.
env CC_DEMO="$SCENE" CC_DEMO_DATADIR="$TMP" ${THEME:+CC_APPEARANCE="$THEME"} "$BIN" &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Wait for the app to position its window (rect.txt) + the scene's crop region (crop.txt).
for _ in $(seq 1 60); do [ -f "$TMP/rect.txt" ] && break; sleep 0.1; done
[ -f "$TMP/rect.txt" ] || { echo "app never reported its window rect"; exit 1; }
for _ in $(seq 1 30); do [ -f "$TMP/crop.txt" ] && break; sleep 0.1; done
read -r X Y W H < "$TMP/rect.txt"   # content area, screen points (top-left)

# The scene's crop is view-local (relative to the content top-left); offset it onto the screen. Same units
# (points), so a plain add works — screencapture then records only the region of interest.
if [ -f "$TMP/crop.txt" ]; then
  read -r CX CY CW CH < "$TMP/crop.txt"
  # Clamp the crop to the window content rect: the SwiftUI hosting view can overflow the window (its
  # reported size is taller than the content), so an unclamped full-height crop would capture desktop
  # below the window. Never record past the window's right/bottom edge.
  maxW=$((W - CX)); maxH=$((H - CY))
  [ "$CW" -gt "$maxW" ] && CW=$maxW
  [ "$CH" -gt "$maxH" ] && CH=$maxH
  X=$((X + CX)); Y=$((Y + CY)); W=$CW; H=$CH
fi
# Wait for the scene to finish its OFF-CAMERA setup (seeding + navigating to the starting view) and signal
# readiness, so setup animations (e.g. zooming into the week) never land in the GIF. Falls back after ~8s.
for _ in $(seq 1 80); do [ -f "$TMP/ready.txt" ] && break; sleep 0.1; done
sleep 0.2
echo "Recording rect ${W}x${H} at ($X,$Y) for ${DUR}s…"

# Handshake: tell the (now-ready) scene that recording has begun, so it starts the on-camera action exactly
# in sync with the first captured frame.
touch "$TMP/go.txt"
# screencapture -R captures just that region; -V caps the duration; blocks until done. It ignores signals
# and always records the FULL duration, so we over-record and trim below to the scene's real end.
/usr/sbin/screencapture -v -R"${X},${Y},${W},${H}" -V"${DUR}" "$TMP/raw.mov"

# The scene wrote its exact on-camera length to done.txt; trim the video to there (+ a hair) so the GIF ends
# right after the scene's final frame instead of holding whatever slack was left in DUR.
TRIM=""
if [ -f "$TMP/done.txt" ]; then
  read -r ELAPSED < "$TMP/done.txt"
  END=$(echo "$ELAPSED + 0.3" | bc)
  TRIM="-t $END"
  echo "Scene ended at ${ELAPSED}s → trimming GIF to ${END}s"
fi

echo "Encoding GIF → $OUT"
# FPS/SCALE/COLORS/DITHER overridable per scene (full-window scenes like pinch-zoom want lower values +
# fewer colors + no dither to stay small — the dark UI's dotted gridlines otherwise blow up the GIF).
FPS="${FPS:-15}"; SCALE="${SCALE:-1000}"; COLORS="${COLORS:-256}"; DITHER="${DITHER:-bayer}"
ffmpeg -y -loglevel error -i "$TMP/raw.mov" $TRIM \
  -vf "fps=${FPS},scale=${SCALE}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=${COLORS}:stats_mode=diff[p];[s1][p]paletteuse=dither=${DITHER}" \
  "$OUT"

# Lossy compression pass (the "jpeg-like" step): gifsicle re-quantizes similar pixels and optimizes frame
# deltas, shrinking each frame substantially with little visible loss. LOSSY overridable (higher = smaller).
if command -v gifsicle >/dev/null; then
  before=$(du -h "$OUT" | cut -f1)
  gifsicle -O3 --lossy="${LOSSY:-24}" -o "$OUT" "$OUT"
  echo "Compressed ${before} → $(du -h "$OUT" | cut -f1) (gifsicle --lossy=${LOSSY:-24})"
fi

echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
