// Full-keyboard control of the calendar — a single TABLE-DRIVEN state machine.
//
// ── The one invariant ──────────────────────────────────────────────────────────────
// There is exactly ONE table (`KeyboardModel.bindings()`), and it drives BOTH:
//   1. live dispatch — a key press looks up the current state's bindings and runs the matching action, and
//   2. the Cmd+K guide overlay — the same bindings render as a grid of keycaps with their labels.
// Because both read the same table, the on-screen guide can never drift from what the keys actually do.
//
// ── States ─────────────────────────────────────────────────────────────────────────
// The app has many *distinct* keyboard states (year/month/week/day × selection/cursor/drawer/editing …).
// `AppKeyState` is the current LEAF state, DERIVED each time from the live engine + UI signals — it is
// never stored, so it can't get out of sync. We build it out one state at a time; unhandled states fall
// to `.idle` (no bindings). This file currently implements the "a timed event is selected" flow.
//
// ── Text editing defers to the field ────────────────────────────────────────────────
// When an inline editor / text field is first responder, macOS routes keys straight to it (the catcher
// isn't in the responder chain), so `handle` never runs for those — the field owns Enter/Esc/typing.
// Such states still LIST their keys here (empty actions) so the guide can show them.

import CalendarEngine
import CalendarGeometry
import SwiftUI

/// ── A normalized key, independent of view/state (mapped from the raw NSEvent by the catcher) ──
enum KeyToken: Equatable {
    case enter, space, escape, tab, backTab, left, right, up, down, delete, cmdS, cmdN, cmdT, cmdU, cmdL
    case cmdEqual, cmdMinus // ⌘= / ⌘− → zoom in / out (keeps the current focus)
    case cmdUp, cmdDown, cmdLeft, cmdRight // ⌘+arrows → move the selected event
    case optUp, optDown // ⌥↑ / ⌥↓ — guide display only (the note editor owns them: move line)
    case cmdB, cmdE, cmdJ // ⌘B/⌘E/⌘J — guide display only (the View-menu key equivalents own the keystroke)
    case shiftUp, shiftDown, shiftLeft, shiftRight // ⇧+arrows → resize the selected event
    case char(Character)

    /// Whether holding the key should keep firing (auto-repeat). Only the arrows step a value; the
    /// discrete keys (Enter/Space/Tab/Esc/Delete/…) fire once per press to avoid double-actions.
    var repeats: Bool {
        switch self {
        case .left, .right, .up, .down,
             .cmdUp, .cmdDown, .cmdLeft, .cmdRight,
             .shiftUp, .shiftDown, .shiftLeft, .shiftRight: true
        default: false
        }
    }

    /// The glyph shown on the keycap in the Cmd+K guide.
    var cap: String {
        switch self {
        case .enter: "return"
        case .space: "space"
        case .escape: "esc"
        case .tab: "tab"
        case .backTab: "⇧tab"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .delete: "delete"
        case .cmdS: "⌘S"
        case .cmdN: "⌘N"
        case .cmdT: "⌘T"
        case .cmdU: "⌘U"
        case .cmdL: "⌘L"
        case .cmdEqual: "⌘+"
        case .cmdMinus: "⌘−"
        case .optUp: "⌥↑"
        case .optDown: "⌥↓"
        case .cmdB: "⌘B"
        case .cmdE: "⌘E"
        case .cmdJ: "⌘J"
        case .cmdUp: "⌘↑"
        case .cmdDown: "⌘↓"
        case .cmdLeft: "⌘←"
        case .cmdRight: "⌘→"
        case .shiftUp: "⇧↑"
        case .shiftDown: "⇧↓"
        case .shiftLeft: "⇧←"
        case .shiftRight: "⇧→"
        case let .char(c): String(c).uppercased()
        }
    }
}

/// ── One row of the keymap: a key, what it does (`action`), and a human label for the guide ──
struct KeyBinding: Identifiable {
    let token: KeyToken
    let label: String
    let action: () -> Void
    var id: String {
        token.cap + label
    }

    init(_ token: KeyToken, _ label: String, _ action: @escaping () -> Void = {}) {
        self.token = token; self.label = label; self.action = action
    }
}

/// ── The current leaf state. Grown one at a time; `.idle` = nothing special (no bindings yet). ──
enum AppKeyState: Equatable {
    case idle
    case block // block cursor (default/home): navigate time cells, Space/Esc zoom
    case bandCursor // band cursor: a lane×day grid cell (⌘N creates a band there)
    case trackName // month view: a focused track NAME (Enter edits it)
    case trackNameEditing // its inline text field is open (the field owns the keys)
    case timedSelected // a timed event is selected in a detail view (Enter/Space/Escape)
    case timedTitleEditing // its inline title editor is open (the field owns the keys)
    case bandSelected // a band (multi-day) event is selected (Enter/Space/Escape)
    case bandTitleEditing // its inline title editor is open (the field owns the keys)
    case deadlineSelected // a deadline is selected (Space/Escape + ⌘↑/↓ nudge)
    case multiSelected // 2+ events selected → single-event ops are OFF; batch ops act on the set
    case drawerOpen // the event drawer is open, no field focused
    case drawerTitleEditing // the drawer's title field is focused (the field owns the keys)
    case drawerField(DrawerField) // a drawer field is keyboard-focused (Tab-cycled); sub-keys act on it
    case dashTodo // day view: the dashboard TODO list is focused (↑/↓ rows, Space toggles)
    case dashNote // day view: the daily NOTE is focused (Enter → edit)
    case dashNoteEditing // the daily NOTE editor has focus (the WebView owns the keys)

    /// Heading shown at the top of the Cmd+K guide.
    var title: String {
        switch self {
        case .idle: "Calendar"
        case .block: "Navigate"
        case .bandCursor: "Band cursor"
        case .trackName: "Track name"
        case .trackNameEditing: "Editing track name"
        case .timedSelected: "Event selected"
        case .timedTitleEditing: "Editing title"
        case .bandSelected: "Band selected"
        case .multiSelected: "Multiple selected"
        case .bandTitleEditing: "Editing title"
        case .deadlineSelected: "Deadline selected"
        case .drawerOpen: "Event drawer"
        case .drawerTitleEditing: "Drawer · editing title"
        case let .drawerField(f): "Drawer · " + f.label
        case .dashTodo: "Dashboard · to-dos"
        case .dashNote: "Daily note"
        case .dashNoteEditing: "Editing daily note"
        }
    }
}

/// ── The state machine: derives the state, exposes the keymap, and dispatches a pressed key. ──
/// Holds the engine + UI by reference and reads them LIVE, so a model built at render time still sees
/// current state when a key is pressed later.
@MainActor struct KeyboardModel {
    let engine: CalendarEngine
    let ui: CalendarUIState

    var state: AppKeyState {
        if engine.timedEditing {
            return .timedTitleEditing
        }
        if engine.bandEditing {
            return .bandTitleEditing
        }
        if engine.trackEditing {
            return .trackNameEditing
        }
        if ui.openEventId != nil {
            if ui.drawerTitleEditing {
                return .drawerTitleEditing
            } // title in text-editing mode
            switch ui.drawerFocus {
            case .none: return .drawerOpen
            case let .some(f): return .drawerField(f) // ring focus (includes .title as a ring)
            }
        }
        if engine.multiSelectActive {
            return .multiSelected
        } // 2+ selected → batch state (single ops off)
        if engine.selectedIsTimed {
            return .timedSelected
        }
        if engine.selectedIsBand {
            return .bandSelected
        }
        if engine.selectedIsDeadline {
            return .deadlineSelected
        }
        switch engine.cursor.dashStop { // day-view dashboard Tab stops (checked before the plain cursors)
        case .todo: return .dashTodo
        case .note: return engine.cursor.dashNoteEditing ? .dashNoteEditing : .dashNote
        case .none: break
        }
        if engine.cursor.trackNameCursor != nil {
            return .trackName
        }
        if engine.cursor.bandCursorActive {
            return .bandCursor
        }
        return .block // nothing selected → the block cursor is home
    }

    /// The ⌘↑/⌘↓ move bindings, shared by every "… selected" state (they mean lane-shift for bands and
    /// ±15-minutes for timed / deadlines — the engine dispatches by type). Available in all views.
    private var verticalMoveBindings: [KeyBinding] {
        [
            KeyBinding(.cmdUp, "Move up") { engine.nudgeVertical(-1) },
            KeyBinding(.cmdDown, "Move down") { engine.nudgeVertical(1) },
            KeyBinding(.cmdLeft, "Move ◂") { engine.nudgeHorizontal(-1) },
            KeyBinding(.cmdRight, "Move ▸") { engine.nudgeHorizontal(1) },
        ]
    }

    /// Plain arrows navigate BETWEEN events (event cursor). Currently the day view (↑/↓ by time); the
    /// 2-D focus engine for year/month/week is a later increment.
    private var eventNavBindings: [KeyBinding] {
        [
            KeyBinding(.up, "↑ event") { engine.navigateEvent(0, -1) },
            KeyBinding(.down, "↓ event") { engine.navigateEvent(0, 1) },
            KeyBinding(.left, "← event") { engine.navigateEvent(-1, 0) },
            KeyBinding(.right, "→ event") { engine.navigateEvent(1, 0) },
        ]
    }

    /// Delete on a selected event → raise the custom confirm dialog (never an immediate delete). Shared by
    /// the timed / band / deadline selected states; the hotkey monitor has the same fallback for safety.
    private var deleteBinding: KeyBinding {
        KeyBinding(.delete, "Delete…") {
            if let t = engine.deleteTargetForSelection() {
                ui.requestDelete(
                    id: t.id,
                    occKey: t.occKey,
                    recurring: t.recurring,
                    imported: t.imported,
                    alreadyHidden: t.alreadyHidden,
                    kind: engine.kind(of: t.id) ?? .timed,
                    viaGhost: t.viaGhost,
                    atBase: t.atBase
                )
            }
        }
    }

    /// Enter-to-select from the BLOCK cursor — week/day only (per spec); year/month block Enter is a no-op
    /// (the band cursor gets its own Enter binding inline, valid in every view).
    private var selectBinding: [KeyBinding] {
        (engine.isWeekLevel || engine.isDayLevel)
            ? [KeyBinding(.enter, "Select event") { engine.selectFromCursor() }] : []
    }

    /// ⌘= / ⌘− zoom in / out from ANY navigation mode, keeping the current focus (event stays selected).
    private var zoomBindings: [KeyBinding] {
        [
            KeyBinding(.cmdEqual, "Zoom in") { engine.cmdZoomIn() },
            KeyBinding(.cmdMinus, "Zoom out") { engine.cmdZoomOut() },
            KeyBinding(.cmdT, "Go to today") { engine.goToToday() },
        ]
    }

    /// ⌘B / ⌘E — dashboard tab focus (display only; the View-menu key equivalents run the action).
    /// Listed wherever the dashboard is reachable (month/week/day — never at year).
    private var dashHotkeyBindings: [KeyBinding] {
        engine.chrome.level >= 1
            ? [KeyBinding(.cmdB, "To-do list"), KeyBinding(.cmdE, "Note editor"),
               KeyBinding(.cmdJ, "Projects")]
            : []
    }

    /// Tab cycles the cursor DOMAIN. For now: event cursor → block cursor (band cursor is a later step).
    private var eventTabBindings: [KeyBinding] {
        [
            KeyBinding(.tab, "Block cursor") { engine.tabCursor(true) },
            KeyBinding(.backTab, "Block cursor") { engine.tabCursor(false) },
        ]
    }

    /// The keymap for the current state — the single source of truth for dispatch AND the guide.
    func bindings() -> [KeyBinding] {
        switch state {
        case .timedSelected:
            return [
                KeyBinding(.enter, "Edit title") {
                    if let s = engine.selectedId {
                        engine.editTimed(s)
                    }
                },
                KeyBinding(.space, "Open drawer") {
                    if let s = engine.selectedId {
                        ui.openEventId = sourceId(of: s)
                    }
                },
                KeyBinding(.escape, "Deselect") { engine.deselect() },
                KeyBinding(.cmdU, "Toggle promote") {
                    if let s = engine.selectedId {
                        engine.togglePromote(s)
                    }
                },
                KeyBinding(.shiftUp, "Shrink") { engine.resizeSelected(0, -1) },
                KeyBinding(.shiftDown, "Extend") { engine.resizeSelected(0, 1) },
            ] + [deleteBinding] + verticalMoveBindings + eventNavBindings + eventTabBindings + zoomBindings
        case .timedTitleEditing:
            // The inline TextField owns these keys (Enter = commit, Esc = cancel) — listed for the guide.
            return [
                KeyBinding(.enter, "Done"),
                KeyBinding(.escape, "Cancel"),
            ]
        case .bandSelected:
            return [
                KeyBinding(.enter, "Edit title") {
                    if let s = engine.selectedId {
                        engine.editBand(sourceId(of: s))
                    }
                },
                KeyBinding(.space, "Open drawer") {
                    if let s = engine.selectedId {
                        ui.openEventId = sourceId(of: s)
                    }
                },
                KeyBinding(.escape, "Deselect") { engine.deselect() },
                KeyBinding(.shiftLeft, "Shrink") { engine.resizeSelected(-1, 0) },
                KeyBinding(.shiftRight, "Extend") { engine.resizeSelected(1, 0) },
            ] + [deleteBinding] + verticalMoveBindings + eventNavBindings + eventTabBindings + zoomBindings
        case .bandTitleEditing:
            // The inline TextField owns these keys — listed for the guide.
            return [
                KeyBinding(.enter, "Done"),
                KeyBinding(.escape, "Cancel"),
            ]
        case .deadlineSelected:
            return [
                KeyBinding(.space, "Open drawer") {
                    if let s = engine.selectedId {
                        ui.openEventId = sourceId(of: s)
                    }
                },
                KeyBinding(.escape, "Deselect") { engine.deselect() },
            ] + [deleteBinding] + verticalMoveBindings + eventNavBindings + eventTabBindings + zoomBindings
        case .multiSelected:
            // Batch ops over the whole selection. Single-event ops (drawer, nav, inline rename) are OFF.
            return [
                KeyBinding(.escape, "Deselect all") { engine.deselectAll() },
                KeyBinding(.enter, "Rename all…") { ui.startBatchRename() },
                KeyBinding(.delete, "Delete selected…") { ui.requestBatchDelete(engine) },
                KeyBinding(.cmdUp, "Move up") { engine.batchMove(dx: 0, dy: -1) },
                KeyBinding(.cmdDown, "Move down") { engine.batchMove(dx: 0, dy: 1) },
                KeyBinding(.cmdLeft, "Move ◂") { engine.batchMove(dx: -1, dy: 0) },
                KeyBinding(.cmdRight, "Move ▸") { engine.batchMove(dx: 1, dy: 0) },
                KeyBinding(.shiftUp, "Shrink") { engine.batchResize(dx: 0, dy: -1) },
                KeyBinding(.shiftDown, "Extend") { engine.batchResize(dx: 0, dy: 1) },
                KeyBinding(.shiftLeft, "Shrink") { engine.batchResize(dx: -1, dy: 0) },
                KeyBinding(.shiftRight, "Extend") { engine.batchResize(dx: 1, dy: 0) },
            ] + zoomBindings
        case .drawerOpen:
            return [
                KeyBinding(.enter, "Edit title") { ui.drawerFocus = .title; ui.drawerTitleEditing = true },
                KeyBinding(.tab, "Focus fields") { ui.drawerFocus = ui.drawerFieldOrder.first },
                KeyBinding(.backTab, "Focus fields") { ui.drawerFocus = ui.drawerFieldOrder.last },
                KeyBinding(.delete, "Delete…") { ui.postDrawer(.confirmDelete) },
                KeyBinding(.space, "Close drawer") { ui.openEventId = nil },
                KeyBinding(.escape, "Close drawer") { ui.openEventId = nil },
            ]
        case .drawerTitleEditing:
            // The drawer's TextField owns these (onSubmit / onExitCommand) — listed for the guide.
            return [
                KeyBinding(.enter, "Done"),
                KeyBinding(.escape, "Done"),
            ]
        case let .drawerField(f):
            // Field-specific sub-keys first, then the shared Tab / Shift-Tab / Escape navigation.
            var b: [KeyBinding] = []
            switch f {
            case .title:
                b.append(KeyBinding(.enter, "Edit title") { ui.postDrawer(.activate) })
            case .date, .start, .end:
                b.append(KeyBinding(.enter, "Edit") { ui.postDrawer(.activate) })
            case .color:
                b.append(KeyBinding(.left, "Prev color") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "Next color") { ui.postDrawer(.right) })
            case .config:
                b.append(KeyBinding(.enter, "Expand / collapse") { ui.postDrawer(.activate) })
            case .cfgTags:
                b.append(KeyBinding(.enter, "Add tag") { ui.postDrawer(.activate) })
            case .cfgRepeat:
                b.append(KeyBinding(.left, "Prev") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "Next") { ui.postDrawer(.right) })
            case .repEvery:
                b.append(KeyBinding(.left, "Fewer") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "More") { ui.postDrawer(.right) })
            case .repDays:
                b.append(KeyBinding(.left, "Prev day") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "Next day") { ui.postDrawer(.right) })
                b.append(KeyBinding(.space, "Toggle day") { ui.postDrawer(.activate) })
            case .repUntil:
                b.append(KeyBinding(.left, "Toggle") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "Toggle") { ui.postDrawer(.right) })
            case .repUntilDate:
                b.append(KeyBinding(.enter, "Edit") { ui.postDrawer(.activate) })
            case .cfgPromote:
                b.append(KeyBinding(.left, "Change") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "Change") { ui.postDrawer(.right) })
            case .promoteLane:
                b.append(KeyBinding(.left, "Prev lane") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "Next lane") { ui.postDrawer(.right) })
            case .cfgTimezone:
                b.append(KeyBinding(.left, "Prev zone") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "Next zone") { ui.postDrawer(.right) })
            case .notes:
                b.append(KeyBinding(.enter, "Edit notes") { ui.postDrawer(.activate) })
            case .noteScope:
                b.append(KeyBinding(.left, "All events") { ui.postDrawer(.left) })
                b.append(KeyBinding(.right, "This event") { ui.postDrawer(.right) })
            case .delete:
                b.append(KeyBinding(.enter, "Delete…") { ui.postDrawer(.activate) })
            }
            b.append(KeyBinding(.tab, "Next field") { ui.drawerFocus = ui.fieldAfter(f) })
            b.append(KeyBinding(.backTab, "Prev field") { ui.drawerFocus = ui.fieldBefore(f) })
            b.append(KeyBinding(.delete, "Delete…") { ui.postDrawer(.confirmDelete) }) // Delete key → confirm dialog
            // Escape from a Configuration child returns to its header; from any other field, to the body.
            if f.isConfigChild {
                b.append(KeyBinding(.escape, "Back to config") { ui.drawerFocus = .config })
            } else {
                b.append(KeyBinding(.escape, "Back") { ui.drawerFocus = nil })
            }
            return b
        case .block:
            // Block cursor. Arrow semantics are view-dependent (the engine dispatches by level); year
            // view uses ↑/↓ = month. Space/⌘= zoom in (with placement); Esc/⌘− zoom out.
            return [
                KeyBinding(.up, "Prev") { engine.blockArrow(dx: 0, dy: -1) },
                KeyBinding(.down, "Next") { engine.blockArrow(dx: 0, dy: 1) },
                KeyBinding(.left, "◂") { engine.blockArrow(dx: -1, dy: 0) },
                KeyBinding(.right, "▸") { engine.blockArrow(dx: 1, dy: 0) },
                KeyBinding(.space, "Zoom in") { engine.blockZoomIn() },
                KeyBinding(.escape, "Zoom out") { engine.onEscape() },
                KeyBinding(.cmdN, "New event") { engine.createEventAtBlock() },
                KeyBinding(.cmdL, "New deadline") { engine.createDeadlineViaShortcut() },
                // Tab cycles block ⇄ event (the band lanes are the block cursor's arrow-reachable
                // sub-state, not a Tab stop of their own).
                KeyBinding(.tab, "Select event") { engine.tabCursor(true) },
                KeyBinding(.backTab, "Select event") { engine.tabCursor(false) },
            ] + selectBinding + dashHotkeyBindings + zoomBindings
        case .bandCursor:
            return [
                KeyBinding(.up, "Prev lane") { engine.bandArrow(dx: 0, dy: -1) },
                KeyBinding(.down, "Next lane") { engine.bandArrow(dx: 0, dy: 1) },
                KeyBinding(.left, "◂") { engine.bandArrow(dx: -1, dy: 0) },
                KeyBinding(.right, "▸") { engine.bandArrow(dx: 1, dy: 0) },
                KeyBinding(.space, "Zoom in") { engine.blockZoomIn() },
                KeyBinding(.escape, "Zoom out") { engine.onEscape() },
                KeyBinding(.cmdN, "New band") { engine.createBandAtCursor() },
                KeyBinding(.tab, "Select event") { engine.tabCursor(true) },
                KeyBinding(.backTab, "Select event") { engine.tabCursor(false) },
                KeyBinding(.enter, "Select event") { engine.selectFromCursor() },
            ] + zoomBindings
        case .trackName:
            return [
                KeyBinding(.enter, "Edit name") { engine.editFocusedTrackName() },
                KeyBinding(.space, "Zoom in") { engine.blockZoomIn() },
                KeyBinding(.escape, "Zoom out") { engine.onEscape() },
                KeyBinding(.tab, "Next") { engine.tabCursor(true) },
                KeyBinding(.backTab, "Prev") { engine.tabCursor(false) },
            ] + zoomBindings
        case .trackNameEditing:
            // The inline TextField owns these keys (onSubmit / onExitCommand) — listed for the guide.
            return [
                KeyBinding(.enter, "Done"),
                KeyBinding(.escape, "Done"),
            ]
        case .dashTodo:
            // Day-view dashboard TODO list: a row cursor lives inside the WebView; keys drive it via
            // the engine's onDashCommand bridge.
            return [
                KeyBinding(.up, "↑ item") { engine.dashMove(-1) },
                KeyBinding(.down, "↓ item") { engine.dashMove(1) },
                KeyBinding(.left, "Fold subs") { engine.dashFold(false) },
                KeyBinding(.right, "Unfold subs") { engine.dashFold(true) },
                KeyBinding(.space, "Toggle done") { engine.dashActivate() },
                KeyBinding(.enter, "Open") { engine.dashOpen() },
                KeyBinding(.escape, "Zoom out") { engine.onEscape() },
                // The dashboard stops left the Tab cycle — Tab hands focus back to the timeline;
                // ⌘E (the menu key equivalent) flips to the NOTE tab.
                KeyBinding(.tab, "Timeline cursor") { engine.tabCursor(true) },
                KeyBinding(.backTab, "Timeline cursor") { engine.tabCursor(false) },
                KeyBinding(.cmdE, "Note editor"),
            ] + zoomBindings
        case .dashNote:
            return [
                KeyBinding(.enter, "Edit note") { engine.dashActivate() },
                KeyBinding(.escape, "Zoom out") { engine.onEscape() },
                KeyBinding(.tab, "Timeline cursor") { engine.tabCursor(true) },
                KeyBinding(.backTab, "Timeline cursor") { engine.tabCursor(false) },
                KeyBinding(.cmdB, "To-do list"),
            ] + zoomBindings
        case .dashNoteEditing:
            // The daily-note WebView editor owns these (CodeMirror bindings) — listed for the guide.
            return [
                KeyBinding(.tab, "Indent"),
                KeyBinding(.backTab, "Outdent"),
                KeyBinding(.optUp, "Move line up"),
                KeyBinding(.optDown, "Move line down"),
                KeyBinding(.cmdS, "Preview"),
                KeyBinding(.escape, "Done"),
            ]
        case .idle:
            return []
        }
    }

    /// Run the binding for `token` if the current state has one. Returns whether it was handled (so the
    /// catcher can consume the event; unhandled keys fall through to the existing behavior / native field).
    @discardableResult func handle(_ token: KeyToken) -> Bool {
        for b in bindings() where b.token == token {
            b.action(); return true
        }
        return false
    }
}

/// ── The Cmd+K guide overlay ─────────────────────────────────────────────────────────
/// Fades in while Cmd+K is held, out on release. Shows the current state's bindings as a grid of
/// keycaps + labels. Reads the SAME `bindings()` the dispatcher uses.
struct KeyGuideOverlay: View {
    let model: KeyboardModel
    let theme: Theme
    private let maxCols = 5 // wrap to a new row past this, so a many-key panel doesn't run off-screen

    var body: some View {
        let binds = model.bindings()
        // Rows of at most `maxCols` keycaps → the panel's WIDTH scales with the number of keys (up to
        // the cap, then it wraps). `.fixedSize()` below makes the panel hug this content instead of
        // stretching to fill the screen.
        let cols = max(1, min(binds.count, maxCols))
        let rows = stride(from: 0, to: binds.count, by: cols).map { Array(binds[$0 ..< min($0 + cols, binds.count)]) }
        VStack(spacing: 14) {
            Text(model.state.title.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(1.5)
                .foregroundStyle(theme.textMuted)
            if binds.isEmpty {
                Text("No shortcuts here").font(.system(size: 13)).foregroundStyle(theme.textMuted)
            } else {
                VStack(spacing: 14) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 14) {
                            ForEach(row) { keycap($0) }
                        }
                    }
                }
            }
        }
        .padding(24)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16)) // frosted glass, like the events
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .fixedSize() // hug the content (don't stretch to the overlay); the overlay centers it
    }

    private func keycap(_ b: KeyBinding) -> some View {
        VStack(spacing: 6) {
            Text(b.token.cap)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text)
                .frame(minWidth: 40, minHeight: 30)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.highlight.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.sep.opacity(0.6), lineWidth: 1))
            Text(b.label)
                .font(.system(size: 10)).foregroundStyle(theme.textMuted)
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 92)
        }
    }
}
