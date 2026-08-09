# Calendar Import — Design Document

Status: **Draft v0.2** · Last updated: 2026-06-29

> Pull events into the libirabu calendar from external sources — primarily the **local macOS Apple
> Calendar** (read via an EventKit helper; it already aggregates iCloud, Google, and shared calendars
> in one place), plus **emailed `.ics` attachments** — tagging each with its provenance,
> de-duplicating against what's already there, and merging notes rather than clobbering. libirabu
> is the user's single driving calendar; imports are **one-way (read-only pull)** in v1. Every
> import lands only through a **preview/review** step — nothing is written silently. An LLM (via the
> existing `getLLM()` layer) advises on ambiguous duplicate matches; the human always decides.
>
> **v0.2 change:** Apple Calendar (EventKit) replaces direct Google OAuth as the *primary* source —
> the Mac's Calendar.app already subscribes the user's Google + iCloud + shared calendars, so one
> local bridge covers them all. Direct Google OAuth moves to the Later tier (§10).

---

## 1. Goals

1. **Pull from external sources.** Import events from the local **Apple Calendar** (all calendars it
   aggregates) and from `.ics` files received by email.
2. **Provenance tagging.** Every imported event records where it came from — the source app, the
   underlying account/EKSource, and the calendar name — so it's visibly "imported from X".
3. **De-duplication.** Detect when an incoming event already exists in libirabu. Trust an exact
   **iCalUID** match enough to merge automatically; for everything else, **ask the user**.
4. **Note merging.** When merging a duplicate, keep the user's notes as the source of truth and
   **append** the imported description — never overwrite.
5. **Always-preview.** Imports are staged and reviewed (new / duplicate / changed) before any write.
6. **AI-assisted decisions.** For ambiguous (non-UID) match candidates, an LLM suggests "same event"
   vs "keep both" with a reason; it advises only — it never auto-applies an uncertain merge.
7. **Imported events are partially immutable.** Title and time are **locked to the source** (edit at
   the vendor). Vendor details (attendees & RSVP, location, meeting link, description) are rendered
   by a dedicated algorithm into a **provenance-marked managed block** inside the note, which re-sync
   can replace in place — while the user's own additions (tags, color, extra TODOs, promote-to-band,
   per-occurrence notes) live *outside* the block and always survive (§7).
8. **Visible provenance + source link.** Imported events carry a small corner badge (sibling to the
   AI/recurrence/promoted badges) and a click-through **link to the original vendor event** so the
   user can open and edit it at the source.
9. **A "Connectivity" top-bar menu.** Manage accounts/calendars, run a sync on demand, see when each
   was last synced, and import a `.ics` file — all from one place.

## 2. Non-goals (v1)

- **One-way only.** No write-back to Apple Calendar / vendors (no two-way sync). The schema records
  enough (`source`, `externalUid`, `externalId`) that two-way *could* be added later without a
  migration rewrite, but no write path to sources exists in v1.
- **No direct Google OAuth in v1.** Deferred to Later (§10) — Apple Calendar already aggregates the
  user's Google calendars, so OAuth is redundant for now. (Kept in the design so it can be added as a
  peer source later, e.g. for headless server-side sync.)
- **No Gmail auto-scan in v1.** `.ics` arrives by manual upload (drag/drop/paste).
- **Mac-dependent.** The Apple Calendar bridge needs the user's Mac (and the Calendars permission) —
  acceptable for a local/Electron single-user app. Headless sync is the Google/CalDAV Later story.
- **No assistant tool yet.** An `import_events` tool over this same pipeline is a natural later add;
  v1 is the bridge + UI + API + pipeline.

---

## 3. Architecture at a glance

Both sources funnel into **one** normalize → diff → preview → commit pipeline. The source differs
only at the "fetch raw events" step; everything downstream is shared.

```
┌── sources ──────────────────┐
│  Apple Calendar (EventKit)  │  Swift helper → JSON ─┐
│  via native bridge          │  (eventkit-bridge)    │
│                             │                       ▼
│  .ics upload                │── raw VEVENTs ──► normalize() ──► NormalizedEvent[]
│                             │   (ical.ts)        (normalize.ts)         │
│  [Later: Google API,        │                                          │
│   CalDAV — peer sources]    │                                          ▼
└─────────────────────────────┘            diff() vs DB CalendarItems  (diff.ts)
                                                 │ tier-1 UID match  → auto-merge
                                                 │ tier-2 fuzzy match → AI suggest (getLLM)
                                                 │ tier-3 no match    → new
                                                 ▼
                                     ┌─────────  PREVIEW  ─────────┐
                                     │ New | Needs-decision | Dup  │  ← user reviews, toggles
                                     └──────────────┬──────────────┘
                                                    ▼  commit {selections}
                                   createEventForUser / updateEventForUser  (_helpers.ts)
                                                    │  (+ managed-note merge on duplicates)
                                                    ▼
                                              CalendarItem (DB)
```

Both sources converge on one normalize → diff → preview → commit pipeline; only the "fetch raw
events" step differs. Trust zones mirror the assistant design: the **client** renders the preview and
captures the user's choices; the **server** is the only place the bridge runs, the LLM is called, and
the DB is written. The **EventKit Swift helper** is the one native piece — a small `swiftc`-built
binary invoked as a child process (§5).

---

## 4. Data model (Prisma migration)

### 4.1 New model: `CalendarConnection`

One row per **calendar** the user has enabled for import. For Apple Calendar, a "connection" is one
`EKCalendar`; `accountLabel` carries its `EKSource` title (e.g. "iCloud", "Google", the account
name) so provenance reads "Apple · `<source>` · `<calendar>`". The model stays generic so Google/
CalDAV slot in later (they'd populate the OAuth-token fields, which Apple leaves null).

```prisma
model CalendarConnection {
  id            String    @id @default(cuid())
  userId        String
  provider      String    // "apple" (Later: "google", "caldav", "outlook")
  accountLabel  String    // Apple: EKSource.title (iCloud / Google / account); Google: account email
  externalCalId String    // Apple: EKCalendar.calendarIdentifier; vendor calendar id otherwise
  calName       String    // display name ("Liby's Work", "US Holidays", …)
  color         String?   // the calendar's color (EKCalendar.color) — hint for the UI

  // OAuth tokens — null for Apple (no auth; the bridge uses the OS Calendars permission).
  // AES-256-GCM encrypted via src/lib/crypto.ts when present (Google/CalDAV, Later).
  accessTokenEnc  Bytes?
  refreshTokenEnc Bytes?
  expiresAt       Int?

  syncToken    String?    // Google incremental cursor (Later). Apple has no token → window re-fetch (§10 P4).
  lastSyncedAt DateTime?
  enabled      Boolean   @default(true)

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@unique([userId, provider, externalCalId])
  @@index([userId])
}
```

### 4.2 Additions to `CalendarItem`

```prisma
model CalendarItem {
  // …existing fields…
  source       String   @default("manual") // "manual" | "apple" | "ical" (Later: "google")
  externalUid  String?  // iCalUID / EKEvent.calendarItemExternalIdentifier — cross-system dedup key (§6)
  externalId   String?  // source-native id (Apple: EKEvent.calendarItemIdentifier); for re-sync
  externalEtag String?  // change token (Apple: EKEvent.lastModifiedDate); skip unchanged on re-sync
  externalUrl  String?  // "open this event" link (Apple: EKEvent.url if present; Google: htmlLink) — §7.5
  connectionId String?  // → CalendarConnection.id; null for .ics imports
  importedAt   DateTime?

  // Idempotency backstop for re-sync: a (connection, uid) pair maps to one row.
  // (.ics imports have connectionId=null; Postgres treats NULLs as distinct, so the
  //  app-level diff — not this constraint — is what dedups .ics. That's intentional.)
  @@unique([userId, connectionId, externalUid])
}
```

`source` drives an **"imported" badge** in the UI (sibling to the existing `createdByAI` Sparkles
badge — see `EventBadges`).

---

## 5. The Apple Calendar bridge (primary source)

macOS Calendar already aggregates the user's iCloud, Google, and shared calendars; reading it via
**EventKit** (the official API) gets them all through one local bridge — no per-vendor OAuth.

### 5.1 The native helper (`eventkit-bridge`)

A small Swift program (`native/eventkit-bridge/`, compiled with the system `swiftc` — confirmed
present at `/usr/bin/swiftc`) using `EKEventStore`. It is a thin, stateless CLI that prints JSON to
stdout; libirabu's server invokes it via `child_process`. Two subcommands:

```
eventkit-bridge list-calendars
  → [{ id, title, source, sourceType, color, allowsModify }]   // EKCalendar + EKSource.title

eventkit-bridge events --from <ISO> --to <ISO> --calendars <id,id,…>
  → [{ uid,            // EKEvent.calendarItemExternalIdentifier (cross-system; maps to iCalUID)
       localId,        // EKEvent.calendarItemIdentifier (Apple-local; → externalId)
       calendarId, title, start, end, allDay, location, notes, url,
       organizer, attendees:[{name,email,status}], status,
       rrule,          // EKRecurrenceRule re-serialized to an RFC 5545 RRULE string (§8)
       lastModified }] // → externalEtag (skip-unchanged on re-sync)
```

Design choices:
- **Emit RRULE strings**, not structured recurrence — so `recurrence.ts` (§8) handles Apple, `.ics`,
  and future Google uniformly through one mapper. (EventKit gives `EKRecurrenceRule`; the helper
  re-serializes it.)
- **JSON over stdout**, no flags beyond the range/calendars — keeps the binary trivial and testable.
- The helper resolves nothing about libirabu's schema; normalization stays in TS (§8).

### 5.2 Permission & packaging

EventKit reads require the **Calendars** privacy permission (TCC). `EKEventStore.requestFullAccessToEvents`
triggers the one-time prompt; the granted process must carry the right entitlement / usage string:
- **Electron build (primary):** the packaged app declares `NSCalendarsUsageDescription` (and the
  `com.apple.security.personal-information.calendars` entitlement) and ships the compiled
  `eventkit-bridge` binary in `Resources`. The app owns the permission; the server invokes the
  bundled binary. This is the supported, durable path.
- **Dev (`next dev` on :8100):** the controlling terminal needs Calendars access; first run prompts.
  `osascript` already works on this machine (calendars enumerated in testing), so dev is unblocked
  even before the entitlement work.

### 5.3 Connections = enumerated calendars

There is no OAuth round-trip. "Connecting" = running `list-calendars`, showing the calendars in the
Connectivity menu, and letting the user toggle which to import (`enabled`). Each enabled calendar
becomes a `CalendarConnection` row (`provider:"apple"`, tokens null).

```
GET   /api/calendar/connections                  → enumerate (live list-calendars) + persisted rows
PATCH /api/calendar/connections/:id              → enable/disable a calendar
POST  /api/calendar/connections/:id/sync         → run the bridge for its range → preview
```

> **Provenance note:** EventKit exposes the underlying account via `EKSource` (e.g. "iCloud",
> "Google", the account name). So even routed through Apple Calendar, an event keeps coarse
> provenance — "Apple · Google · Liby's Work" — stored in `CalendarConnection.accountLabel` + `calName`.

---

## 6. De-duplication (the heart of it)

### 6.1 What `UID` is

`UID` is an **iCalendar (RFC 5545) property** assigned by whatever app *creates* an event; it
travels with the event across systems. The same invite emailed to you (`.ics`) and present on your
Google Calendar carry the **same** UID. **EventKit exposes it as `EKEvent.calendarItemExternalIdentifier`**
(distinct from the Apple-local `calendarItemIdentifier`) — so an event read from Apple Calendar and the
same event from a `.ics` file dedup correctly. So a UID match is *proof* two records descend from one
source event. Caveats baked into the design: **manual libirabu events have no UID** (internal — fuzzy
path only); a recurring **series shares one UID** (instances differ by `RECURRENCE-ID`); some sources
regenerate UIDs (so UID *absence/mismatch* ≠ "different"). Note `calendarItemExternalIdentifier` is
**not guaranteed unique** (a copied event can share one) — fine here, since a UID match only ever
*merges*, which the preview still surfaces.

### 6.2 Tiered matching (`diff.ts`)

| Tier | Condition | Action |
|------|-----------|--------|
| **1 — Confident** | incoming UID **==** an existing `externalUid` (+ same occurrence for series) | **Auto-merge.** Shown in preview as pre-decided (overridable), no prompt. |
| **2 — Ambiguous** | no UID match, but **name + date/time** are close to an existing event (either side may lack a UID) | **Ask the user.** Side-by-side modal with the **AI's recommendation** pre-selected. |
| **3 — New** | nothing similar | Import as a new event (listed under "New"). |

**Fuzzy candidate rule (tier 2 trigger).** An existing event is a candidate when normalized title
matches (case-insensitive, trimmed; near-match via a cheap similarity ≥ threshold) **and** start
time is within a window (proposed default: same calendar day for all-day/band; ±2 h for timed —
see §10 Open decisions). Candidates are ranked; the top 1–3 go to the modal.

### 6.3 AI suggestion (advice only)

Structurally identical to the assistant's **auditor**: a focused `getLLM().chat()` call returning a
parsed JSON verdict (the auditor's `{decision,reason,risk}` → here `{same,confidence,suggestion,reason}`).

```ts
// lib/import/aiDedup.ts — input: the two events' METADATA only (title, start/end, location,
// attendees, a notes excerpt). Output (parsed like auditor.parseVerdict):
interface DedupSuggestion {
  same: boolean;
  confidence: number;            // 0..1
  suggestion: "merge" | "keep_both";
  reason: string;                // one line shown in the modal
}
```

- **Cost:** called only for tier-2 candidates, **batched** (all ambiguous pairs in one request).
- **Safety:** the model sees only event metadata for a yes/no similarity judgment and **cannot act**
  — an injection in an imported note has nothing to drive. (Same isolation philosophy as the
  auditor; reuses the JSON-extraction pattern in `auditor.ts`.)
- The modal pre-selects the suggested action but the **user clicks** — AI never auto-merges tier 2.

### 6.4 Note merge (on any merge — tier 1 auto or tier 2 confirmed)

Merging never clobbers. The vendor's details become a **managed block** with provenance markers;
the user's own note content lives outside it and is preserved verbatim. The full rules are in §7.

---

## 7. Imported-event lifecycle: immutability, managed notes, overlays

To start (v1), externally-imported events are **partially immutable**: their identity (title) and
schedule (start/end, all-day/timed kind, recurrence) are **owned by the vendor**. The user does not
edit those in libirabu — they click through to the source (§7.5). What the user *can* do is layer
libirabu-local information on top. This keeps re-sync unambiguous: the vendor wins on identity/time,
the user wins on overlays, and the note has one **fixed two-region layout** each owns:

```
notes  =  <managed block>          ← vendor-owned PREFIX (immutable in the editor)
          <blank line>
          <user content>           ← user-owned POSTFIX (the only editable part)
```

The managed block is **always the prefix**; everything the user types is a **postfix** after it.

### 7.1 The managed note block

A dedicated algorithm (`lib/import/renderManagedNote.ts`) formats the vendor's mutable details —
**description, location/address, meeting/conference link, organizer, attendees + RSVP
(going/declined/tentative), status** — into clean markdown, wrapped in **HTML-comment markers**:

```md
<!-- libirabu:import:begin uid=<iCalUID> rev=<etag> -->
*Imported from Apple · Google · Liby's Work*
📍 **Where** · 3400 N Charles St, Baltimore
🔗 **Join** · https://meet.google.com/abc-defg-hij
👤 **Organizer** · alice@example.com
👥 **Attendees** · Alice ✓ · Bob ~ · Carol ✗
📝 <vendor description, marker-sanitized>
<!-- libirabu:import:end -->
```

(Markers use a **source-neutral** namespace `libirabu:import` — not Google-specific — since the
primary source is Apple Calendar. Implemented in `src/lib/import/managedNote.ts`.)

**Why HTML comments:** `NotesPreview` renders react-markdown **without `rehype-raw`** ("No raw
HTML"), so the marker comments are **invisible when rendered** yet **persist in the stored note
string** (rendering ≠ storage). The block's *content* between the markers is ordinary markdown, so it
shows normally. The markers also can't collide with the §17 TODO-token grammar.

### 7.2 The editor only edits the postfix

A small helper (`lib/import/managedNote.ts`) is the single owner of the layout:

```ts
splitNote(notes): { managed: string; user: string }   // parse on the markers (managed="" if none)
composeNote(managed, user): string                     // managed + "\n\n" + user
replaceManaged(notes, freshManaged): string            // swap the prefix, keep the user postfix
```

In the event drawer, for imported events `EventDrawerShell` calls `splitNote` and:
- renders the **managed block read-only above the editor** (greyed, via `NotesPreview` or a styled
  block — markers stay invisible since react-markdown drops them, §7.1);
- passes **only `user`** as `NotesEditor`'s `value`. The managed text **never enters the CodeMirror
  document**, so it is *structurally* un-editable — no read-only ranges or change-filters needed.

On change, the parent recomposes `composeNote(managed, editedUser)` before persisting. (Manual events
have `managed === ""` → the editor behaves exactly as today, editing the whole note.) Two small wiring
notes: the preview's ⌘-click-to-edit line number is offset by the managed block's line count when
handed to `NotesEditor.cursorLine`, and ⌘-click on a managed line is a no-op.

### 7.3 Re-sync = swap the prefix, keep the postfix

On re-import the server calls `replaceManaged(existingNote, freshBlock)` — regenerate the managed
prefix from fresh vendor data, keep the user postfix verbatim. So when an attendee changes their RSVP,
the address changes, or a meeting link is added upstream, only the prefix updates and **nothing the
user wrote is lost** — and because the user could never edit the prefix in the first place, there is
**no "reverted on sync" surprise** (this resolves the v0.1 tamper-policy fork: the boundary is
enforced at edit time, not reconciliation time). The `rev=<etag>` marker lets re-sync skip unchanged
events cheaply.

### 7.4 User overlays (always preserved, never vendor-owned)

The user may freely add, on an imported event:

- **Tags** (`tags[]`) and **color** — libirabu-local, ignored by sync.
- **Promote to all-day band** (`promoteTrack`) — a libirabu display concern.
- **Extra TODOs / free notes** — the user postfix, including §17 checkbox TODOs (`- [ ] follow up …`)
  and per-occurrence notes (`occurrenceNotes`, which are user-only in v1 — no per-occurrence managed
  blocks yet).

Enforcement: `updateEventForUser` gains an **imported-event guard** — when a row has
`source != "manual"`, edits to `title`, `start`, `end`, `kind`, and `repeat` are rejected; `tags`,
`color`, `promoteTrack`, `notes`, and `occurrenceNotes` are allowed. For `notes`, the guard also
verifies the incoming value still begins with the current managed prefix (defense in depth — the UI
already prevents editing it). The drawer disables the locked title/time fields with a tooltip pointing
at the source link.

### 7.5 Link to the source

`CalendarItem.externalUrl` stores the source's deep link. For Apple-routed events the cleanest "edit
at source" is to **open the event in Calendar.app** — `EKEvent.url` is often empty, so the drawer's
**"Open in Calendar ↗"** uses an `ical://`/`x-apple-calevent://` deep link (or falls back to opening
Calendar.app) so the user edits identity/time there; the next sync pulls the change back. When the
underlying source is Google and a web `htmlLink` is available, prefer that. (The corner badge is
decorative/`aria-hidden`; the click-through is a real link in the drawer, not the badge.)

---

## 8. Normalization (`normalize.ts`, `recurrence.ts`)

Source event (EventKit JSON or parsed VEVENT) → libirabu's floating **main-tz wall-clock** `ApiEvent`
shape (kept identical to what `createEventForUser` validates, so import reuses that one write path).
Both sources land in the same `NormalizedEvent`, so `normalize.ts` is source-agnostic past the fetch.

- **All-day events are ignored by default.** The user rarely uses all-day items (they're mostly
  birthdays/holidays), so `normalizeEvents` **partitions source all-day events out** of the import
  set (`{ events, allDay }`); the pipeline imports `events` and drops `allDay`. They aren't lost —
  `allDay` is returned, so a future "inbox" can surface them for opt-in. (Reinforced by the
  Birthdays/Holidays calendars defaulting to *disabled* in the Apple bridge — §11.)
- **Kind mapping (for the timed events that are imported):** single-day timed → `timed`. Multi-day
  **timed** events (libirabu `timed` is single-day) get promoted to `band` over the day span (flagged
  in preview, §11). Imports never produce `deadline` (a CFP/assistant concern, not calendar import).
- **All-day end is exclusive** in iCal (`DTEND` for `VALUE=DATE`); EventKit gives explicit
  start/end `Date`s. libirabu `band` end is **inclusive** → normalize to the inclusive last day.
- **Timezones:** the bridge emits ISO instants; iCal gives `DTSTART;TZID=…`. Convert the instant to
  the user's **main tz** wall-clock (a small `instantToMainWall(iso, mainTz)` using `Intl`, alongside
  the existing `convertWallClock`).
- **Recurrence (`recurrence.ts`):** the bridge re-serializes `EKRecurrenceRule` → **RRULE string**, so
  Apple and `.ics` share one mapper. Map the subset libirabu's `Repeat` supports — `FREQ=DAILY|WEEKLY|
  YEARLY`, `BYDAY` (→ `weekly` w/ `days`, or `weekdays` for Mon–Fri), `INTERVAL` (→ `n`, clamped 1–4),
  `UNTIL` (→ `until`), `EXDATE` (→ `exdates`). **Unsupported** RRULEs (MONTHLY, BYSETPOS, COUNT,
  INTERVAL > 4, …) degrade: import best-effort + stash the raw RRULE in notes + **flag in the preview**
  ("recurrence simplified") so it's never silently wrong.

---

## 9. APIs & UI

### 9.1 Endpoints

```
POST /api/calendar/import/preview
  body: { connectionId } | { icsText }          // one source per call; reads, NEVER writes
  → { groups: { new: PreviewItem[], decide: PreviewItem[], duplicate: PreviewItem[] },
      // each decide-item carries its candidate(s) + the AI DedupSuggestion }

POST /api/calendar/import/commit
  body: { items: { tempId, action: "create" | "merge" | "skip", targetId?, edited? }[] }
  → { created: ApiEvent[], merged: ApiEvent[], skipped: number }   // via createEventForUser/updateEventForUser

GET   /api/calendar/connections              → enumerate Apple calendars (bridge) + persisted rows + lastSyncedAt
PATCH /api/calendar/connections/:id          → enable/disable one calendar
POST  /api/calendar/connections/:id/sync     → run the bridge for its range → preview
```

`.ics` upload reuses the assistant upload pattern (`runtime="nodejs"`, `requireUser`, `formData`),
but parses VEVENTs (iCal parser — **`node-ical`**) instead of extracting text. The Apple bridge runs
server-side via `child_process` against the bundled `eventkit-bridge` binary (§5).

### 9.2 The "Connectivity" top-bar menu

A **"Connectivity"** entry on the calendar toolbar (`.cc-bar-actions` in `CalendarCanvas.tsx`,
beside `TagFilterMenu`/`EditMenu`) opens a panel that is the single home for all import management:

- **Calendars** — list the Apple calendars from `list-calendars`, grouped by `EKSource` (iCloud /
  Google / …); toggle which to import (`enabled`). A first-run "Grant Calendar access" affordance
  triggers the TCC prompt.
- **Sync** — a **"Sync now"** button per calendar (and a global one); shows a spinner while running.
- **Last synced** — each calendar shows its `lastSyncedAt` ("Synced 4m ago") so staleness is visible.
- **Import a `.ics` file** — a dropzone (drag/drop/paste) for emailed attachments.

A "Sync now" run invokes the bridge and routes through the same **preview** (so the always-review
guarantee holds); tier-1 UID matches are pre-decided, tier-2 go to the decision modal.

### 9.3 Event UI

- **Imported badge:** `EventBadges` gains an `imported` flag rendering a small corner icon (e.g.
  lucide `CalendarSync`, `size={9}`) beside the existing AI/recurrence/promoted badges. Driven by
  `source != "manual"`.
- **Locked fields:** in the event drawer/editor, title & time inputs are disabled for imported events
  with a tooltip ("Synced from Apple Calendar — edit at the source ↗"); tags/color/promote/TODOs stay editable.
- **Open at source:** an **"Open in Calendar ↗"** link (from `externalUrl`, §7.5) in the drawer.
- **Preview screen:** three groups (**New** pre-checked; **Needs your decision** each with the AI hint
  + merge/keep-both toggle and a side-by-side diff; **Duplicates** auto-merged/overridable) → **Import**
  commits the selections.

---

## 10. Phased plan

- **P0 — Schema + foundation.** Migration: `CalendarConnection` (generic, Apple-shaped) + `CalendarItem`
  provenance columns (incl. `externalUrl`). `lib/import/types.ts` (`NormalizedEvent`, `PreviewItem`,
  `DedupSuggestion`).
- **P1 — `.ics` pipeline end-to-end.** `ical.ts` (parse via `node-ical`) → `normalize.ts` +
  `recurrence.ts` → `renderManagedNote.ts` + `managedNote.ts` (managed block, §7) → `diff.ts`
  (tier 1/3 only) → `import/preview` + `import/commit` → the **Connectivity** menu (with `.ics`
  dropzone) + preview UI. Imported badge in `EventBadges`; imported-event guard + split-editor in the
  drawer; source link. *Proves the whole pipeline + immutability + managed notes with zero native code.*
- **P2 — Apple Calendar bridge (primary source).** Build `native/eventkit-bridge` (Swift; `list-calendars`
  + `events`, RRULE re-serialization); `lib/import/apple.ts` (invoke via `child_process`, JSON → 
  `NormalizedEvent`); the Connectivity menu's calendars section (grouped by `EKSource`) + per-calendar
  "Sync now"; TCC permission flow; Electron entitlement + binary bundling. Apple events flow through the
  P1 pipeline unchanged.
- **P3 — Dedup tier 2 + AI suggestion. ✅ Done.** Fuzzy matching in `fuzzy.ts` (Dice-bigram title
  similarity ≥ 0.68 AND same-day/±2h time window; hidden rows excluded) routed to the `decide` bucket
  in `diff.ts`; `aiDedup.ts` (`getLLM`, batched, auditor-style JSON parse, sandboxed — metadata-only,
  fails open to "no hint"). Ambiguous matches are **persisted to a Triage store** (`TriageItem` model)
  during a sync and resolved later (Merge / Import-new / Skip) in the **Connectivity → Triage** box —
  they are NOT resolved inline (the sync review just reports "N sent to Triage"). Merge targets are
  server-validated against the pipeline's own candidates. The **Inbox** menu stub was removed (its
  role is covered by the inline sync review). Endpoint: `GET/POST /api/calendar/triage`.
- **P4 — Incremental re-sync.** Rolling-window re-fetch using `lastModified`/`rev` to skip unchanged;
  managed-block replace-in-place on re-sync (§7.3); `lastSyncedAt` display polish; deleted-upstream
  handling.
- **Later (non-blocking):** direct **Google OAuth** + CalDAV as peer/headless sources (the model + 
  pipeline already accommodate them); Gmail auto-scan for `.ics`; an assistant `import_events` tool;
  opt-in two-way sync (the schema already records what's needed).

---

## 11. Open decisions (for the user)

1. **Fuzzy-match window (tier 2 trigger):** same-day (all-day) + ±2h (timed)? Looser/tighter?
   *Recommend: exact-title-or-≥0.8-similarity AND (same day for band, ±2h for timed).*
2. **Multi-day timed events:** promote to `band`, or import as a `band` only when truly all-day and
   otherwise clamp/flag? *Recommend: promote multi-day to `band`; flag in preview.*
3. **AI dedup model tier:** reuse the actor model, or a cheap/auditor tier? *Recommend: cheap tier
   (it's a small structured judgment), behind the same `getLLM()` swap point.*
4. **Default action for tier-1 "changed" (vendor moved an event):** auto-accept the new time, or
   list under "decide"? *Recommend: list as a pre-checked "changed" row (visible, overridable).*
5. **Imported badge vs. tag:** a dedicated badge only, or also write a `#imported`/`#apple` tag the
   existing tag filter can use? *Recommend: both — badge for glance, tag for filtering.*
6. **Sync range:** what window does the bridge fetch per sync? *Recommend: a rolling window (e.g.
   −1 month … +12 months), configurable per calendar; full-history import is opt-in.*
7. **Birthdays / Holidays / Siri Suggestions calendars:** import by default or off until enabled?
   *Recommend: enumerate all, default-enable only the user's own calendars; auto-generated ones
   (Birthdays, Siri Suggestions) start disabled.*

**Resolved (2026-06-30):**
- **All-day events → ignored by default** (the user rarely uses them; mostly birthdays/holidays).
  `normalizeEvents` partitions them into `allDay` and the pipeline drops them; recoverable via a
  future inbox. (§8)
- **Marker namespace** = `libirabu:import` (source-neutral), not `gcal:`. (§7.1)

---

## 12. Deployment topology & future clients

The bridge is a **server-side capability behind the REST API**; clients never touch EventKit. So the
same server runs on the user's laptop today and an always-on Mac later with **no client changes** — the
only requirement is that the host is a Mac signed into the relevant Calendar accounts.

### 12.1 Two host modes (same code)

**Packaging status (2026-07-02): the user's MacBook Pro IS the persistent server** (client/server
separation deferred). The menu-bar `Libirabu.app` no longer runs `next dev` — it execs
`scripts/serve.sh`, which on every launch: ensures Postgres (docker) is up → `prisma generate` →
`prisma migrate deploy` → `next build` if there's no build yet → `next start` (production) on :8100.
Regenerating the client each boot is what makes a schema change "just work" after a restart (kills the
stale-client 500 class). Postgres stays host-managed (docker on 5433) — no DB bundling. Reboot
survival: `scripts/install-login-item.sh` (`npm run serve:login-item`) installs a LaunchAgent that
`open`s the app at login **via LaunchServices** (so it stays the TCC-responsible process; a raw
launchd exec of node would not inherit the Calendar grant). Docker Desktop must also be set to start
at login. Node is still the fnm-realpath baked by `build-app.sh`. Caveat: `next start` is a real
build, so code changes need a rebuild (quit + relaunch, or `npm run build`); and the production
server + `npm run dev` can't share :8100, so quit the server while actively coding.

- **Local-Mac mode (now):** the native menu-bar app runs the production server (above). The app bundle
  (LaunchServices-launched) holds the Calendars TCC permission. On-demand "Sync now" + `.ics`.
- **Mac-Mini-server mode (target):** an always-on Mac Mini runs the Next.js server + Postgres + the
  `eventkit-bridge` + a periodic sync agent. Because the Mini is logged into the same iCloud/Google
  account, its Calendar.app aggregates the same calendars. All clients read the one DB via the API.

```
[laptop browser] [iOS app] [other devices]
        └──────────── HTTPS over Tailscale / LAN ───────────┐
                                                            ▼
                        ┌──────────── Mac Mini (always on, auto-login) ───────────┐
                        │ Next.js (libirabu)  +  Postgres   ← single source of truth │
                        │ eventkit-bridge (EventKit, same accounts)                  │
                        │ launchd LaunchAgent: periodic pull → diff → ingest         │
                        └─────────────────────────────────────────────────────────┘
```

### 12.2 Communication scheme

- **Transport:** REST + SSE over HTTP. Same LAN → `http://macmini.local:8100`; remote → **Tailscale**
  (zero-config WireGuard, stable private IP, encrypted, no port-forwarding). Cloudflare Tunnel if a
  public hostname is ever wanted.
- **Source of truth:** Postgres on the Mini. The bridge syncs Apple Calendar → DB; every client reads
  the same DB, so "everything synced" is automatic.
- **Auth:** existing NextAuth, plus network-level isolation from Tailscale.

### 12.3 Background sync (✅ done — P5)

An unattended pull can't show a modal, so it applies the SAFE, reversible tiers and parks the rest —
the user's chosen policy (2026-07-02):

- **Auto-apply** brand-**new** events (create) and **tier-1 (UID)** matches (merge/refresh). Both are
  additive + reversible (imported events are immutable overlays, soft-deletable, re-syncable).
- **Tier-2 ambiguous** → **Triage** (unchanged) for later review.
- **Removed-upstream** → **counted/flagged only, never auto-deleted** (deletion is the one
  irreversible-feeling action; it stays a manual confirm in the on-demand preview).
- **Manual `.ics` drops and on-demand "Sync now"** keep the full synchronous preview screen.

**Implementation:** an **in-process scheduler** (`src/lib/import/autoSync.ts`), started once from
`src/instrumentation.ts` (gated to the production server via `NODE_ENV`/`NEXT_RUNTIME`, since only the
LaunchServices-launched app is TCC-responsible; `AUTO_SYNC=1/0` overrides, `AUTO_SYNC_INTERVAL_MS`
tunes the ~20-min default). Each tick calls `autoSyncAll(userId)` → `autoSyncConnection` (fetch →
`previewOf(withAi)` → `persistTriage` → auto-commit new + tier-1 → bump `lastSyncedAt`), isolated
per connection, non-overlapping. The latest tally lives in memory behind `GET /api/calendar/
sync-status`; the calendar polls it (`useBackgroundSync`) every 60 s and fires `calendar:changed`
when a tick lands new/updated events, so background changes surface in the open view instead of
silently. A per-user **"Automatic sync" toggle** in the Connectivity menu (persisted on
`CalendarPrefs.autoSync`, default on) gates it — the scheduler reads the pref each tick, so flipping
it takes effect next cycle without a restart (`GET/PUT /api/calendar/auto-sync`).

### 12.4 Headless Mac Mini caveats

- **TCC is GUI-granted:** grant Calendar access once via Screen Sharing/locally; it persists.
- **Auto-login + stay-logged-in:** EventKit/iCloud calendar access needs a live user session, so the
  sync agent must be a **user LaunchAgent**, not a system LaunchDaemon.
- **Calendar.app configured:** the Mini must have the same accounts added and syncing.

### 12.5 Future iOS app

A **thin client** over the same API (Tailscale) — no EventKit of its own, since the Mini is the
calendar gateway. Minimal UI, focused on **quick AI actions** (the assistant SSE endpoint) and reading
the synced calendar/TODOs. It rides entirely on the existing server contract; no server changes needed.
