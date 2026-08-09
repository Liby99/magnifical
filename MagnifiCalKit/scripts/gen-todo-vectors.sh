#!/bin/bash
# Regenerate the TodoIndex golden vectors from the legacy web tokenizer (todos.ts).
# Output: Tests/CalendarEngineTests/Fixtures/todo-vectors.json (committed).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Tests/CalendarEngineTests/Fixtures
mkdir -p "$OUT"
TMP=$(mktemp -d /tmp/todo-vectors.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
(cd webeditor && npx --yes esbuild ../scripts/todo-vector-driver.ts \
  --bundle --format=esm --platform=node --outfile="$TMP/driver.mjs" --log-level=warning)
node "$TMP/driver.mjs" > "$OUT/todo-vectors.json"
echo "✓ wrote $OUT/todo-vectors.json ($(wc -c < "$OUT/todo-vectors.json") bytes)"
