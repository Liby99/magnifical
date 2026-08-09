#!/bin/bash
# Stage the "manual benchmark" data dir for the Xcode CalendarApp (MagnifiCal), then print the exact
# environment variables to paste into its Run scheme. This lets you A/B the SIGNED Xcode app against
# the CalendarMac harness by hand: same fixture data (145 bands · 487 events), and EVERYTHING else off —
# no iCloud sync, no ICS feeds, no Apple-Calendar import, no notifications, no now-timer (all gated by
# isDemoMode, which CC_DEMO=idle turns on) — with a live FPS HUD.
#
#   ./scripts/bench-app-setup.sh            # stage the default display fixture
#   PAYLOAD=full ./scripts/bench-app-setup.sh   # copy your REAL live store instead (max realism)
#
# If MagnifiCal is smooth in this mode but janky normally, the cost is the background work, not rendering.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="${DIR:-$HOME/.magical-bench}"
mkdir -p "$DIR"
case "${PAYLOAD:-display}" in
  display) cp bench/year-display-2026.json "$DIR/data.json" ;;
  bands)   cp bench/year-bands-2026.json  "$DIR/data.json" ;;
  full)    cp "$HOME/Library/Application Support/CalendarKit/data.json" "$DIR/data.json" ;;
  *) echo "unknown PAYLOAD=${PAYLOAD}"; exit 1 ;;
esac
# A clean throwaway root: drop any stale sync/registry state a previous run left behind.
rm -f "$DIR"/syncState.bin "$DIR"/records.plist "$DIR"/registry.json 2>/dev/null || true

echo "Staged $(python3 -c "import json;d=json.load(open('$DIR/data.json'));print(len(d.get('bands',[])),'bands /',len(d.get('events',[])),'events')")"
echo ""
echo "Add these to the CalendarApp Run scheme (Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments ▸ Environment Variables),"
echo "run it, open Year view, and read the HUD in the top-left:"
echo ""
echo "    CC_DEMO           idle"
echo "    CC_DEMO_DATADIR   $DIR"
echo "    CC_FPS_HUD        1"
echo ""
echo "Optional — measure the GLASS path (Performance Mode forced off): CC_PERF_OFF  1"
echo "Optional — per-layer signposts in Instruments (Points of Interest): CC_PROF  1"
