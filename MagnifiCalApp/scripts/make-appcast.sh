#!/bin/bash
# Generate (or update) Sparkle's appcast.xml for a directory of release DMGs.
#
#   scripts/make-appcast.sh [updates-dir]     # default: build/updates
#
# Workflow per release (see DISTRIBUTE.md):
#   1. Put the new notarized MagnifiCal-X.Y.Z.dmg into build/updates/ (keep the older
#      DMGs there too — the appcast lists every version it can see, which lets Sparkle
#      offer delta-free upgrades from any older install).
#   2. Run this script. It signs each entry with the EdDSA PRIVATE key that
#      `generate_keys` stored in your login Keychain (one-time setup — DISTRIBUTE.md).
#   3. Upload BOTH the new DMG and the regenerated appcast.xml as assets of the GitHub
#      release. The app's feed URL is .../releases/latest/download/appcast.xml, so the
#      newest release's copy is always the one served.
#
# `generate_appcast` ships with Sparkle itself. This script finds it in the Xcode SPM
# artifacts (present once the app has been built with the Sparkle dependency), or uses
# $SPARKLE_BIN, or PATH.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)" # MagnifiCalApp/
UPDATES="${1:-$HERE/build/updates}"

if [ ! -d "$UPDATES" ] || ! ls "$UPDATES"/*.dmg >/dev/null 2>&1; then
    echo "error: no DMGs in $UPDATES — put the notarized release DMG(s) there first" >&2
    exit 1
fi

find_generate_appcast() {
    if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ]; then
        echo "$SPARKLE_BIN/generate_appcast"; return
    fi
    if command -v generate_appcast >/dev/null 2>&1; then
        command -v generate_appcast; return
    fi
    # Xcode's SPM checkout ships Sparkle's tools as an artifact bundle.
    find ~/Library/Developer/Xcode/DerivedData -type f -name generate_appcast -perm +111 2>/dev/null \
        | head -1
}

GEN="$(find_generate_appcast)"
if [ -z "$GEN" ]; then
    echo "error: generate_appcast not found. Build the app once in Xcode (so SPM fetches" >&2
    echo "       Sparkle), or download Sparkle from github.com/sparkle-project/Sparkle" >&2
    echo "       and point SPARKLE_BIN at its bin/ directory." >&2
    exit 1
fi

echo "→ $GEN $UPDATES"
"$GEN" "$UPDATES"
echo
echo "Wrote $UPDATES/appcast.xml"
echo "Upload the new DMG AND appcast.xml as assets of the GitHub release."
