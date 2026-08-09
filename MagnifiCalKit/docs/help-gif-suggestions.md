# Help GIFs — inventory & suggestions

The in-app Help browser (`Help ▸ MagnifiCal Help`, `Sources/CalendarUI/Help/`) can show a short GIF at the top
of a topic. A topic opts in by setting `HelpTopic.gif` to an asset name; the GIF is loaded from
`Sources/CalendarUI/Resources/tutorial/<name>.gif` (same folder the onboarding carousel uses). A missing
GIF is simply not shown, so topics stay usable before the asset exists.

All GIFs are produced by `scripts/record-tutorial.sh <scene>` (see `DemoController.swift`). Recording is
privacy-isolated (throwaway store, Apple import off) and re-runnable.

## Already recorded (reused from the onboarding tutorial)

These exist today and are wired into the matching Help topics:

| asset | used by Help topic | scene |
|-------|--------------------|-------|
| `pinch-zoom.gif` | Getting Around ▸ *Zoom between year, month, week, and day*; Getting Started ▸ *The four zoom levels* | `pinch-zoom` |
| `band-year.gif` | Events ▸ *Create a multi-day event (band)* | `band-year` |
| `timed-week.gif` | Events ▸ *Create a timed event*; Getting Started ▸ *Create your first event* | `timed-week` |
| `ai-assistant.gif` | The AI Assistant ▸ *Meet MagnifiCal AI* | `ai-assistant` |
| `markdown-notes.gif` | Organizing ▸ *Notes & to-do lists* | `markdown-notes` |

## Additional Help GIFs — ALL RECORDED (2026-07-19)

Every suggested demo below is recorded (single-theme, full-window — the theme-variant pairs are only for
the five tutorial-carousel GIFs) and wired into its Help topic via `HelpTopic.gif`:

| asset | Help topic | scene | notes |
|-------|-----------|-------|-------|
| `move-resize.gif` | Events ▸ Move or resize an event | `move-resize` | rect-targeted (time-of-day independent) |
| `edit-drawer.gif` | Events ▸ Edit an event | `edit-drawer` | live swatch hover-preview → orange |
| `deadline-add.gif` | Deadlines ▸ Add a deadline | `deadline-add` | hover-sweep finds the "+" spot |
| `recurring.gif` | Events ▸ Repeat an event | `recurring` | band + drawer-driven weekly repeat w/ until |
| `search-demo.gif` | Keyboard & Tips ▸ Search your calendar | `search-demo` | types "coffee wed", flies to hit |
| `promote.gif` | Organizing ▸ Tracks & promoting events | `promote-manual` | HAND-RECORDED (real mouse); scripted `promote` scene also exists |
| `daily-dashboard.gif` | Getting Around ▸ The daily dashboard | `daily-dashboard` | rich TODO DSL seeds; real webview toggle |
| `dashboard-tour.gif` | onboarding tutorial ▸ dashboard page | `dashboard-tour` | month view → ⌘B (keycap shown, real hotkey path) pins the TODO panel → click PROJ → gantt charts; seeded @project histories (bars/hatch/milestone/event box); theme-variant pair like the other carousel GIFs |

Re-record any of them with `./scripts/record-tutorial.sh <scene> [seconds]` (full-window scenes use
`FPS=12 SCALE=900 COLORS=128 DITHER=none`). `promote-manual` stages the scene and lets a human drive the
mouse; trim the result with `gifsicle in.gif '#<first>-<last>' -o out.gif`.
