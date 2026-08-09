#!/usr/bin/env node
// Migrate the daily-dashboard NOTE-tab notes from the web app's Postgres DB into the native
// CalendarKit store (data.json → `dailyNotes` map, keyed by ISO date).
//
// Usage (from the repo root, with the web DB running — `npm run db:up`, and the native app CLOSED
// so it doesn't overwrite the file on its next persist):
//   node native/scripts/migrate-daily-notes.mjs
//
// It reads DATABASE_URL from .env, dumps the "DailyNote" table, backs up data.json → data.json.bak,
// then merges: existing native notes are kept; DB notes fill in / overwrite by date. Non-destructive
// to events/bands/deadlines/rich — only the `dailyNotes` field is touched.

import { readFileSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import pg from "pg";

const repoRoot = join(import.meta.dirname, "..", "..");
const storePath = join(homedir(), "Library", "Application Support", "CalendarKit", "data.json");

function databaseUrl() {
  if (process.env.DATABASE_URL) return process.env.DATABASE_URL;
  const env = readFileSync(join(repoRoot, ".env"), "utf8");
  const m = env.match(/^\s*DATABASE_URL\s*=\s*["']?([^"'\n]+)["']?/m);
  if (!m) throw new Error("DATABASE_URL not found (set it or add to .env)");
  return m[1];
}

async function fetchDailyNotes() {
  const client = new pg.Client({ connectionString: databaseUrl() });
  await client.connect();
  try {
    // Prisma model `DailyNote` → same-cased Postgres table (quote to preserve case).
    const { rows } = await client.query('SELECT "userId", "date", "notes" FROM "DailyNote"');
    return rows;
  } finally {
    await client.end();
  }
}

async function main() {
  if (!existsSync(storePath)) {
    console.error(`No native store at:\n  ${storePath}\nLaunch the native app once so it writes data.json, then re-run.`);
    process.exit(1);
  }
  const rows = await fetchDailyNotes();
  const users = new Set(rows.map((r) => r.userId));
  if (users.size > 1) console.warn(`⚠︎ ${users.size} users in DailyNote; merging ALL of them: ${[...users].join(", ")}`);

  const store = JSON.parse(readFileSync(storePath, "utf8"));
  const notes = store.dailyNotes ?? {};
  let added = 0, updated = 0;
  for (const { date, notes: text } of rows) {
    if (typeof text !== "string" || text.trim() === "") continue;
    if (notes[date] === text) continue;
    if (notes[date] === undefined) added++; else updated++;
    notes[date] = text;
  }
  store.dailyNotes = notes;

  copyFileSync(storePath, storePath + ".bak");
  writeFileSync(storePath, JSON.stringify(store), "utf8");
  console.log(`✓ Migrated ${rows.length} DB note(s) → ${added} added, ${updated} updated, ${Object.keys(notes).length} total.`);
  console.log(`  Backup: ${storePath}.bak`);
  console.log(`  Restart the native app to load them.`);
}

main().catch((e) => { console.error("Migration failed:", e.message); process.exit(1); });
