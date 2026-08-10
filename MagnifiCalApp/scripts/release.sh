#!/usr/bin/env bash
# One-command release of the DIRECT (Developer-ID) build:
#
#   preflight → package.sh (archive → notarize → DMG) → pull prior release DMGs →
#   make-appcast.sh (EdDSA-signed) → GitHub release with DMG + appcast.xml
#
# The version comes from project.yml (MARKETING_VERSION). Do the bump FIRST — that's
# deliberately manual (see DISTRIBUTE.md "Versioning & changelog"): retitle [Unreleased]
# in native/CHANGELOG.md, bump MARKETING_VERSION *and* CURRENT_PROJECT_VERSION (Sparkle
# compares CFBundleVersion), commit. Then:
#
#   native/MagnifiCalApp/scripts/release.sh          # full release, published
#   DRY_RUN=1 …/release.sh                           # everything except the GitHub upload
#   NOTARIZE=0 …/release.sh                          # forwarded to package.sh; refuses to
#                                                    # publish (smoke tests never ship)
#
# Release notes are auto-extracted from the CHANGELOG section for this version (falling
# back to [Unreleased]); the release stays editable afterward (gh release edit).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PROJ_DIR/../.." && pwd)"
REPO="${REPO:-Liby99/magnifical}"
cd "$PROJ_DIR"

VERSION="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)".*/\1/p' project.yml | head -1)"
BUILDNUM="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)".*/\1/p' project.yml | head -1)"
TAG="v$VERSION"
DMG_NAME="MagnifiCal-$VERSION.dmg"

echo "▸ releasing MagnifiCal $VERSION (build $BUILDNUM) → $REPO $TAG"

# ── Preflight ──────────────────────────────────────────────────────────────────────
command -v gh >/dev/null || { echo "✗ gh CLI not installed (brew install gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh not authenticated (gh auth login)"; exit 1; }
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "✗ release $TAG already exists on $REPO — bump MARKETING_VERSION first"; exit 1
fi
KEY="$(plutil -extract SUPublicEDKey raw Info-macOS.plist 2>/dev/null || true)"
if [ "$(printf %s "$KEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" != "32" ]; then
    echo "✗ Info-macOS.plist SUPublicEDKey isn't a real EdDSA key — run Sparkle's generate_keys"
    echo "  (DISTRIBUTE.md ▸ Sparkle auto-updates, one-time setup)"; exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "⚠ monorepo has uncommitted changes — the release builds from the working tree"
fi
if [ "${NOTARIZE:-1}" = "0" ] && [ "${DRY_RUN:-0}" != "1" ]; then
    echo "✗ NOTARIZE=0 builds are smoke tests — refusing to publish (use DRY_RUN=1)"; exit 1
fi

# ── Build (package.sh wipes build/, so the updates dir is assembled after) ─────────
"$HERE/package.sh"
[ -f "$PROJ_DIR/build/MagnifiCal.dmg" ] || { echo "✗ package.sh produced no DMG"; exit 1; }

UPDATES="$PROJ_DIR/build/updates"
mkdir -p "$UPDATES"
cp "$PROJ_DIR/build/MagnifiCal.dmg" "$UPDATES/$DMG_NAME"

echo "▸ pull previously released DMGs (the appcast lists every version)"
gh release list -R "$REPO" --json tagName -q '.[].tagName' 2>/dev/null | while read -r t; do
    [ -n "$t" ] && gh release download "$t" -R "$REPO" --pattern '*.dmg' \
        --dir "$UPDATES" --skip-existing 2>/dev/null || true
done

echo "▸ generate the signed appcast"
"$HERE/make-appcast.sh" "$UPDATES"

# ── Release notes from the CHANGELOG ───────────────────────────────────────────────
NOTES="$PROJ_DIR/build/RELEASE_NOTES.md"
awk -v ver="$VERSION" '
    /^## \[/ { on = index($0, "[" ver "]") > 0; if (on) next }
    on && /^## / { on = 0 }
    on { print }
' "$ROOT/native/CHANGELOG.md" > "$NOTES"
if [ ! -s "$NOTES" ]; then
    echo "⚠ no \"## [$VERSION]\" section in CHANGELOG.md — using [Unreleased]"
    awk '/^## \[Unreleased\]/{on=1; next} on && /^## /{on=0} on{print}' \
        "$ROOT/native/CHANGELOG.md" > "$NOTES"
fi
printf '\n---\nInstalls update themselves (Sparkle). First install: download the DMG below.\n' >> "$NOTES"

if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "✓ DRY RUN — would publish $TAG with:"
    echo "    $UPDATES/$DMG_NAME"
    echo "    $UPDATES/appcast.xml"
    sed 's/^/    │ /' "$NOTES"
    exit 0
fi

echo "▸ publish $TAG on $REPO"
gh release create "$TAG" -R "$REPO" \
    --title "MagnifiCal $VERSION" \
    --notes-file "$NOTES" \
    "$UPDATES/$DMG_NAME" "$UPDATES/appcast.xml"

echo "▸ verify the Sparkle feed"
sleep 3
code="$(curl -s -o /dev/null -w '%{http_code}' -L \
    "https://github.com/$REPO/releases/latest/download/appcast.xml")"
echo "  feed HTTP $code (200 = live)"

echo ""
echo "✓ MagnifiCal $VERSION released: https://github.com/$REPO/releases/tag/$TAG"
echo "  next cycle: retitle [Unreleased] in CHANGELOG, bump MARKETING_VERSION"
echo "  AND CURRENT_PROJECT_VERSION in project.yml"
