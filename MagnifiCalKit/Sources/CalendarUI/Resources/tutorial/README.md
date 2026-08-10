# Tutorial carousel GIFs

Drop animated GIFs here with these exact names (see `TutorialView.swift` → `TutorialView.slides`).
Each slide falls back to a placeholder if its GIF is missing, so the carousel works without them.

Each tutorial demo ships in TWO theme variants — `<name>-light.gif` and `<name>-dark.gif` — and the
carousel/Help browser shows the one matching the viewer's appearance (plain `<name>.gif` is the fallback
for single-variant assets like the extra Help demos). Record a variant with `THEME=light|dark
./scripts/record-tutorial.sh <scene> [seconds]` (demo mode pins "now" to 4 pm so recordings are
time-of-day independent).

The carousel order (TutorialView.slides) is: pinch-zoom, band-year, timed-week, ai-assistant, markdown-notes, dashboard-tour.

| filename            | scene (record-tutorial.sh) | caption |
|---------------------|----------------------------|---------|
| `pinch-zoom.gif`    | `pinch-zoom`  | Pinch to zoom into monthly, weekly, or daily view. |
| `band-year.gif`     | `band-year`   | Drag across days in the year view to create multi-day events. |
| `timed-week.gif`    | `timed-week`  | Drag on the timeline to create timed events. |
| `ai-assistant.gif`  | `ai-assistant`   | Click the AI button to let AI help you manage your calendar. |
| `markdown-notes.gif`| `markdown-notes` | Edit markdown notes in events or the daily notepad to add TODO items. |
| `dashboard-tour.gif`| `dashboard-tour` | The TODO/NOTE/PROJ dashboard tour (⌘B/⌘E/⌘J). NOT YET RECORDED — slide shows the placeholder. |

Full-window scenes (pinch-zoom, ai-assistant) are recorded with `FPS=12 SCALE=900 COLORS=128 DITHER=none` to
keep the file small; the cropped scenes use the script defaults. All get a `gifsicle --lossy` pass.

These are produced automatically by `scripts/record-tutorial.sh <scene>` (see DemoController.swift). They're
copied into the app bundle at build time and loaded via `Bundle.module.url(...subdirectory:"tutorial")`. A
slide falls back to a placeholder if its GIF is missing.

## Still help screenshots (PNGs)

The Help browser's `.image` blocks (HelpContent) use STILL screenshots, captured by
`./scripts/capture-help-shots.sh [scene ...]` — one settled frame per scene instead of a movie, in the
same `<name>-light.png` / `<name>-dark.png` theme pairs (HelpView's HelpStill picks the variant). Scenes
live in DemoController+HelpGIFs.sceneHelpShot and seed TODAY-RELATIVE data, so a re-capture always shows
current-looking bars/dates.

| filename           | scene (capture-help-shots.sh) | shows |
|--------------------|-------------------------------|-------|
| `proj-gantt.png`   | `proj-gantt`   | The PROJ tab's gantt charts: bars, hatch, due ticks, milestone rule, event box, pinned row. |
| `todo-panel.png`   | `todo-panel`   | The TODO tab: Pinned section, due/priority/followup meta, project pills, provenance prefixes. |
| `note-preview.png` | `note-preview` | The NOTE tab's preview: DUE/FROM/DONE pills, priority badges, tag/person/project chips. |
