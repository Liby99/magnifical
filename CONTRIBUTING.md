# Contributing to MagnifiCal

Thanks for looking under the hood. This file is the short version of how work happens
here; the design notes in `docs/` are the long version for each subsystem.

## Build & test

Everything except the .app shells is a Swift package:

```sh
cd CalendarKit
swift build          # builds all layers + the CalendarMac dev shell
swift test           # ~180 tests, hermetic (temp-dir stores, no signing, no network)
```

That loop is the whole review gate for most changes — if `swift test` passes, CI passes.
The .app targets (`CalendarApp.xcodeproj`, generated from `project.yml`) only matter for
changes to the shells themselves; build those in Xcode.

## Architecture in one paragraph

`CalendarGeometry` is pure layout math (no dependencies). `CalendarEngine` owns state:
items, persistence, undo, iCloud sync, imports, notifications. `CalendarRender` draws:
the Canvas fast paths, sticker views, Liquid Glass (with a macOS 15 material fallback —
never call `.glassEffect` directly; use `GlassCompat`). `CalendarUI` is the macOS shell:
input, menus (single-sourced in `AppMenu.sections` — never hand-add to one shell),
drawer, dashboards. Dependencies point strictly down that list.

## Style

- `swiftformat` with the repo's `.swiftformat` config; CI checks it.
- Comments explain *constraints and why*, not what the next line does. Match the density
  you see around you.
- Perf-sensitive paths (rendering, scrolling): changes need before/after numbers from
  the bench harness (`CalendarKit/bench/` — see its README for scenes and env flags).

## PRs that merge quickly

1. One concern per PR, with a test when behavior changes (`Tests/CalendarEngineTests`
   has patterns for engines-in-temp-dirs, feeds, undo, multi-calendar).
2. `swift test` green locally; note anything you verified by hand in the app.
3. UI changes: a before/after screenshot or clip (the demo recorder in
   `Sources/CalendarUI/DemoController.swift` can script scenes).
4. First-time contributors: the CLA bot will ask for a one-time signature on the PR —
   this grants the project the right to distribute your change in the App Store build
   (the source stays GPL either way).

## Good contribution lanes

- **ICS provider quirks** — every calendar vendor's feed is weird in a new way. Attach
  a minimal `.ics` fixture reproducing the bug; the parser tests make these easy to lock.
- **Localization** — the app is English-only today; infrastructure PRs welcome.
- **Help book** — `Sources/CalendarUI/Help/HelpContent.swift` is plain data.
- **Keyboard navigation gaps** — see `docs/keyboard-navigation.md` for the model.
- **Import edge cases, themes, accessibility.**

Big features (sync providers, new views): open an issue first so we agree on the design
before you invest — the `docs/` design-note format is the preferred way to propose one.

## Reporting bugs

Use the bug template. The in-app **Help ▸ Report a Problem…** prefills one with your
app + macOS version. For import bugs, an anonymized `.ics` snippet is gold; for crashes,
Console.app output filtered to subsystem `dev.magnifical.calendar`.
