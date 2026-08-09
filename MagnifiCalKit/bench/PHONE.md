# iPhone bench protocol

The phone twin of the Mac's `scripts/bench-year.sh` harness. Same stats math (`BenchStats`,
golden-tested), same results-log line format, phone-shaped scenes driving the exact engine
mirrors the touch drivers use (`PhonePagers.swift`). Runner: `CalendarRender/PhoneBench.swift`;
app wiring: `CalendarApp/iOS/CalendarApp_iOS.swift` + `PhoneCalendarView.swift`.

**Results are only meaningful from a Release build on a physical device.**
- The Simulator uses the host's CPU/GPU with no real display pacing or thermals — use it for
  correctness only, never for fps numbers.
- Debug SwiftUI is dramatically slower; its numbers are meaningless. The `MagnifiCalPhoneBench`
  scheme is already Release — also uncheck "Debug executable" (Edit Scheme ▸ Run) for HUD runs.
- The baseline device is a non-Pro iPhone: 60 Hz, one frame = **16.67 ms**. `bench.json` adds
  `budget_ms` + `frames_over_budget` (device-relative); `hitches_over_33ms` keeps the Mac's
  threshold so lines stay comparable across logs.

## Running a scripted scene

1. Xcode: scheme **MagnifiCalPhoneBench**, destination = the physical iPhone.
2. Preflight: > 30% charge, Low Power Mode OFF, device cool (Xcode ▸ Devices shows thermal
   state), fixed brightness, other apps closed.
3. Edit Scheme ▸ Run ▸ Arguments: set `CC_DEMO` to a scene below, `CC_BENCH_PAYLOAD`, and
   `CC_BENCH_TAG` to the current git branch (the device can't know it). Enable a kill switch
   if A/B-ing.
4. ⌘R. The app stages the payload into a throwaway `Documents/bench-store` (demo mode also
   disables sync/import/notifications — the real store is untouched), runs the scene, and
   prints `== bench ==` + the log line + pretty JSON to the Xcode console.
5. Copy the log line into `bench/results-ios.log` (append; 2 runs per config, keep both).
   `bench.json`/`results.log` also land in **Files ▸ MagnifiCal ▸ bench** on the device.

Manual sessions: `CC_DEMO=bench-idle` + `CC_FPS_HUD=1` (or Menu ▸ Developer ▸ Frame rate
HUD), drive by hand. 60 Hz tints: green ≤ 19 ms p95, yellow > 19, red > 33.

## Scenes (`CC_DEMO=`)

| Scene | What it drives | Knobs |
|---|---|---|
| `bench-idle` | nothing — manual mode | |
| `bench-year-scroll` | vertical year fling (`setYearScroll` 0→max→0) | `CC_BENCH_FLING_STEPS` (120) |
| `bench-quarter-scroll` | horizontal quarter strips — the phone's primary year gesture; leg 1 focus quarter, leg 2 all four | `CC_BENCH_FLING_STEPS` |
| `bench-month-swipe` | vertical month page turns, Jun→Sep tour + revisits | `CC_BENCH_MONTHS`, `CC_BENCH_SWIPE_STEPS` (40), `CC_BENCH_SWIPE_GAP` (0.15) |
| `bench-month-hscroll` | focused month's horizontal day-column scroll | `CC_BENCH_FLING_STEPS` |
| `bench-week-swipe` | 3-day week-window turns + a timeline scroll leg | `CC_BENCH_WEEK_MONTH` (0), `CC_BENCH_WEEKS` (2,3), swipe knobs |
| `bench-day-swipe` | day page turns 15→17→15 ×2 | swipe knobs |
| `bench-pinch-zoom` | continuous pinch year→day→year ×3 (`demoMagnify`) | |

Fewer `*_STEPS` = a faster, more violent gesture (8–12 ≈ a hard flick).

## Payloads (`CC_BENCH_PAYLOAD=`)

| Value | Store |
|---|---|
| `display` (default) | `year-display-2026.json` — expanded real load |
| `dense` | `year-dense-2026.json` — 3000 ev / ~500 bands stress |
| `todos` | `todo-dense-2026.json` — real store + ~500 July todos |
| `empty` | `empty.json` |
| `documents:<name>` | `Files ▸ MagnifiCal ▸ bench-payloads/<name>.json` — drop your Mac's `CC_DUMP_DISPLAY` dump here for the true production load |

## A/B kill switches (same binary, scheme-toggled)

`CC_CANVAS_OFF` (sticker Canvas fast path) · `CC_ZOOMCANVAS_OFF` (canvas stickers during zoom)
· `CC_BANDGRAIN_OFF` (per-month band layers) · `CC_YEARCACHE_OFF` (rest-year layer cache —
moot until the cache is wired on the phone) · `CC_PROF` (per-layer ms → `layers_ms`; keys
match the Mac: `1_drawBelow`/`3_drawMid`/`5_drawAbove` + EventsOverlay's `2a_*`).

## Instruments

Product ▸ Profile (the Bench scheme's Profile action presets `CC_DEMO`/`CC_PROF`/payload —
adjust the scene there too):
- **Time Profiler + os_signpost**: add the signpost instrument; lanes appear under subsystem
  `com.calendarkit.render`. Window the flamegraph between the `benchBegin`/`benchEnd` point
  events so it covers exactly the scripted gesture.
- **Animation Hitches** template: commit/render-phase attribution for anything the CPU-side
  `layers_ms` calls cheap (glass/GPU costs are invisible to RenderProf by design).
- **SwiftUI** template: view-body counts — the tool that caught the Mac's 120 Hz panel
  re-creation.

## Baseline matrix (record before any feature/optimization work)

Into `bench/results-ios.log`, 2 runs per line, tag = branch:
1. All 7 scripted scenes × payloads {display, dense, empty}.
2. `documents:dump` (real data) × {year-scroll, quarter-scroll, month-swipe, pinch-zoom}.
3. A/Bs on display payload: `CC_CANVAS_OFF` × {year-scroll, quarter-scroll, month-swipe};
   `CC_ZOOMCANVAS_OFF` × pinch-zoom; `CC_BANDGRAIN_OFF` × {year-scroll, quarter-scroll}.
4. One `CC_PROF=1` pass per scene on display payload (seeds `layers_ms` attribution).

Log line format (identical to `results.log`, plus the device tag):

    2026-08-03 12:00 [main|bench-month-swipe/release/display/390x844@60/device=iPhone14,7/os=26.0] avg 55.2 fps | ...
