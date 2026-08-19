# Tutorial slide clips (bundled)

The Welcome carousel's demo clips — the ONLY media that ships in the app bundle (first launch must
work offline). Each slide is a looping H.264 `.mp4` in TWO theme variants (`<name>-light.mp4` /
`<name>-dark.mp4`), played by `LoopingVideo` (HelpMedia.swift); a slide falls back to a placeholder
if its clip is missing. Record with:

    THEME=light|dark ./scripts/record-tutorial.sh <scene> [seconds]

(demo mode pins "now" to 4 pm so recordings are time-of-day independent; [seconds] just needs to
be ≥ the scene length — the capture trims to the scene's end stamp).

The carousel order (TutorialView.slides): pinch-zoom, band-year, timed-week, ai-assistant,
markdown-notes, dashboard-tour. Those six scene names route to this folder; every OTHER scene is
help-only and routes to `media/help/` (fetched from GitHub at runtime, never bundled) — and the
still screenshots for Help's `.image` blocks are captured to `media/help/` by
`./scripts/capture-help-shots.sh`. See `media/README.md`.

`app-icon.png` is the welcome slide's icon fallback for the unsigned dev shell (refreshed by
`scripts/gen-icons.sh`).
