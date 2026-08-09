#!/bin/bash
# The canonical perf suite for comparing optimization branches against the baseline.
# Run from any worktree; results are tagged with that worktree's branch in bench/results.log.
#
#   ./scripts/bench-suite.sh            # 3× rapid month-swipe + 1× year-fling, heavy dump payload
#   REPS=5 ./scripts/bench-suite.sh     # more repetitions of the swipe scene
#
# Scenes (identical knobs every time — do not vary between branches):
#   month-swipe: MONTHS=5,6,7 SWIPE_STEPS=10 SWIPE_GAP=0.02  (the reproduced ~80fps real-world case)
#   year-fling:  HOVER=1                                     (year-view scroll regression guard)
# Payload: ~/.magical-bench/data.json (CC_DUMP_DISPLAY export of the real store: 1007 ev / 157 bands).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f "$HOME/.magical-bench/data.json" ] || { echo "missing ~/.magical-bench/data.json — run scripts/bench-app-setup.sh or CC_DUMP_DISPLAY first"; exit 1; }

REPS="${REPS:-3}"
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
echo "=== bench-suite on branch: $BRANCH (REPS=$REPS) ==="
for i in $(seq 1 "$REPS"); do
  echo "--- month-swipe $i/$REPS ---"
  CONFIG=release SCENE=bench-month-swipe PAYLOAD=dump PROF=1 MONTHS=5,6,7 SWIPE_STEPS=10 SWIPE_GAP=0.02 \
    ./scripts/bench-year.sh | grep -E "^20|hitch offsets"
done
echo "--- year-fling ---"
CONFIG=release SCENE=bench-year-fling PAYLOAD=dump PROF=1 HOVER=1 ./scripts/bench-year.sh | grep -E "^20"
echo ""
echo "=== last suite lines for '$BRANCH' (bench/results.log) ==="
grep -F "[$BRANCH|" bench/results.log | tail -8
# Environment sanity gate: p50 should be 8.33 ms (120 Hz cadence). A run at p50 16.67 means the
# display cadence was halved (machine busy / window occluded / power state) — numbers from that
# run are NOT comparable to a clean baseline. Warn loudly rather than silently logging junk.
BAD=$(grep -F "[$BRANCH|" bench/results.log | tail -$((REPS + 1)) | grep -cv "p50 8.33" || true)
if [ "$BAD" -gt 0 ]; then
  echo ""
  echo "⚠️  $BAD of the last $((REPS + 1)) runs have p50 ≠ 8.33 ms — degraded environment (60 Hz cadence?)."
  echo "    Close heavy apps / keep the bench window frontmost and RERUN before comparing branches."
fi
