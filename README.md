# MagnifiCal

**A calendar you zoom.** One continuous canvas holds your whole year — pinch in and it
re-forms into a month, a week, a single day. Notes, to-dos, and projects live *inside*
the calendar, not beside it.

<!-- TODO before publishing: hero GIF here (pinch-zoom year→day dive; record with the
     demo scenes — scripts/record-demos, "pinch-zoom" scene, light + dark). -->

## Why MagnifiCal

- **Semantic zoom** — year, month, week, and day are the same calendar at four scales,
  not four screens. 120fps scrolling and zooming, built on a custom SwiftUI canvas
  renderer.
- **Your notes live on your days** — every event and every day holds Markdown notes with
  to-do items; dashboards collect them into TODO lists, a notes editor, and project
  gantt views (⌘B / ⌘E / ⌘J).
- **Local-first, private by construction** — your data is yours: on-disk JSON, synced
  through *your* iCloud. No accounts, no servers, no analytics, ever.
- **Shows your other calendars** — read-only imports from Apple Calendar (EventKit),
  Google Calendar, and Outlook (secret/published ICS addresses). Hide, recolor,
  annotate, or promote imported events without touching the originals.
- **AI assistant, your keys** — an optional assistant that reads and edits your calendar
  through audited tools, talking to any OpenAI-compatible endpoint with credentials you
  provide. Keys stay in your macOS Keychain.

## Install

| Channel | For |
| --- | --- |
| **Mac App Store** ($7.99) | One-click install + updates, and supporting development |
| **[Direct download](../../releases/latest)** (free) | Notarized DMG, auto-updates via Sparkle |
| **Build from source** (free) | `git clone` + Xcode — see below |

MagnifiCal is free software under the GPLv3. The App Store version is identical to the free
one; buying it funds development. (The same model as IINA and friends.)

Requires macOS 15+. iPhone companion (read-only viewer) via TestFlight.
Website: [magnifical.dev](https://magnifical.dev)

## Building from source

```sh
# The engine + UI live in a Swift package — no signing needed:
cd CalendarKit
swift build && swift test          # ~180 hermetic tests

# The .app shells (macOS "MagnifiCal", iOS companion) build in Xcode:
open CalendarApp/CalendarApp.xcodeproj
```

The package layering is the map: `CalendarGeometry` (pure math) → `CalendarEngine`
(state, persistence, sync) → `CalendarRender` (canvas renderer + glass) → `CalendarUI`
(AppKit/SwiftUI shell). See `docs/` for design notes on subsystems.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the build/test
workflow, style, and what makes a merge-able PR. Good entry points are labeled
[`good first issue`](../../labels/good%20first%20issue): ICS provider quirks,
localization, Help topics, keyboard gaps.

Contributions require signing the CLA (one-time, automated in the PR) — it's what lets
the project ship the App Store build alongside the GPL source.

## License

[GPL-3.0](LICENSE). © the MagnifiCal contributors.
