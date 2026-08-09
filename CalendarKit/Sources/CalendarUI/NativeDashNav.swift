// Keyboard navigation state for the NATIVE dashboard TODO panel (pinned week/month) — the native
// stand-in for the webview's CK.nav* bridge, driven by the SAME engine key system (DashCmd via
// onDashCommand): ⌘B focuses the list, ↑/↓ move the row cursor, Space toggles, Enter opens, Esc
// leaves. The panel registers its VISIBLE rows (display order, frozen-structure order) each
// render; CalendarView's command handler acts on the current row through the model.

import CalendarEngine
import Foundation
import Observation

@MainActor @Observable final class NativeDashNavModel {
    var active = false // the TODO stop is keyboard-focused → the row ring shows
    var cursor = 0 // index into `rows` (display order)
    /// Folded PARENT rows (by soft-link anchor) — shared so the chevron click and the keyboard
    /// ←/→ fold commands drive the same state, and it survives panel re-keys.
    var collapsedSubs: Set<String> = []
    /// The visible rows, registered PER PANEL (keyed by scope|key) on each panel render —
    /// every mounted panel (live or parked) keeps its own entry fresh, and `activePanel`
    /// (pointed at the settled live panel by the overlay each frame) selects whose rows the
    /// cursor walks. Keyed registration lets a parked panel re-enter the carousel with ZERO
    /// re-evaluation. @ObservationIgnored: registration happens per frame — it must not
    /// invalidate views; the ring keys on `active`/`cursor` only.
    @ObservationIgnored var rowsByPanel: [String: [ParsedTodo]] = [:]
    @ObservationIgnored var activePanel = ""

    var rows: [ParsedTodo] {
        rowsByPanel[activePanel] ?? []
    }

    /// A note-row jump landing: the NOTE panel whose storage key matches consumes this —
    /// flips to edit with the line selected (the web's onJumpDay line-focus flow).
    struct NoteJumpRequest: Equatable {
        var key: String // note storage key ("YYYY-MM-DD" / "week:…" / "month:…")
        var line: Int // 1-based source line to select
        var seq: Int // uniquifies repeat jumps to the same line
    }

    var noteJump: NoteJumpRequest?
    /// ⌘E / Enter-on-NOTE-stop: the ACTIVE panel's editor takes keyboard focus.
    var noteFocusSeq = 0
    @ObservationIgnored private var jumpSeq = 0

    func requestNoteJump(key: String, line: Int) {
        jumpSeq += 1
        noteJump = NoteJumpRequest(key: key, line: line, seq: jumpSeq)
    }

    var currentRow: ParsedTodo? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    func focus() {
        active = true
        cursor = 0
    }

    func blur() {
        active = false
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(rows.count - 1, cursor + delta))
    }
}
