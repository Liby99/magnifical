#!/bin/bash
# Bundle the notes editor into the CalendarUI resources (loaded by the drawer's WKWebView).
# Resolves @codemirror/*, remark-*, katex from the repo-root node_modules (walked up from here),
# and rehype-stringify from webeditor/node_modules. Run: ./build.sh
set -e
cd "$(dirname "$0")"
OUT=../Sources/CalendarUI/Resources/editor

# (dashboard.ts was retired to legacy/webeditor in phase 4a — the dashboard is native Swift now.)
echo "› bundling editor.js …"
npx --yes esbuild editor.ts \
  --bundle --format=iife --platform=browser --target=safari17 \
  --loader:.ts=ts \
  --outfile="$OUT/editor.js" \
  --log-level=warning

echo "› copying html/css + KaTeX assets …"
cp editor.html editor.css "$OUT/"
# KaTeX stylesheet + its fonts (css references ./fonts/*)
cp ../../../node_modules/katex/dist/katex.min.css "$OUT/"
rm -rf "$OUT/fonts" && cp -R ../../../node_modules/katex/dist/fonts "$OUT/fonts"

echo "✓ built → $OUT"
ls -1 "$OUT"
