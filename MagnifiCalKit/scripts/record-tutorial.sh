#!/bin/bash
# Record a tutorial/help demo by driving the app in a scripted "demo mode" and screen-capturing a
# fixed rect. The canonical output is a looping H.264 .mp4 (5–10× smaller than the old GIFs; the
# app plays them with LoopingVideo — see HelpMedia.swift). GIF=1 additionally emits the legacy GIF.
#
#   ./scripts/record-tutorial.sh <scene> [seconds]
#   scenes: see DemoController.swift (sceneXxx). [seconds] only needs to be ≥ the scene's real
#   length — the capture is trimmed to the scene's done.txt stamp.
#
# Output location routes by scene: the Welcome-carousel slides (TutorialView.slides) are BUNDLED →
# Sources/CalendarUI/Resources/tutorial/; every other demo is help-only and fetched from GitHub at
# runtime → media/help/ (committed, exported to the public repo, NOT bundled).
#
# The app runs against a THROWAWAY data dir with Apple Calendar import OFF, so it never touches your real
# calendar. Requires: ffmpeg (brew install ffmpeg), and Screen Recording permission for your terminal
# (System Settings ▸ Privacy & Security ▸ Screen Recording) — a one-time grant.
set -euo pipefail
cd "$(dirname "$0")/.."

SCENE="${1:-drag-create}"
DUR="${2:-8}"
# THEME=light|dark → records that appearance and suffixes the filename (tutorial dual-theme sets).
# Keep this list in sync with TutorialView.slides — those six ship in the app bundle.
case "$SCENE" in
  pinch-zoom|band-year|timed-week|ai-assistant|markdown-notes|dashboard-tour)
    OUTDIR="Sources/CalendarUI/Resources/tutorial" ;;
  *)
    OUTDIR="media/help"; mkdir -p "$OUTDIR" ;;
esac
OUT="$OUTDIR/${SCENE}${THEME:+-$THEME}.mp4"
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

# The scene wrote its exact on-camera length to done.txt; trim the video to there (+ a hair) so the clip
# ends right after the scene's final frame instead of holding whatever slack was left in DUR.
TRIM=""
if [ -f "$TMP/done.txt" ]; then
  read -r ELAPSED < "$TMP/done.txt"
  END=$(echo "$ELAPSED + 0.3" | bc)
  TRIM="-t $END"
  echo "Scene ended at ${ELAPSED}s → trimming to ${END}s"
fi

# ── mp4 (canonical): H.264 CRF-quality, no audio, faststart for instant remote playback ─────────
# FPS/SCALE/CRF overridable per scene; even dimensions forced (yuv420p requires them).
FPS="${FPS:-24}"; SCALE="${SCALE:-1000}"; CRF="${CRF:-23}"
echo "Encoding mp4 → $OUT"
ffmpeg -y -loglevel error -i "$TMP/raw.mov" $TRIM \
  -vf "fps=${FPS},scale=trunc(${SCALE}/2)*2:-2:flags=lanczos" \
  -c:v libx264 -crf "$CRF" -preset slow -pix_fmt yuv420p -movflags +faststart -an \
  "$OUT"
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"

# ── GIF (GIF=1 only — the public README embeds a few demos, and GitHub can't inline-play repo
# mp4s; these land in media/readme/, never the app bundle) ───────────────────────────────────────
if [ "${GIF:-0}" = "1" ]; then
  mkdir -p media/readme
  GOUT="media/readme/$(basename "${OUT%.mp4}").gif"
  COLORS="${COLORS:-256}"; DITHER="${DITHER:-bayer}"; GFPS="${GFPS:-15}"
  echo "Encoding GIF → $GOUT"
  ffmpeg -y -loglevel error -i "$TMP/raw.mov" $TRIM \
    -vf "fps=${GFPS},scale=${SCALE}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=${COLORS}:stats_mode=diff[p];[s1][p]paletteuse=dither=${DITHER}" \
    "$GOUT"
  if command -v gifsicle >/dev/null; then
    before=$(du -h "$GOUT" | cut -f1)
    gifsicle -O3 --lossy="${LOSSY:-24}" -o "$GOUT" "$GOUT"
    echo "Compressed ${before} → $(du -h "$GOUT" | cut -f1) (gifsicle --lossy=${LOSSY:-24})"
  fi
fi
