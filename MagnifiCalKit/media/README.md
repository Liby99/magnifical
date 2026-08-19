# Non-bundled media

Assets that live in the repo (and the public mirror) but NOT in the app bundle:

- **`help/`** — the Help browser's demo clips (`.mp4`) and screenshots (`.png`). The app fetches
  these at runtime from GitHub raw at this build's release tag, with a disk cache — see
  `Sources/CalendarUI/HelpMedia.swift`. Produced by `scripts/record-tutorial.sh <scene>` (any
  scene that isn't a Welcome slide routes here) and `scripts/capture-help-shots.sh`.
- **`readme/`** — GIF twins of the demos the public README embeds (GitHub can't inline-play repo
  mp4s). Produced by `GIF=1 scripts/record-tutorial.sh <scene>`.

The Welcome carousel's six slides stay bundled (first launch must work offline) — those live in
`Sources/CalendarUI/Resources/tutorial/`. Because help media is fetched at the release tag, any
re-recorded asset ships to users on the next release automatically; nothing here bloats the DMG.
