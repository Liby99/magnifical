# CalendarKit

Native Swift port of the web calendar (`src/app/calendar`). The web app is the
**ground truth**; the pure geometry layer here is a faithful port of `geometry/*.ts`.

## Milestone

A macOS app that shows the semantic-zoom calendar and is interactable:

- **Pinch** to zoom continuously across Year → Month → Week → Day (live morphing).
- **Click** to drill in one level (year→month→week→day), following the cursor.
- **Esc** to zoom back out one level.
- **Scroll** to move the year view / scroll the day timeline; **horizontal scroll**
  shifts the week window (week view) or pages days (day view).
- Hover highlights track the cursor; today / now-line markers; a few seed events.

## Layout

```
Sources/
  CalendarGeometry/   pure math — no deps. Ported 1:1 from geometry/*.ts.
    Types · Layout · Dates · Frames · EventGeom · Scene · HitTest
  CalendarEngine/     @MainActor view-state + tween clock + gesture handling
  CalendarUI/         Canvas renderer + SwiftUI CalendarView + AppKit input bridge
  CalendarMac/        macOS app bootstrap (executable)
Tests/
  CalendarGeometryTests/  layout + date parity checks
```

The one deliberate change from the TS: the module-level globals (`setDaily`,
`syncWeekHourH`, `setCalendarYear`) are replaced by an explicit, value-typed
`SceneInput` passed to every geometry function — so the layer is pure and
concurrency-safe.

## Run

Primary (debuggable) — the Xcode app in `../CalendarApp` wraps this package:

```sh
cd ../CalendarApp && open CalendarApp.xcodeproj   # then ⌘R; use LLDB + Debug View Hierarchy
xcodegen generate                                 # regenerate the project from project.yml
```

Command-line (no Xcode):

```sh
swift build -c release && ./scripts/run-mac.sh    # wraps the CalendarMac executable in a .app
swift test                                        # geometry parity tests
```

## Not yet ported (next milestones)

Event editing/drawers, band events, deadlines, recurrence, undo/redo, the sync
engine + server client, the markdown editor, and the other platform targets
(iOS/iPadOS/watchOS/visionOS). Deployment target is macOS 14 for the milestone;
the plan bumps it to 26 for Liquid Glass.
