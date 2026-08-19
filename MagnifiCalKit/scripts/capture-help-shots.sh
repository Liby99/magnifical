#!/bin/bash
# Capture STILL help screenshots (the Help browser's .image blocks) from scripted demo scenes —
# record-tutorial.sh's pipeline minus the movie: the scene seeds off-camera, settles on its final
# state, signals ready, and we grab ONE frame of its crop region with screencapture -R.
#
#   ./scripts/capture-help-shots.sh [scene ...]     # default: proj-gantt todo-panel note-preview
#   scenes: proj-gantt | todo-panel | note-preview  (see DemoController+HelpGIFs.sceneHelpShot)
#
# Each scene is captured in BOTH themes — <scene>-light.png / <scene>-dark.png in media/help/
# (help-only assets: committed + exported to the public repo, fetched at runtime, NOT bundled) —
# matching the demos' theme-pair convention (HelpView's HelpStill picks the variant). pngquant
# (if installed) crushes each capture ~60-70% losslessly-enough for flat UI.
# The app runs against a THROWAWAY data dir (never your real calendar). Requires Screen Recording
# permission for your terminal (the same one-time grant record-tutorial.sh needs); no ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."

SCENES=("$@")
[ ${#SCENES[@]} -eq 0 ] && SCENES=(proj-gantt todo-panel note-preview)
BIN=".build/debug/CalendarMac"

echo "Building CalendarMac (debug)…"
swift build -c debug >/dev/null

mkdir -p media/help
for SCENE in "${SCENES[@]}"; do
  for THEME in light dark; do
    OUT="media/help/${SCENE}-${THEME}.png"
    TMP="$(mktemp -d /tmp/cc-shot.XXXXXX)"
    echo "Staging '$SCENE' ($THEME) — throwaway data at ${TMP}…"
    env CC_DEMO="$SCENE" CC_DEMO_DATADIR="$TMP" CC_APPEARANCE="$THEME" "$BIN" &
    APP_PID=$!
    # shellcheck disable=SC2064  # expand now: the loop reuses these vars next iteration
    trap "kill $APP_PID 2>/dev/null || true; rm -rf '$TMP'" EXIT

    # rect.txt (window content rect) arrives at launch; ready.txt once the scene has seeded,
    # opened the panel, and written its crop — stills need no early-start race, so just wait
    # for ready (generous: the seed + panel mount takes a few seconds).
    for _ in $(seq 1 100); do [ -f "$TMP/rect.txt" ] && break; sleep 0.1; done
    [ -f "$TMP/rect.txt" ] || { echo "app never reported its window rect"; exit 1; }
    for _ in $(seq 1 150); do [ -f "$TMP/ready.txt" ] && break; sleep 0.1; done
    [ -f "$TMP/ready.txt" ] || { echo "scene never signalled ready"; exit 1; }

    read -r X Y W H < "$TMP/rect.txt" # content area, screen points (top-left)
    # The scene's crop is view-local; offset onto the screen and clamp inside the content rect
    # (the SwiftUI hosting view can overflow the window — record-tutorial.sh's clamp).
    if [ -f "$TMP/crop.txt" ]; then
      read -r CX CY CW CH < "$TMP/crop.txt"
      maxW=$((W - CX)); maxH=$((H - CY))
      [ "$CW" -gt "$maxW" ] && CW=$maxW
      [ "$CH" -gt "$maxH" ] && CH=$maxH
      X=$((X + CX)); Y=$((Y + CY)); W=$CW; H=$CH
    fi

    # Handshake, then one settled beat and the single-frame grab (-x: no sound).
    touch "$TMP/go.txt"
    sleep 1.0
    /usr/sbin/screencapture -x -R"${X},${Y},${W},${H}" "$OUT"
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    trap - EXIT
    rm -rf "$TMP"
    [ -s "$OUT" ] || { echo "capture FAILED: $OUT is empty"; exit 1; }
    if command -v pngquant >/dev/null; then
      before=$(du -h "$OUT" | cut -f1)
      pngquant --force --skip-if-larger --quality 70-95 --output "$OUT" "$OUT" || true
      echo "pngquant: ${before} → $(du -h "$OUT" | cut -f1)"
    fi
    echo "Captured $OUT ($(sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null \
      | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h" px"}'), $(du -h "$OUT" | cut -f1))"
  done
done
