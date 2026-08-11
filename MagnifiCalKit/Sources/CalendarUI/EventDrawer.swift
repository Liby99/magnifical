// Detail drawer — a floating, rounded native "card" on the trailing edge (Apple sidebar look).
// Content is a compact, unified configuration form ported from the web drawer: title, when
// (date/time per kind), color, tags, repeat, and promote/lane — all as native segmented
// controls / pickers. The markdown notes editor and imported/detach actions are deferred.

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

@MainActor
@Observable
public final class CalendarUIState {
    public var openEventId: String?
    /// Set (before openEventId) when a TODO row opens the drawer: land the notes area in the
    /// EDITOR at the row's source line — in the occurrence ("This Event") note's scope when
    /// the todo lives there. Consumed once by the drawer's load(); canvas opens leave it nil.
    public struct OpenNoteTarget {
        public var line: Int
        public var occurrenceKey: String?
    }

    public var openNoteTarget: OpenNoteTarget?

    /// PROJ row-menu Delete awaiting its confirm: item text + the yes-action. Hosted by the
    /// window-level DialogOverlay so the blur covers the WHOLE window, not just the panel.
    public struct PendingTodoDelete {
        public var text: String
        public var confirm: () -> Void
    }

    public var pendingTodoDelete: PendingTodoDelete?
    public var editingTrack: TrackEdit? // inline track-name editor target
    public var editingBand: BandEdit? // inline band-title editor target
    public var editingTimed: TimedEdit? // inline timed-event-title editor target
    public var showKeyGuide: Bool = false // Cmd+K shortcut-guide overlay is held open
    public var showTutorial: Bool = false // the onboarding GIF-carousel overlay is up
    public var tutorialIndex: Int = 0 // current carousel slide
    public var drawerFocus: DrawerField? // which drawer control the keyboard has focused (nil = drawer body)
    public var drawerTitleEditing: Bool = false // the title field is in text-editing mode (vs. ring focus)
    public var selectTitleOnOpen: Bool =
        false // a freshly-created item (e.g. deadline "+") → focus + select-all the title
    /// True while a native inline editor (the date/time NSDatePicker) is active. The key monitor treats
    /// this like text-input focus: it passes ALL keys — including Tab — to the native field so it cycles
    /// its own components, and the drawer-level Tab cycle does NOT advance until Enter/Esc commits.
    public var drawerFieldEditing: Bool = false
    /// The Tab cycle for the open item — published by the drawer on load (it depends on the item kind,
    /// e.g. bands have no start/end *time*). Both the drawer and the keyboard model read it.
    public var drawerFieldOrder: [DrawerField] = []
    // One-shot action channel: the keyboard model (which lives outside the drawer, in the key monitor)
    // posts a semantic action here; the drawer observes `drawerPulse` and runs it against its own state.
    // `drawerPulse` always increments so repeated identical actions (e.g. Right, Right) still fire.
    public var drawerPulse: Int = 0
    public var drawerActionKind: DrawerActionKind = .none
    // The custom delete-confirm dialog, when up. Shown as an app-level overlay so BOTH the drawer trash
    // button and the hotkey (Delete on a selected event, drawer closed) present the same modal. `focus` is
    // the keyboard-focused button (index into `choices`); the key monitor drives it while this is non-nil.
    public var pendingDelete: PendingDelete?
    /// A one-button informational modal (e.g. "Printing Week view is not supported right now."). Same
    /// blocking treatment as the delete dialog: canvas blur + input gate; OK/Enter/Esc dismiss.
    public var notice: String?
    // Multi-select batch UI: a batch-delete confirm summary, and the floating "rename all" field.
    public var pendingBatchDelete: CalendarEngine.BatchDeleteSummary?
    public var batchRenaming = false
    public var batchRenameText = ""
    public var batchRenameTouched = false // any live rename happened → Cancel/Esc must restore
    public var batchRenameOriginal: [String: String] = [:] // pre-rename titles (see batchTitlesSnapshot)
    // Multiple calendars (File menu): a name prompt (New / Rename) + a remove confirm.
    public enum CalendarPrompt: Equatable { case new, rename }
    public var calendarPrompt: CalendarPrompt?
    public var calendarPromptText = ""
    public var pendingCalendarRemove = false
    /// Right-click event menu: the target box + its anchor rect (view coords). Non-nil = callout up.
    public struct EventMenuTarget: Equatable {
        public var id: String
        public var anchor: CGRect
        public init(id: String, anchor: CGRect) {
            self.id = id; self.anchor = anchor
        }
    }

    public var eventMenu: EventMenuTarget?
    /// Right-click on EMPTY space: the classified spot + pointer anchor (view coords).
    public struct SpaceMenuTarget: Equatable {
        public var spot: CalendarEngine.EmptySpot
        public var anchor: CGRect
        public init(spot: CalendarEngine.EmptySpot, anchor: CGRect) {
            self.spot = spot; self.anchor = anchor
        }
    }

    public var spaceMenu: SpaceMenuTarget?
    /// One-shot: the next drawer open expands Configuration (the menu's "Repeat…" row).
    public var openRepeatOnOpen = false
    public init() {}

    /// Raise the batch-delete confirm for the current multi-selection (no-op if nothing deletable).
    public func requestBatchDelete(_ engine: CalendarEngine) {
        let s = engine.batchDeleteSummary()
        if !s.isEmpty {
            pendingBatchDelete = s
        }
    }

    /// Open the floating "rename all" field (typing sets every selected title live).
    public func startBatchRename() {
        batchRenameText = ""; batchRenameTouched = false; batchRenaming = true
    }

    /// Raise the delete-confirm dialog for an event. No button is focused yet (no ring shows until the
    /// user arrows); Enter before that confirms the primary choice.
    public func requestDelete(id: String, occKey: String, recurring: Bool, imported: Bool,
                              alreadyHidden: Bool = false, kind: CalendarEngine.ItemKind = .timed,
                              viaGhost: Bool = false, atBase: Bool = false) {
        pendingDelete = PendingDelete(id: id, occKey: occKey, recurring: recurring, imported: imported,
                                      alreadyHidden: alreadyHidden, kind: kind, viaGhost: viaGhost,
                                      atBase: atBase, focus: nil)
    }

    /// Move the focus ring. The first arrow reveals it by stepping off the (implicit) primary choice.
    public func moveDeleteFocus(_ d: Int) {
        guard var pd = pendingDelete else { return }
        let n = pd.choices.count
        let base = pd.focus ?? pd.primaryIndex
        pd.focus = (base + d + n) % n
        pendingDelete = pd
    }

    /// Post a keyboard action into the open drawer (see `drawerPulse`).
    public func postDrawer(_ kind: DrawerActionKind) {
        drawerActionKind = kind; drawerPulse += 1
    }

    /// The field after / before `f` in the current Tab cycle (wrapping).
    public func fieldAfter(_ f: DrawerField) -> DrawerField? {
        guard let i = drawerFieldOrder.firstIndex(of: f) else { return drawerFieldOrder.first }
        return drawerFieldOrder[(i + 1) % drawerFieldOrder.count]
    }

    public func fieldBefore(_ f: DrawerField) -> DrawerField? {
        guard let i = drawerFieldOrder.firstIndex(of: f) else { return drawerFieldOrder.last }
        return drawerFieldOrder[(i - 1 + drawerFieldOrder.count) % drawerFieldOrder.count]
    }
}

/// One button in the delete-confirm dialog. A non-recurring event offers Cancel + Delete; a recurring
/// one offers the three web-matching scopes plus Cancel.
public enum DeleteChoice: Equatable {
    case cancel, thisEvent, thisAndFuture, deleteAll, hide
    case removeFromLane // promoted ghost bar → clear the promotion (series-level), keep the item
    case hideOccurrence // imported recurring → hide just this occurrence (per-occurrence overlay)
    case unhide // already-hidden imported (revealed) → bring it back
    /// Button label; `deleteAll` reads "Delete" for a lone event, "All Events" for a series.
    public func label(recurring: Bool) -> String {
        switch self {
        case .cancel: "Cancel"
        case .thisEvent: "This Event"
        case .thisAndFuture: "This & Future"
        case .deleteAll: recurring ? "All Events" : "Delete"
        case .hide: recurring ? "Hide Series" : "Hide"
        case .removeFromLane: "Remove from Lane"
        case .hideOccurrence: "Hide Occurrence"
        case .unhide: "Unhide"
        }
    }

    /// Red (destructive) styling: the item disappears from the calendar. Lane removal and unhide
    /// leave it visible, so they render as plain actions.
    public var isDestructive: Bool {
        switch self {
        case .cancel, .removeFromLane, .unhide: false
        default: true
        }
    }
}

/// The live delete-confirm dialog's state. Immutable target + a keyboard `focus` that is nil until the
/// user first arrows (so no focus ring shows on open); Enter with no focus falls back to `primaryIndex`.
public struct PendingDelete: Equatable {
    public let id: String // source event id
    public let occKey: String // focused occurrence-box id (for This-Event / This-&-Future)
    public let recurring: Bool
    public let imported: Bool // an imported (read-only) event → Hide instead of Delete
    public let alreadyHidden: Bool // imported + already hidden (revealed via View menu) → Unhide/Cancel
    public var kind: CalendarEngine.ItemKind = .timed // drives the noun in the confirm text (deadline vs event)
    public var viaGhost: Bool = false // the clicked box is a promoted lane bar → offer Remove from Lane first
    public var atBase: Bool = false // recurring + base occurrence → This & Future ≡ series, so it's dropped
    public var focus: Int? // nil = not navigating yet (no ring)
    private var noun: String {
        kind == .deadline ? "deadline" : "event"
    }

    /// The systematic action matrix — derived from the DeleteTarget dimensions, one row per case:
    ///   local plain            → Delete
    ///   local recurring @base  → This Event · All Events
    ///   local recurring @occ   → This Event · This & Future · All Events
    ///   imported plain         → Hide
    ///   imported recurring     → Hide Occurrence · Hide Series
    ///   any of these via ghost → Remove from Lane first (and it's the Enter default)
    ///   imported, hidden       → Unhide
    public var choices: [DeleteChoice] {
        if alreadyHidden {
            return [.cancel, .unhide]
        }
        var out: [DeleteChoice] = [.cancel]
        if viaGhost {
            out.append(.removeFromLane)
        }
        if imported {
            if recurring {
                out.append(.hideOccurrence)
            }
            out.append(.hide)
        } else if recurring {
            out.append(.thisEvent)
            if !atBase {
                out.append(.thisAndFuture)
            }
            out.append(.deleteAll)
        } else {
            out.append(.deleteAll)
        }
        return out
    }

    /// The default confirm target — the first non-cancel choice (Hide / Delete / This Event). Enter lands
    /// here before any arrow. Clamped so an info-only dialog (Cancel alone) doesn't index past its end.
    public var primaryIndex: Int {
        min(1, choices.count - 1)
    }

    public var title: String {
        if alreadyHidden {
            return "This imported \(noun) is already hidden"
        }
        if viaGhost {
            return "Remove the promoted bar, or \(imported ? "hide" : "delete") the \(noun)?"
        }
        if imported {
            return "This is an imported \(noun); Hide the \(noun)?"
        }
        return recurring ? "Delete recurring \(noun)?" : "Delete this \(noun)?"
    }

    /// A secondary note under the title, explaining the non-obvious action on each row.
    public var note: String? {
        if alreadyHidden {
            return "You can't delete an imported \(noun) — but you can Unhide it. To re-hide revealed hidden events, turn off Menu Bar ▸ View ▸ Show Hidden Imported Events."
        }
        if viaGhost {
            return "Remove from Lane un-promotes the \(recurring ? "whole series" : noun) — the \(noun) itself stays on the calendar."
        }
        if imported && recurring {
            return "Hide Occurrence hides just this one; Hide Series hides every occurrence. Both survive re-imports (reveal via Menu Bar ▸ View ▸ Show Hidden Imported Events)."
        }
        return nil
    }
}

/// A keyboard-focusable control in the event drawer. The concrete Tab cycle for a given item is
/// published in `CalendarUIState.drawerFieldOrder` (it varies by kind). `.date/.start/.end` are the
/// three "when" parts (for bands, start/end are the start/end *day*; deadlines have date + one time).
public enum DrawerField: Hashable {
    case title, date, start, end, color, config, notes, noteScope, delete
    case cfgRepeat, cfgPromote,
         cfgTimezone // controls inside Configuration (only in the cycle while it's open)
    case repEvery, repDays, repUntil, repUntilDate // repeat sub-controls (shown conditionally by kind)
    case promoteLane // the lane picker that appears when Promote is on (timed / deadline)
}

extension DrawerField {
    /// Human label for the Cmd+K guide heading.
    var label: String {
        switch self {
        case .title: "title"
        case .date: "date"
        case .start: "start time"
        case .end: "end time"
        case .color: "color"
        case .config: "configuration"
        case .notes: "notes"
        case .noteScope: "note scope"
        case .delete: "delete"
        case .cfgRepeat: "repeat"
        case .cfgPromote: "promote / lane"
        case .cfgTimezone: "timezone"
        case .repEvery: "every N weeks"
        case .repDays: "weekdays"
        case .repUntil: "until"
        case .repUntilDate: "until date"
        case .promoteLane: "lane"
        }
    }

    /// Is this one of the controls nested inside Configuration? (Escape returns to the config header.)
    var isConfigChild: Bool {
        switch self {
        case .cfgRepeat, .cfgPromote, .repEvery, .repDays, .repUntil, .repUntilDate, .promoteLane,
             .cfgTimezone: true
        default: false
        }
    }
}

/// A one-shot keyboard action the drawer executes. `activate`/`left`/`right` act on the focused field;
/// `confirmDelete` is global to the drawer (the Delete key → the trash button's confirmation dialog).
public enum DrawerActionKind { case none, activate, left, right, confirmDelete }

/// Collects each drawer field's frame (as an Anchor) so ONE dashed ring can slide over the focused one
/// — the same visual language as the calendar's block/band/event cursors (see CursorRing).
private struct DrawerRingAnchors: PreferenceKey {
    static let defaultValue: [DrawerField: Anchor<CGRect>] = [:]
    static func reduce(value: inout [DrawerField: Anchor<CGRect>], nextValue: () -> [DrawerField: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    /// Mark this view as drawer field `field`'s focus target (its bounds feed the sliding ring).
    func drawerRingAnchor(_ field: DrawerField) -> some View {
        anchorPreference(key: DrawerRingAnchors.self, value: .bounds) { [field: $0] }
    }
}

/// Target for the inline track-name editor: which month + track, and where (geometry rect).
public struct TrackEdit: Equatable { public var month: Int; public var track: Int; public var rect: CGRect }
/// Target for the inline band-title editor: which band id, and where (geometry rect).
public struct BandEdit: Equatable { public var id: String; public var rect: CGRect }
/// Target for the inline timed-event-title editor: which (source) event id, and where (geometry rect).
public struct TimedEdit: Equatable { public var id: String; public var rect: CGRect }

private enum ItemKind2 { case timed, band, deadline }
private enum WhenField: Hashable { case date, start, end } // which "when" part is being edited inline
private enum NoteScope: Hashable { case series, occurrence } // recurring: shared note vs this-occurrence note
private let DOW = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]

/// A wrapping flow layout: places subviews left→right, wrapping to a new row when the next one
/// wouldn't fit the proposed width. Used so tag pills reflow onto multiple rows.
private struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW {
                widest = max(widest, x - spacing); x = 0; y += rowH + lineSpacing; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX; y += rowH + lineSpacing; rowH = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

struct EventDrawer: View {
    let engine: CalendarEngine
    let id: String
    /// Read-only external event (Apple Calendar): title/time/color are vendor-owned — only local
    /// overlays (tags, notes, promote-to-band) are editable here; edit the rest in Calendar.app.
    private var imported: Bool {
        engine.isImported(id)
    }

    @Binding var width: CGFloat
    let containerWidth: CGFloat // window width — the drawer may not grow past it
    let theme: Theme
    let onClose: () -> Void
    var ui: CalendarUIState // keyboard focus target (ui.drawerFocus) — kept in 2-way sync
    var refocus: () -> Void = {} // return first-responder to the calendar canvas on field blur
    // GIF-recording only: the DemoController streams note text here (typed live into the editor) and drives
    // the edit/preview toggle, so the markdown-notes scene shows real typing + render. No-op otherwise.
    var demoNoteFeed: String = ""
    var demoNotePreview: Bool = false
    // …and the recurring scene's cues: expand the Configuration section, and apply a repeat rule through
    // the drawer (updates the pickers AND commits, exactly like the user choosing it).
    var demoConfigOpen: Int = 0
    var demoRepeatFeed: Repeat?

    @FocusState private var fieldFocus: DrawerField? // the keyboard-focused drawer control (mirrors ui.drawerFocus)
    @State private var kind: ItemKind2 = .timed
    @State private var title = ""
    @State private var titleOriginal = "" // title at edit-start — restored if left blank
    @State private var color = "blue"
    @State private var resizeStart: CGFloat?
    @State private var resizeHover = false
    @State private var whenEditing: WhenField? // which "when" part currently shows its editor
    @FocusState private var whenFocus: WhenField? // focuses the shown editor
    @State private var repDayCursor = 0 // keyboard cursor across the 7 weekday buttons (repDays)
    @FocusState private var untilFocused: Bool // the "until" date field is keyboard-editing
    @State private var notesFocusPulse = 0 // bump → focus the notes editor (keyboard)
    @State private var noteSession = NoteEditSession() // created:-stamps on mode-toggle/scope flips
    @State private var noteEditLine: Int? // ⌘-click a preview line → edit focused at that line
    /// Fixed native date-field height (the text parts reserve it so activating a field doesn't reflow).
    /// A live measurement churns @State mid-entrance-transition, which makes the "when" row snap to its
    /// destination instead of sliding with the drawer — so it's a constant, tunable if a field clips.
    private let whenRowH: CGFloat = 22
    // when (mirrors the item; re-synced from the engine after each edit)
    @State private var itemYear = 2026
    @State private var month = 0
    @State private var day = 1
    @State private var start: CGFloat = 9
    @State private var end: CGFloat = 10
    @State private var startDay = 1
    @State private var endDay = 1
    @State private var track = 0
    @State private var hour: CGFloat = 12
    // config
    @State private var rep = Repeat(kind: "none")
    @State private var promote: Int?
    @State private var configOpen = false // the Configuration disclosure (collapsed by default)
    @State private var notes = "" // series note (all events)
    @State private var occNote = "" // this-occurrence note (recurring)
    @State private var occKey = "" // focused occurrence box id (key for occNote)
    @State private var noteScope: NoteScope = .series
    @State private var notesMode: NotesMode = .edit
    @State private var settled = false // true once the slide-in finishes → fade in native controls
    // Recurring band: the CURRENT occurrence's date range (read-only) + the base/first occurrence's start
    // date (the "Started …" jump target). `onBaseOccurrence` = the drawer is already on the first one.
    @State private var occStart: YMD?
    @State private var occEnd: YMD?
    @State private var baseStart: YMD?
    @State private var onBaseOccurrence = false

    private var recurring: Bool {
        rep.kind != "none"
    }

    /// A recurring band shows its occurrence dates read-only (no Tab stop) + a jump-to-first button.
    private var recurringBand: Bool {
        kind == .band && recurring
    }

    /// The drawer is showing a revealed hidden imported event → the footer button becomes "Unhide".
    private var isRevealedHidden: Bool {
        imported && engine.isUserHidden(id)
    }

    /// Raise the delete/hide confirm dialog for the open item (the Delete key / delete-ring Enter path).
    /// Imported events aren't recurring in our model (rep is empty) — their "recurring" is whether the
    /// series has >1 occurrence. An already-hidden imported event gets the info-only "can't delete" dialog.
    private func requestDeleteFromDrawer() {
        // Same systematic classification every other entry point uses (deleteTarget), keyed on the
        // focused occurrence box when there is one (base/occurrence + ghost detection live there).
        let t = engine.deleteTarget(for: occKey.isEmpty ? id : occKey)
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

    /// Activating the footer BUTTON (click, or Enter on its focus ring): a revealed hidden event un-hides
    /// directly; otherwise it's the delete/hide dialog. (Distinct from the raw Delete key, which always
    /// routes to the dialog — showing the info-only "already hidden" variant for a hidden event.)
    private func footerButtonAction() {
        if isRevealedHidden {
            engine.unhideImportedSeries(id); onClose()
        } else {
            requestDeleteFromDrawer()
        }
    }

    /// The note the editor is bound to right now: the occurrence note only when recurring + selected.
    private var activeNote: Binding<String> {
        (recurring && noteScope == .occurrence) ? $occNote : $notes
    }

    private let minWidth: CGFloat = 410 // wide enough that expanding Configuration doesn't force a resize
    private var maxWidth: CGFloat {
        min(760, max(minWidth, containerWidth - margin))
    }

    private let topInset: CGFloat = 52
    private let margin: CGFloat = 10
    private let cornerRadius: CGFloat = 16
    // ── Tunable layout spacing ────────────────────────────────────────────────────
    private let contentPad: CGFloat = 18 // left/right/top inset for the top group + notes editor
    private let configBottomGap: CGFloat = 0 // gap under the Configuration box (before the editor)
    private let editorVPad: CGFloat = 8 // vertical inset around the notes editor
    private let footHPad: CGFloat = 16 // foot row horizontal inset
    private let footTopPad: CGFloat = 7 // space above the toggle / delete row
    private let footBottomPad: CGFloat = 14 // space below it (raises it off the card's bottom edge)
    private let base = Calendar.current.startOfDay(for: Date())

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) { resizeHandle; card }
            .padding(.top, topInset)
            .padding(.trailing, margin)
            .padding(.bottom, margin)
            // Red accent scoped to the drawer's native controls (pickers, date fields, disclosure,
            // toggles) — kept off the toolbar so its glass buttons stay neutral.
            .tint(Theme.accent)
            .onAppear {
                load()
                // Native controls (pickers, the notes WebView) can't ride the slide transition, so
                // fade them in once the drawer has arrived rather than letting them snap into place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.18)) { settled = true }
                }
            }
            .onDisappear { engine.clearColorPreview() } // drop any lingering swatch preview
            .onChange(of: id) { _, _ in load() } // re-pointed (e.g. "make local copy") → reload fields
            .onChange(of: notes) { _, v in engine.setNotes(id, v) }
            // GIF-recording demo: stream typed note text into the editor + flip edit/preview on cue.
            .onChange(of: demoNoteFeed) { _, v in notes = v; notesMode = .edit }
            .onChange(of: demoNotePreview) { _, p in notesMode = p ? .preview : .edit }
            .modifier(DemoDrawerCues(configPulse: demoConfigOpen, repeatFeed: demoRepeatFeed,
                                     configOpen: $configOpen, rep: $rep,
                                     commit: { r in engine.setRepeat(id, r.kind == "none" ? nil : r) }))
            .onChange(of: occNote) { _, v in engine.setOccNote(id, occKey, v) }
            .onChange(of: noteScope) { _, s in // open each note in the sensible view
                // …unless a todo-row line focus is pending: load() just switched the scope
                // programmatically and the editor must open AT the line, not the content default.
                guard noteEditLine == nil else { return }
                let c = s == .occurrence ? occNote : notes
                notesMode = c.isEmpty ? .edit : .preview
            }
            .onChange(of: containerWidth) { _, _ in width = min(width, maxWidth) }
            // Title editing rides the native @FocusState: ui.drawerTitleEditing (set by Enter) focuses
            // the field; a native blur (Tab/click away) flips it back off. Ring focus on the other
            // fields is a pure highlight driven by ui.drawerFocus — no native control receives it.
            .onChange(of: ui.drawerTitleEditing) { _, editing in
                if fieldFocus != (editing ? .title : nil) {
                    fieldFocus = editing ? .title : nil
                }
                if editing {
                    titleOriginal = title
                } // remember the pre-edit title
                else { // done → strip; a blank title reverts (no empty titles)
                    let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    title = s.isEmpty ? titleOriginal : s // setting `title` re-fires commitTitle
                }
            }
            .onChange(of: fieldFocus) { _, v in
                if v == nil, ui.drawerTitleEditing {
                    ui.drawerTitleEditing = false
                } // native blur → stop editing
            }
            // Keyboard actions posted by the KeyboardModel (Enter / ←/→ on the focused field).
            .onChange(of: ui.drawerPulse) { _, _ in handleDrawerAction(ui.drawerActionKind) }
            // Tell the key monitor when a native inline editor owns the keyboard (so Tab goes to it,
            // not our drawer cycle) — either a "when" part or the "until" date field.
            .onChange(of: whenEditing) { _, _ in updateFieldEditing() }
            .onChange(of: untilFocused) { _, _ in updateFieldEditing() }
            // The confirmation dialog wants the keyboard while it's up (native Enter/Esc/arrows).
            // Configuration open/close re-shapes the Tab cycle (its children join/leave it). If it
            // collapses while a child is focused, pull focus back up to the Configuration header.
            .onChange(of: configOpen) { _, open in
                publishFieldOrder()
                if !open {
                    if ui.drawerFocus?.isConfigChild == true {
                        ui.drawerFocus = .config
                    }
                }
            }
            .onDisappear { ui.drawerFocus = nil; ui.drawerTitleEditing = false; ui.drawerFieldEditing = false }
            .onAppear { selectTitleIfRequested() } // body hoisted: keeps this chain under the
            // type-checker's budget (see the 2026-07-18 bisection)
            .id(id)
    }

    /// A freshly-created item (e.g. the deadline "+") opens with its default title focused and
    /// fully selected, so the first keystroke replaces "New Deadline".
    private func selectTitleIfRequested() {
        guard ui.selectTitleOnOpen else { return }
        ui.selectTitleOnOpen = false
        ui.drawerTitleEditing = true // focus the title field (drives fieldFocus = .title)
        // The field editor becomes first responder a beat after @FocusState flips + the drawer
        // finishes sliding in; select-all once it's up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            // Top: title / when / color / configuration (compact — Configuration collapses by default).
            VStack(alignment: .leading, spacing: 14) {
                if imported {
                    importedBanner
                } else if let src = engine.editableImportSource(id) {
                    editableImportBanner(src) // .ics file import: editable, but explain the badge
                }
                VStack(alignment: .leading, spacing: 7) {
                    Group {
                        titleField
                        whenControls // each part carries its own focus ring (see whenPart)
                    }
                    .disabled(imported) // title / time are owned by the source calendar
                    // Color IS editable on imported events — it's stored as a local overlay (colorOverride),
                    // not written back to Apple Calendar. Tags / notes / promote (in configBox) are too.
                    colorSwatches.drawerRingAnchor(.color)
                }
                configBox.drawerRingAnchor(.config)
            }
            .padding(.horizontal, contentPad).padding(.top, contentPad).padding(.bottom, configBottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Tapping empty top-area space ends any inline "when" edit (macOS won't resign a focused
            // DatePicker when a non-text control / blank area is clicked).
            .onTapGesture { endWhenEdit() }

            // Notes: the NATIVE markdown editor + preview engine (the webview retired here —
            // the app's last WKWebView). Same layout slot; horizontal padding of 18 matches
            // the top content so the text left/right edges line up.
            Group {
                if notesMode == .edit {
                    NativeNoteEditor(
                        storageKey: "drawer|\(id)|\(recurring && noteScope == .occurrence ? occKey : "series")",
                        text: activeNote.wrappedValue,
                        theme: theme,
                        // Name the note being edited — one editor serves both scopes, and an
                        // identical empty state made it impossible to tell which one you're in.
                        placeholder: !recurring ? "Something to note about this event?"
                            : noteScope == .occurrence
                            ? "Notes for THIS occurrence only…"
                            : "Notes for every occurrence of this event…",
                        onText: { activeNote.wrappedValue = $0 }, // onChange persists (setNotes/setOccNote)
                        onSave: { notesMode = .preview; refocus() }, // ⌘S → preview → notes ring
                        onExit: { // Escape → back to the notes ring (preview if there's content)
                            if !activeNote.wrappedValue
                                .trimmingCharacters(in: .whitespaces).isEmpty {
                                notesMode = .preview
                            }
                            refocus()
                        },
                        session: noteSession,
                        completionIndex: { NativeNotePanel.entityIndex(engine) },
                        dueAnchor: { engine.dueAnchorString(id).map { ("this event time", $0) } },
                        focusLine: noteEditLine,
                        onFocusLineHandled: { noteEditLine = nil },
                        focusPulse: notesFocusPulse
                    )
                } else {
                    MarkdownPreview(text: activeNote.wrappedValue, theme: theme,
                                    onToggle: { line in
                                        if NSEvent.modifierFlags.contains(.command) {
                                            noteEditLine = line
                                            notesMode = .edit
                                            return
                                        }
                                        let stamp = NativeDashPanel.todayIso() + "T"
                                            + NativeDashPanel.clockNow()
                                        if let next = TodoIndex.toggleTodoLine(
                                            activeNote.wrappedValue, line: line, stamp: stamp
                                        ),
                                            next != activeNote.wrappedValue {
                                            activeNote.wrappedValue = next
                                        }
                                    },
                                    onLineEdit: { line in
                                        noteEditLine = line
                                        notesMode = .edit
                                    })
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            .drawerRingAnchor(.notes)
            .padding(.horizontal, contentPad).padding(.vertical, editorVPad)
            // AppKit-hosted views (the editor's NSScrollView, the preview NSTextView) can't
            // ride the drawer's slide transition — platform views take their final frame at
            // layout commit, so the notes popped into place mid-slide. Same treatment as the
            // foot pickers: hidden until the slide lands, then the settled fade-in.
            .opacity(settled ? 1 : 0)
            // Leaving edit by ANY route (toggle, scope flip landing in preview) ends the
            // created:-stamp session before the preview reads the note.
            .onChange(of: notesMode) { old, new in
                if old == .edit, new != .edit {
                    noteSession.end?()
                }
            }

            footRow
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        // The single sliding dashed focus ring, positioned from the collected field anchors.
        .overlayPreferenceValue(DrawerRingAnchors.self) { drawerRingOverlay($0) }
        // Opaque base so the dim outside-click scrim behind the card can't grey it through —
        // the drawer reads fully bright and pops against the darkened calendar. Light mode uses
        // pure white (the frosted material added a faint grey cast); dark mode keeps the frosted
        // material over the solid background for depth.
        .background(cardShape.fill(theme.dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.white)))
        .background(cardShape.fill(theme.bg))
        .overlay { cardShape.strokeBorder(theme.text.opacity(0.12), lineWidth: 1) }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle()).padding(8)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        // Resign-based fallback: if the shown field loses first responder (Tab/Enter, or clicking
        // the title/tag field) and nothing else re-focuses, drop back to text. Deferred so a
        // field-to-field switch (which briefly nils focus) isn't torn down.
        .onChange(of: whenFocus) { _, f in
            if f == nil {
                DispatchQueue.main.async {
                    if whenFocus == nil {
                        whenEditing = nil
                    }
                }
            }
        }
    }

    private func endWhenEdit() {
        whenEditing = nil; whenFocus = nil
    }

    /// ── Keyboard drive ────────────────────────────────────────────────────────────
    /// ═══════════════════════════════════════════════════════════════════════════════
    /// FOCUS-RING SHAPES — TUNE HERE. This is the single place that controls the shape of
    /// every drawer focus ring. Each field maps to a RingSpec:
    ///   • inset  — padding applied to the ring rect. NEGATIVE grows it OUTWARD past the
    ///              control (looser); POSITIVE shrinks it INWARD (tighter). Per-edge, so you
    ///              can nudge just left/right or top/bottom (e.g. to clear an occluding edge).
    ///   • radius — corner radius of the rounded rectangle.
    ///   • width  — stroke thickness when focused.
    /// Every call site is just `.drawerRingAnchor(.someField)` — no geometry there.
    /// ═══════════════════════════════════════════════════════════════════════════════
    private struct RingSpec { var inset: EdgeInsets; var radius: CGFloat; var width: CGFloat = 2 }

    private func ringSpec(for field: DrawerField) -> RingSpec {
        // helpers: `ins` = per-edge (top, leading, bottom, trailing); `all` = uniform.
        func ins(_ t: CGFloat, _ l: CGFloat, _ b: CGFloat, _ r: CGFloat) -> EdgeInsets {
            EdgeInsets(
                top: t,
                leading: l,
                bottom: b,
                trailing: r
            )
        }
        func all(_ v: CGFloat) -> EdgeInsets {
            ins(v, v, v, v)
        }
        switch field {
        // Top group
        case .title: return RingSpec(inset: ins(-3, -5, -3, -5), radius: 8)
        case .date, .start, .end: return RingSpec(inset: ins(-2, -4, -2, -4), radius: 8)
        case .color: return RingSpec(inset: all(-4), radius: 8)
        case .config: return RingSpec(inset: all(-2), radius: 10)
        case .notes: return RingSpec(inset: all(0), radius: 6)
        case .noteScope: return RingSpec(inset: all(-3), radius: 7)
        case .delete: return RingSpec(inset: all(-4), radius: 7)
        // Configuration children (rings sit on the inner controls)
        case .cfgRepeat: return RingSpec(inset: all(-3), radius: 7)
        case .repEvery: return RingSpec(inset: all(-3), radius: 7)
        case .repDays: return RingSpec(inset: all(-3), radius: 7)
        case .repUntil: return RingSpec(inset: all(-3), radius: 7)
        case .repUntilDate: return RingSpec(inset: all(-3), radius: 7)
        case .cfgPromote: return RingSpec(inset: all(-3), radius: 7)
        case .promoteLane: return RingSpec(inset: all(-3), radius: 7)
        case .cfgTimezone: return RingSpec(inset: all(-3), radius: 7)
        }
    }

    /// The ONE dashed focus ring that slides over the focused field. Positioned from the collected
    /// field anchors; springs to its new frame when `ui.drawerFocus` changes. Dashed + red = the same
    /// language as the calendar cursors.
    private func drawerRingOverlay(_ anchors: [DrawerField: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let f = ui.drawerFocus, let anchor = anchors[f] {
                let spec = ringSpec(for: f)
                let b = proxy[anchor]
                let rect = CGRect(x: b.minX + spec.inset.leading, y: b.minY + spec.inset.top,
                                  width: b.width - spec.inset.leading - spec.inset.trailing,
                                  height: b.height - spec.inset.top - spec.inset.bottom)
                RoundedRectangle(cornerRadius: spec.radius, style: .continuous)
                    .strokeBorder(theme.eventBorder("red"), style: StrokeStyle(lineWidth: spec.width, dash: [4, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: ui.drawerFocus)
    }

    /// Map a keyboard-focused "when" field to its inline editor part.
    private func whenFieldFor(_ f: DrawerField) -> WhenField? {
        switch f { case .date: return .date; case .start: return .start; case .end: return .end; default: return nil }
    }

    /// Run a keyboard action against the currently-focused field (posted via ui.postDrawer).
    private func handleDrawerAction(_ action: DrawerActionKind) {
        if action == .confirmDelete {
            requestDeleteFromDrawer(); return
        } // Delete key → confirm dialog
        switch ui.drawerFocus {
        case .title:
            if action == .activate {
                ui.drawerTitleEditing = true
            } // Enter → start editing the title
        case .date, .start, .end:
            if action == .activate, let wf = whenFieldFor(ui.drawerFocus!) {
                whenEditing = wf
            }
        case .color:
            if action == .left {
                cycleColor(-1)
            } else if action == .right {
                cycleColor(1)
            }
        case .config:
            if action == .activate {
                withAnimation(.easeInOut(duration: 0.2)) { configOpen.toggle() }
            }
        case .cfgRepeat:
            if action == .left {
                cycleRepeat(-1)
            } else if action == .right {
                cycleRepeat(1)
            }
        case .repEvery:
            if action == .left {
                stepEvery(-1)
            } else if action == .right {
                stepEvery(1)
            }
        case .repDays:
            if action == .left {
                repDayCursor = (repDayCursor + 6) % 7
            } else if action == .right {
                repDayCursor = (repDayCursor + 1) % 7
            } else if action == .activate {
                toggleDay(repDayCursor)
            }
        case .repUntil:
            if action == .left || action == .right {
                untilOn.wrappedValue.toggle()
            }
        case .repUntilDate:
            if action == .activate {
                untilFocused = true
            }
        case .cfgPromote:
            if action == .left {
                stepPromote(-1)
            } else if action == .right {
                stepPromote(1)
            }
        case .cfgTimezone:
            if action == .left {
                stepTimezone(-1)
            } else if action == .right {
                stepTimezone(1)
            }
        case .promoteLane:
            if action == .left {
                stepPromoteLane(-1)
            } else if action == .right {
                stepPromoteLane(1)
            }
        case .notes:
            if action == .activate {
                notesMode = .edit; notesFocusPulse += 1
            } // edit mode + focus CodeMirror
        case .noteScope:
            if action == .left {
                noteScope = .series
            } else if action == .right {
                noteScope = .occurrence
            }
        case .delete:
            if action == .activate {
                footerButtonAction()
            } // Enter on the delete ring = clicking the button
        case .none: break
        }
    }

    private let repeatKinds = ["none", "daily", "weekly", "weekdays", "yearly"]
    /// Step the repeat kind (← / →) through the segmented options.
    private func cycleRepeat(_ delta: Int) {
        let i = repeatKinds.firstIndex(of: rep.kind) ?? 0
        let n = repeatKinds.count
        setKind(repeatKinds[((i + delta) % n + n) % n])
    }

    /// Step the "every N weeks" count within 1…4.
    private func stepEvery(_ delta: Int) {
        let v = max(1, min(4, (rep.n ?? 1) + delta))
        if v != (rep.n ?? 1) {
            rep.n = v; commitRep()
        }
    }

    /// A native inline editor (a "when" part or the "until" date) owns the keyboard right now.
    private func updateFieldEditing() {
        ui.drawerFieldEditing = (whenEditing != nil) || untilFocused
    }

    /// Bands: step the lane T1…T4. Timed/deadline: toggle promote off/on (← and → both toggle).
    private func stepPromote(_ delta: Int) {
        if kind == .band {
            let t = max(0, min(3, track + delta))
            track = t; engine.updateBand(id) { $0.track = t }
        } else {
            promote = (promote == nil) ? 0 : nil
            engine.setPromoteTrack(id, promote)
            refreshOrder(fallback: .cfgPromote) // toggling on/off adds/removes the lane picker
        }
    }

    /// Timed/deadline: step the promoted lane T1…T4.
    private func stepPromoteLane(_ delta: Int) {
        let v = max(0, min(3, (promote ?? 0) + delta))
        promote = v; engine.setPromoteTrack(id, promote)
    }

    /// Step the selected colour by `delta` (← / →), committing live.
    private func cycleColor(_ delta: Int) {
        guard let i = EVENT_COLORS.firstIndex(of: color) else { color = EVENT_COLORS.first ?? color; return }
        let n = EVENT_COLORS.count
        color = EVENT_COLORS[((i + delta) % n + n) % n]
        commitColor(color)
    }

    /// ── Configuration disclosure (macOS Settings-style grouped box) ────────────────
    /// A collapsed-by-default rounded box: native DisclosureGroup for the collapse, holding the
    /// advanced controls (tags / repeat / promote) split by full-margin dividers.
    private var configBox: some View {
        DisclosureGroup(isExpanded: $configOpen) {
            VStack(alignment: .leading, spacing: 0) {
                // (Tags have no UI row here: they're markdown — type #tokens into the note itself.)
                // Imported events have NO Repeat section: recurrence is configured in the source
                // calendar app (Apple Calendar / Google / Outlook), which expands occurrences for
                // us — a local rule would fight the vendor's. (Promote stays: a local overlay.)
                if !imported {
                    configItem("Repeat") { repeatControls } // rings live on each repeat sub-control
                    configDivider
                }
                configItem(kind == .band ? "Lane" : "Promote") { laneOrPromoteControls } // rings live on each control
                if kind != .band { // bands are all-day → timezone-irrelevant
                    configDivider
                    configItem("Timezone") { tzControls.drawerRingAnchor(.cfgTimezone) }
                }
            }
            .padding(.bottom, 6)
            // Inset the controls a touch so the focus rings' outset (see ringSpec, ~3pt) stays inside
            // the DisclosureGroup's content clip — otherwise the ring's left/right edges get cut off.
            .padding(.horizontal, 4)
            // The config children's anchors don't cross the DisclosureGroup boundary (it resets
            // preferences), so the sliding ring for them is rendered HERE, inside the content. Only one
            // ring is ever visible — keyed on ui.drawerFocus — so this never double-draws with the card's.
            .overlayPreferenceValue(DrawerRingAnchors.self) { drawerRingOverlay($0) }
        } label: {
            // Full-width, vertically-padded header so clicking anywhere across the title row —
            // including a little above/below it — toggles the disclosure (not just the triangle).
            HStack {
                Text("Configuration").font(.callout.weight(.medium)).foregroundStyle(theme.text)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { configOpen.toggle() } }
        }
        .padding(.horizontal, 12)
        .background(theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
            theme.text.opacity(0.08),
            lineWidth: 1
        ) }
    }

    /// Row separator inside the config box — theme text colour so it stays light on dark, with
    /// breathing room above and below the line.
    private var configDivider: some View {
        Rectangle().fill(theme.text.opacity(0.14)).frame(height: 1).padding(.vertical, 6)
    }

    /// One captioned row inside the box, with top/bottom margin so the dividers breathe.
    private func configItem<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased()).font(.caption2).tracking(0.7).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    /// Provenance banner for a READ-ONLY imported event: real source name (Apple Calendar /
    /// Google Calendar / Calendar Feed) + Edit-original deep link (when derivable) + local copy.
    @ViewBuilder private var importedBanner: some View {
        let prov = engine.importedProvenance(id)
        HStack(spacing: 7) {
            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
            Text(prov?.label ?? "Imported").font(.system(size: 11, weight: .medium)).fixedSize()
            Spacer(minLength: 6)
            // Reveal the event back in its source calendar (Calendar.app deep link / Google
            // Calendar web link) — only when we can still derive the original's identity.
            if let prov, let url = prov.editURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Edit original", systemImage: "arrow.up.forward.app")
                }
                .help(prov.editHelp)
            }
            // Clone into our own calendar (editable); the read-only original is hidden. Re-point the drawer.
            Button {
                if let newId = engine.makeLocalCopy(id) {
                    ui.openEventId = newId
                }
            } label: {
                Label("Make local copy", systemImage: "doc.on.doc")
            }
            .help("Duplicate into your calendar so you can edit it")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
    }

    /// Informational banner for an EDITABLE item that still wears the imported badge (a one-shot
    /// .ics file import): explains the badge without vendor buttons — the copy is fully local.
    private func editableImportBanner(_ source: String) -> some View {
        let label = switch source {
        case "ical": "Imported from .ics file (editable local copy)"
        case "apple": "Imported from Apple Calendar (editable local copy)"
        default: "Imported (editable local copy)"
        }
        return HStack(spacing: 7) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 11, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
    }

    private var titleField: some View {
        TextField("Untitled", text: $title)
            .textFieldStyle(.plain)
            .font(.custom("Comic Sans MS", size: 20).weight(.bold))
            .foregroundStyle(theme.text)
            .padding(.trailing, 26)
            .focused($fieldFocus, equals: .title) // keyboard: Enter on the title ring focuses this
            .onHover { $0 ? NSCursor.iBeam.set() : NSCursor.arrow.set() }
            .onChange(of: title) { _, v in commitTitle(v) }
            // Enter / Escape end editing but keep the title RING focused, so Tab flows on to date.
            .onSubmit { ui.drawerTitleEditing = false; refocus() }
            .onExitCommand { ui.drawerTitleEditing = false; refocus() }
            .drawerRingAnchor(.title)
    }

    private var colorSwatches: some View {
        HStack(spacing: 8) {
            ForEach(EVENT_COLORS, id: \.self) { key in
                Circle()
                    .fill(theme.eventBorder(key))
                    .frame(width: 17, height: 17)
                    .overlay(Circle().strokeBorder(theme.text, lineWidth: key == color ? 2 : 0))
                    .contentShape(Circle())
                    .onHover { hovering in
                        if hovering {
                            engine.setColorPreview(id, key)
                        } else {
                            engine.clearColorPreview(key)
                        }
                    }
                    .onTapGesture { endWhenEdit(); color = key; commitColor(key) }
            }
        }
    }

    /// One tappable "when" part: plain text (sized to the text) until clicked; then it swaps to a
    /// focused native `.field` DatePicker. `whenEditing` drives visibility — the editor renders only
    /// while active (so the text isn't padded to the field's width) and grabs focus on appear.
    private func whenPart<E: View>(_ field: WhenField, _ text: String, @ViewBuilder _ editor: () -> E) -> some View {
        // Both states occupy the same (measured) field height so activating the editor never
        // shifts the drawer's layout.
        Group {
            if whenEditing == field {
                editor()
                    .labelsHidden().datePickerStyle(.field)
                    .focused($whenFocus, equals: field)
                    .fixedSize()
                    .onAppear { whenFocus = field }
                    // Enter / Escape commit-and-exit the native editor back to the ring, returning
                    // first responder to the calendar so Tab keeps cycling. (The value is already
                    // committed live by the bindings, so both keys just close the editor.)
                    .onExitCommand { endWhenEdit(); refocus() }
                    .onKeyPress(.return) { endWhenEdit(); refocus(); return .handled }
            } else {
                Text(text)
                    .foregroundStyle(theme.text)
                    .contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.iBeam.set() : NSCursor.arrow.set() }
                    .onTapGesture { whenEditing = field }
            }
        }
        .frame(height: whenRowH, alignment: .leading)
        .drawerRingAnchor(whenDrawerField(field))
    }

    /// The DrawerField that corresponds to a "when" part (for the focus ring).
    private func whenDrawerField(_ f: WhenField) -> DrawerField {
        switch f { case .date: return .date; case .start: return .start; case .end: return .end }
    }

    private func dateStr(_ d: Int) -> String {
        "\(month + 1)/\(d)/\(itemYear)"
    }

    private func dateStr(_ p: YMD) -> String {
        "\(p.month + 1)/\(p.day)/\(p.year)"
    } // full date (may cross months)
    private var dateText: String {
        dateStr(day)
    }

    /// "Started …" button: navigate to + select the base (first) occurrence, then close and reopen the
    /// drawer on it. `id` is already the source/base id (the drawer always opens on the source).
    private func goToFirstOccurrence() {
        let baseId = id
        ui.openEventId = nil // close the drawer (slides out)
        engine.revealAndSelect(id: baseId) // highlight the first occurrence + fly to it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ui.openEventId = baseId } // reopen on it
    }

    private func timeText(_ h: CGFloat) -> String {
        let hh = min(23, Int(h)); let mm = Int((h - floor(h)) * 60)
        return String(format: "%d:%02d", hh, mm)
    }

    /// "Navigate to Event" — shown beside the time info when the drawer was reached WITHOUT
    /// selecting the event on the canvas (a dashboard/gantt/search open): fly the calendar to
    /// the event and select it, keeping the drawer up.
    @ViewBuilder private var navigateButton: some View {
        if engine.selectedId.map({ sourceId(of: $0) }) != id {
            Button { engine.revealAndSelect(id: id) } label: {
                Label("Navigate to Event", systemImage: "location")
            }
            .buttonStyle(.link).font(.caption)
            .foregroundStyle(Theme.accent) // .link renders blue; the app's accent (Settings) wins
            .help("Fly the calendar to this event")
        }
    }

    @ViewBuilder private var whenControls: some View {
        switch kind {
        case .timed:
            // Read-only text until a part is clicked; then just that part becomes a focused native
            // field, reverting to text when focus leaves (click elsewhere).
            HStack(spacing: 5) {
                whenPart(.date, dateText) { DatePicker("", selection: dateBinding, displayedComponents: .date) }
                Text(",").foregroundStyle(.secondary)
                whenPart(.start, timeText(start)) { DatePicker(
                    "",
                    selection: timeBinding({ start }, setStart),
                    displayedComponents: .hourAndMinute
                ) }
                Text("–").foregroundStyle(.secondary)
                whenPart(.end, timeText(end)) { DatePicker(
                    "",
                    selection: timeBinding({ end }, setEnd),
                    displayedComponents: .hourAndMinute
                ) }
                Spacer(minLength: 0)
                navigateButton
            }
            .font(.callout)
        case .band where recurringBand:
            // Recurring band → the CURRENT occurrence's range, read-only (no Tab stop / no editor), then a
            // "Started <first-occurrence date>" button that jumps to & reopens the drawer on the first one.
            HStack(spacing: 4) {
                Text(occStart.map(dateStr) ?? dateStr(startDay))
                if let s = occStart, let e = occEnd, !(s == e) {
                    Text("–").foregroundStyle(.secondary)
                    Text(dateStr(e))
                }
                if !onBaseOccurrence, let bs = baseStart {
                    Text("; Started").foregroundStyle(.secondary)
                    Button(dateStr(bs)) { goToFirstOccurrence() }
                        .buttonStyle(.link)
                }
                Spacer(minLength: 0)
                navigateButton
            }
            .font(.callout).foregroundStyle(theme.text)
        case .band:
            HStack(spacing: 5) {
                whenPart(.start, dateStr(startDay)) { DatePicker(
                    "",
                    selection: bandDayBinding(true),
                    in: monthRange,
                    displayedComponents: .date
                ) }
                Text("–").foregroundStyle(.secondary)
                whenPart(.end, dateStr(endDay)) { DatePicker(
                    "",
                    selection: bandDayBinding(false),
                    in: monthRange,
                    displayedComponents: .date
                ) }
                Spacer(minLength: 0)
                navigateButton
            }
            .font(.callout)
        case .deadline:
            HStack(spacing: 5) {
                whenPart(.date, dateText) { DatePicker("", selection: ddlDateBinding, displayedComponents: .date) }
                Text(",").foregroundStyle(.secondary)
                whenPart(.start, timeText(hour)) { DatePicker(
                    "",
                    selection: timeBinding({ hour }, setDdlHour),
                    displayedComponents: .hourAndMinute
                ) }
                Spacer(minLength: 0)
                navigateButton
            }
            .font(.callout)
        }
    }

    /// ── Tags ──────────────────────────────────────────────────────────────────────
    /// ── Repeat ────────────────────────────────────────────────────────────────────
    private var repeatControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The kind picker itself is the `.cfgRepeat` stop (its ring lives here, not on the whole section).
            Picker("", selection: repKind) {
                Text("None").tag("none"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly")
                Text("Weekdays").tag("weekdays"); Text("Yearly").tag("yearly")
            }
            .pickerStyle(.segmented).labelsHidden()
            .drawerRingAnchor(.cfgRepeat)

            if rep.kind == "weekly" || rep.kind == "weekdays" {
                HStack(spacing: 6) {
                    Text("every").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: repN) { ForEach(1 ... 4, id: \.self) { Text("\($0)").tag($0) } }
                        .labelsHidden().frame(width: 58)
                    Text((rep.n ?? 1) > 1 ? "weeks" : "week").font(.caption).foregroundStyle(.secondary)
                }
                .drawerRingAnchor(.repEvery)
            }
            if rep.kind == "weekdays" {
                HStack(spacing: 4) { ForEach(0 ..< 7, id: \.self) { weekdayButton($0) } }
                    .drawerRingAnchor(.repDays)
            }
            if rep.kind != "none" {
                HStack(spacing: 8) {
                    Text("until").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: untilOn) { Text("None").tag(false); Text("Date").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize() // hug content, flush left
                        .drawerRingAnchor(.repUntil)
                    if rep.until != nil {
                        DatePicker("", selection: untilDate, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field)
                            .focused($untilFocused)
                            .drawerRingAnchor(.repUntilDate)
                            // Enter / Escape commit-and-exit the field back to the ring (value is live).
                            .onExitCommand { untilFocused = false; refocus() }
                            .onKeyPress(.return) { untilFocused = false; refocus(); return .handled }
                    }
                }
            }
        }
    }

    private func weekdayButton(_ i: Int) -> some View {
        let sel = (rep.days ?? [anchorDow]).contains(i)
        let locked = i == anchorDow
        let cursor = ui.drawerFocus == .repDays && repDayCursor == i // keyboard cursor is on this day
        return Button { toggleDay(i) } label: {
            Text(DOW[i]).font(.caption2)
                .frame(width: 27, height: 24)
                .background(sel ? theme.eventBorder(color).opacity(locked ? 0.5 : 0.9) : theme.text.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(sel ? .white : theme.text)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                    theme.eventBorder("red"),
                    lineWidth: cursor ? 2 : 0
                ))
        }
        .buttonStyle(.plain).disabled(locked)
    }

    /// ── Promote / Lane ──────────────────────────────────────────────────────────────
    @ViewBuilder private var laneOrPromoteControls: some View {
        if kind == .band {
            Picker("", selection: lane) { ForEach(0 ..< 4, id: \.self) { Text("T\($0 + 1)").tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
                .drawerRingAnchor(.cfgPromote)
        } else {
            HStack(spacing: 8) {
                Picker("", selection: promoteOn) { Text("No").tag(false); Text("Yes").tag(true) }
                    .pickerStyle(.segmented).labelsHidden()
                    .fixedSize() // hug content → flush left (not centered in a fixed frame)
                    .drawerRingAnchor(.cfgPromote)
                if promote != nil {
                    Picker("", selection: promoteLane) { ForEach(0 ..< 4, id: \.self) { Text("T\($0 + 1)").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                        .drawerRingAnchor(.promoteLane)
                }
            }
        }
    }

    /// ── Timezone (the event's anchor zone) ───────────────────────────────────────────
    /// The zone the event's own date/time are expressed in. Changing it REINTERPRETS the shown wall-clock
    /// in the new zone (keeps the numbers, moves the instant) — "this meeting is at 14:00 London time".
    /// The calendar grid then re-converts it into the current view zone; the hint shows where it lands.
    private var tzControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: tzBinding) {
                ForEach(CalendarTimezones.anchorZones) { Text($0.label).tag($0.id) }
            }
            .labelsHidden().fixedSize()
            if let hint = gridTimeHint {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .disabled(imported)
    }

    /// The event's stored anchor zone, read STRAIGHT from the engine — never a mirror @State that could
    /// drift to (and then be committed as) the current view zone. Falls back to the view zone only for a
    /// legacy item with no anchor yet.
    private var eventAnchorTz: String {
        (engine.event(id)?.anchorTz ?? engine.deadline(id)?.anchorTz) ?? engine.mainTz
    }

    private var tzBinding: Binding<String> {
        Binding(get: { eventAnchorTz }, set: { newTz in
            let anchor = DeadlineTZ.concrete(newTz)
            guard anchor != eventAnchorTz
            else { return } // ignore SwiftUI echo / no-op writes → never clobber the anchor
            switch kind {
            case .timed: engine.update(id) { $0.anchorTz = anchor }
            case .deadline: engine.updateDeadline(id) { $0.anchorTz = anchor }
            case .band: break
            }
            syncFromEngine()
        })
    }

    /// "= HH:MM TZ on your calendar" — the event's time in the current view zone, shown only when the
    /// event's own zone differs from the view (so it moved on the grid).
    private var gridTimeHint: String? {
        func hhmm(_ h: CGFloat) -> String {
            let t = Int((h * 60).rounded()); return String(
                format: "%02d:%02d",
                (t / 60) % 24,
                t % 60
            )
        }
        let tz = eventAnchorTz
        let mainTz = engine.mainTz
        let base = DeadlineTZ.instant(itemYear, month, day, kind == .deadline ? hour : start)
        guard !DeadlineTZ.sameOffset(tz, mainTz, at: base) else { return nil }
        let abbr = DeadlineTZ.shortLabel(mainTz, at: base)
        if kind == .deadline {
            let w = DeadlineTZ.convertWall(itemYear, month, day, hour, from: tz, to: mainTz)
            return "= \(hhmm(w.hour)) \(abbr) on your calendar"
        } else {
            let w = DeadlineTZ.convertWall(itemYear, month, day, start, from: tz, to: mainTz)
            return "= \(fmtHourRange(w.hour, w.hour + (end - start))) \(abbr) on your calendar"
        }
    }

    private func stepTimezone(_ delta: Int) {
        let zones = CalendarTimezones.anchorZones.map(\.id)
        guard !zones.isEmpty else { return }
        let cur = zones.firstIndex(of: DeadlineTZ.concrete(eventAnchorTz)) ?? 0
        tzBinding.wrappedValue = zones[((cur + delta) % zones.count + zones.count) % zones.count]
    }

    // Foot: notes edit/preview toggle, a series/occurrence note toggle (recurring only), then delete.
    private var footRow: some View {
        HStack(spacing: 10) {
            Picker("", selection: $notesMode) {
                Image(systemName: "pencil").tag(NotesMode.edit)
                Image(systemName: "eye").tag(NotesMode.preview)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .opacity(settled ? 1 : 0)
            if recurring {
                Picker("", selection: $noteScope) {
                    Text("All Events").tag(NoteScope.series)
                    Text("This Event").tag(NoteScope.occurrence)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .opacity(settled ? 1 : 0)
                .drawerRingAnchor(.noteScope)
            }
            Spacer(minLength: 0)
            // The footer button: a revealed hidden imported event → Unhide (eye, direct, non-destructive);
            // otherwise Delete (trash) / Hide (eye.slash) via the app-level confirm dialog. (The Delete KEY
            // on a hidden event instead shows the info-only "already hidden" dialog — see requestDeleteFromDrawer.)
            Button(role: isRevealedHidden ? nil : .destructive) { footerButtonAction() } label: {
                Image(systemName: isRevealedHidden ? "eye" : (imported ? "eye.slash" : "trash")).font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isRevealedHidden ? theme.text : theme.eventBorder("red"))
            .drawerRingAnchor(.delete)
            .help(isRevealedHidden ? "Unhide" : (imported ? "Hide" : "Delete"))
        }
        .padding(.horizontal, footHPad).padding(.top, footTopPad).padding(.bottom, footBottomPad)
    }

    /// ── Resize handle ─────────────────────────────────────────────────────────────
    private var resizeHandle: some View {
        Capsule()
            .fill(theme.text.opacity(resizeHover ? 0.55 : 0.3))
            .frame(width: 4, height: 48)
            .padding(.trailing, 4)
            .frame(width: 18, alignment: .trailing)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover {
                h in resizeHover = h; if h {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        let s = resizeStart ?? width
                        if resizeStart == nil {
                            resizeStart = width
                        }
                        width = min(maxWidth, max(minWidth, s - v.translation.width))
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }

    /// ── Date/time bindings ──────────────────────────────────────────────────────────
    private var dateBinding: Binding<Date> {
        Binding(get: { makeDate(itemYear, month, day) },
                set: { d in let x = ymd(d); engine.update(id) { $0.month = x.m; $0.day = x.day }; syncFromEngine() })
    }

    private var ddlDateBinding: Binding<Date> {
        Binding(get: { makeDate(itemYear, month, day) },
                set: { d in
                    let x = ymd(d); engine
                        .updateDeadline(id) { $0.year = x.y; $0.month = x.m; $0.day = x.day }; syncFromEngine()
                })
    }

    private func bandDayBinding(_ isStart: Bool) -> Binding<Date> {
        Binding(
            get: { makeDate(itemYear, month, isStart ? startDay : endDay) },
            set: { d in
                let day = max(1, min(daysInMonth(itemYear, month), ymd(d).day))
                engine.updateBand(id) {
                    if isStart {
                        $0.startDay = min(day, $0.endDay)
                    } else {
                        $0.endDay = max(
                            day,
                            $0.startDay
                        )
                    }
                }
                syncFromEngine()
            }
        )
    }

    private var monthRange: ClosedRange<Date> {
        makeDate(itemYear, month, 1) ... makeDate(itemYear, month, daysInMonth(itemYear, month))
    }

    private func timeBinding(_ get: @escaping () -> CGFloat, _ set: @escaping (CGFloat) -> Void) -> Binding<Date> {
        Binding(
            get: {
                let h = get(); let hh = Int(h) %
                    24; let mm = Int((h - floor(h)) * 60) // %24 so a next-day end (h>24) shows its wall time
                return Calendar.current
                    .date(bySettingHour: max(0, min(23, hh)), minute: mm, second: 0, of: base) ?? base
            },
            set: { d in
                let c = Calendar.current
                    .dateComponents([.hour, .minute], from: d); set(CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60)
            }
        )
    }

    private func setStart(_ h: CGFloat) {
        engine.update(id) {
            $0.startHour = h; if $0.endHour < h + 0.25 {
                $0.endHour = min(
                    24,
                    h + 0.5
                )
            }
        }; syncFromEngine()
    }

    private func setEnd(_ h: CGFloat) {
        engine.update(id) {
            // Picking an end at or before the start means the event runs past midnight (a red-eye): store
            // the end as start-relative hours > 24 (next day). Minimum 15 min; whole span capped at 24h.
            let e = h <= $0.startHour ? h + 24 : h
            $0.endHour = min($0.startHour + 24, max($0.startHour + 0.25, e))
        }
        syncFromEngine()
    }

    private func setDdlHour(_ h: CGFloat) {
        engine.updateDeadline(id) { $0.hour = h }; syncFromEngine()
    }

    /// ── Repeat bindings + logic ───────────────────────────────────────────────────
    private var anchorDate: Date {
        makeDate(itemYear, month, kind == .band ? startDay : day)
    }

    private var anchorDow: Int {
        (Calendar.current.dateComponents([.weekday], from: anchorDate).weekday ?? 1) - 1
    }

    private var repKind: Binding<String> {
        Binding(get: { rep.kind }, set: { setKind($0) })
    }

    private var repN: Binding<Int> {
        Binding(get: { rep.n ?? 1 }, set: { rep.n = $0; commitRep() })
    }

    private var untilOn: Binding<Bool> {
        Binding(get: { rep.until != nil },
                set: { on in
                    if on {
                        if rep.until == nil {
                            rep.until = iso(anchorDate)
                        }
                    } else {
                        rep.until = nil
                    }; commitRep()
                })
    }

    private var untilDate: Binding<Date> {
        Binding(get: { parseIso(rep.until) ?? anchorDate }, set: { rep.until = iso($0); commitRep() })
    }

    private func setKind(_ k: String) {
        switch k {
        case "daily": rep = Repeat(kind: "daily", until: rep.until)
        case "weekly": rep = Repeat(kind: "weekly", n: rep.n ?? 1, until: rep.until)
        case "yearly": rep = Repeat(kind: "yearly", until: rep.until)
        case "weekdays": rep = Repeat(kind: "weekdays", n: rep.n ?? 1, until: rep.until, days: withAnchor(rep.days))
        default: rep = Repeat(kind: "none")
        }
        commitRep()
    }

    private func toggleDay(_ i: Int) {
        if i == anchorDow {
            return
        }
        var set = Set(rep.days ?? [anchorDow])
        if set.contains(i) {
            set.remove(i)
        } else {
            set.insert(i)
        }
        set.insert(anchorDow)
        rep.days = set.sorted(); commitRep()
    }

    private func withAnchor(_ days: [Int]?) -> [Int] {
        (Set(days ?? []).union([anchorDow])).sorted()
    }

    private func commitRep() {
        endWhenEdit(); engine.setRepeat(id, rep.kind == "none" ? nil : rep)
        refreshOrder(fallback: .cfgRepeat) // kind change adds/removes sub-controls in the Tab cycle
    }

    /// ── Promote / lane bindings ─────────────────────────────────────────────────────
    private var lane: Binding<Int> {
        Binding(
            get: { track },
            set: { endWhenEdit(); track = $0; engine.updateBand(id) { $0.track = track } }
        )
    }

    private var promoteOn: Binding<Bool> {
        Binding(
            get: { promote != nil },
            set: { on in endWhenEdit(); promote = on ? (promote ?? 0) : nil; engine.setPromoteTrack(
                id,
                promote
            ); refreshOrder(fallback: .cfgPromote) }
        )
    }

    private var promoteLane: Binding<Int> {
        Binding(
            get: { promote ?? 0 },
            set: { endWhenEdit(); promote = $0; engine.setPromoteTrack(id, promote) }
        )
    }

    /// ── Date helpers ────────────────────────────────────────────────────────────────
    private func makeDate(_ year: Int, _ month0: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = year; c.month = month0 + 1; c.day = d; c.hour = 12
        return Calendar.current.date(from: c) ?? base
    }

    private func ymd(_ d: Date) -> (y: Int, m: Int, day: Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return (c.year ?? itemYear, (c.month ?? 1) - 1, c.day ?? 1)
    }

    private func iso(_ d: Date)
        -> String {
        let x = ymd(d); return String(format: "%04d-%02d-%02d", x.y, x.m + 1, x.day)
    }

    private func parseIso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return makeDate(y, m - 1, d)
    }

    /// ── Load / commit / sync ─────────────────────────────────────────────────────
    private func load() {
        width = min(max(minWidth, width), maxWidth)
        if let e = engine
            .event(id) {
            kind = .timed; title = e.title; color = engine.colorOverride(id) ?? e.color; itemYear = engine
                .year; month = e.month; day = e.day; start = e.startHour; end = e.endHour
        } else if let b = engine
            .band(id) {
            kind = .band; title = b.title; color = b.color; itemYear = b.year; month = b.month; startDay = b
                .startDay; endDay = b.endDay; track = b.track
        } else if let d = engine
            .deadline(id) {
            kind = .deadline; title = d.title; color = d.color; itemYear = d.year; month = d.month; day = d
                .day; hour = d.hour
        } else {
            onClose(); return
        }
        rep = engine.repeatConfig(id) ?? Repeat(kind: "none")
        promote = engine.promoteTrack(id)
        // Context menu's "Repeat…": arrive with Configuration already expanded.
        if ui.openRepeatOnOpen {
            configOpen = true; ui.openRepeatOnOpen = false
        }
        // Focused occurrence box id (the clicked ghost if it belongs to this series, else the base).
        // Strip the promoted-band marker so a promoted bar and its timeline occurrence share one note.
        occKey = occurrenceKey(of: (engine.selectedId.flatMap { sourceId(of: $0) == id ? $0 : nil }) ?? id)
        // Recurring band: resolve the CURRENT occurrence's date range + the base start (for "Started …").
        if kind == .band, rep.kind != "none" {
            let range = engine.bandOccurrenceRange(occKey)
            occStart = range?.start; occEnd = range?.end
            baseStart = engine.bandBaseStart(id)
            onBaseOccurrence = !occKey.contains("@") // no "@Y-M-D" → the base/first occurrence itself
        } else {
            occStart = nil; occEnd = nil; baseStart = nil; onBaseOccurrence = false
        }
        notes = engine.notes(id)
        occNote = engine.occNote(id, occKey)
        noteScope = .series
        notesMode = notes.isEmpty ? .edit : .preview // land on preview when there's something to show
        // A TODO row opened this drawer (panel click / Enter): land the notes area in the
        // EDITOR at the row's source line, in the note that actually holds it — the occurrence
        // ("This Event") note when the todo came from one. Consumed once; the scope-change
        // default (onChange(of: noteScope)) yields while noteEditLine is pending.
        if let target = ui.openNoteTarget {
            ui.openNoteTarget = nil
            if recurring, let ok = target.occurrenceKey {
                occKey = ok
                occNote = engine.occNote(id, ok)
                noteScope = .occurrence
            }
            notesMode = .edit
            noteEditLine = target.line
        }
        publishFieldOrder()
    }

    /// Publish the Tab cycle for the current kind. Configuration's children (tags / repeat / promote)
    /// are spliced in before delete only while the box is open, so Tab descends into them and back out.
    private func publishFieldOrder() {
        var order: [DrawerField] = switch kind {
        case .timed: [.title, .date, .start, .end, .color, .config]
        // A recurring band shows its occurrence dates read-only → no .start/.end Tab stops.
        case .band: recurring ? [.title, .color, .config] : [.title, .start, .end, .color, .config]
        case .deadline: [.title, .date, .start, .color, .config] // start = the time
        }
        if configOpen {
            // Imported events have no Repeat section (vendor-owned recurrence) — keep the Tab
            // cycle in lockstep with configBox.
            if !imported {
                order.append(.cfgRepeat)
                // The repeat sub-controls appear conditionally — mirror repeatControls exactly so
                // Tab visits every input that's actually on screen.
                if rep.kind == "weekly" || rep.kind == "weekdays" {
                    order.append(.repEvery)
                }
                if rep.kind == "weekdays" {
                    order.append(.repDays)
                }
                if rep.kind != "none" {
                    order.append(.repUntil)
                    if rep.until != nil {
                        order.append(.repUntilDate)
                    }
                }
            }
            order.append(.cfgPromote)
            if kind != .band, promote != nil {
                order.append(.promoteLane)
            } // lane picker appears when promoted
            if kind != .band {
                order.append(.cfgTimezone)
            } // bands are all-day → no timezone
        }
        order.append(.notes) // the markdown editor (always present, below Configuration)
        if recurring {
            order.append(.noteScope)
        } // All Events / This Event toggle (recurring only)
        order.append(.delete)
        ui.drawerFieldOrder = order
    }

    /// Re-publish the Tab cycle after a change that adds/removes fields, retreating focus to `fallback`
    /// if the field it was on just left the cycle.
    private func refreshOrder(fallback: DrawerField) {
        publishFieldOrder()
        if let f = ui.drawerFocus, !ui.drawerFieldOrder.contains(f) {
            ui.drawerFocus = fallback
        }
    }

    private func syncFromEngine() {
        if let e = engine.event(id) {
            month = e.month; day = e.day; start = e.startHour; end = e.endHour
        } else if let b = engine
            .band(id) {
            itemYear = b.year; month = b.month; startDay = b.startDay; endDay = b.endDay; track = b.track
        } else if let d = engine.deadline(id) {
            itemYear = d.year; month = d.month; day = d.day; hour = d.hour
        }
    }

    private func commitTitle(_ v: String) {
        switch kind {
        case .timed: engine.update(id) { $0.title = v }
        case .band: engine.updateBand(id) { $0.title = v }
        case .deadline: engine.updateDeadline(id) { $0.title = v }
        }
    }

    private func commitColor(_ v: String) {
        // Imported events have no editable body — their color is a local overlay keyed by series.
        if imported {
            engine.setColorOverride(id, v); return
        }
        switch kind {
        case .timed: engine.update(id) { $0.color = v }
        case .band: engine.updateBand(id) { $0.color = v }
        case .deadline: engine.updateDeadline(id) { $0.color = v }
        }
    }
}

/// GIF-recording cues for the drawer (bundled into ONE modifier link — inline onChanges tipped the
/// type-checker budget): expand the Configuration section, and apply a repeat rule as if chosen in the
/// pickers (updates the drawer's own state AND commits through the engine).
private struct DemoDrawerCues: ViewModifier {
    let configPulse: Int
    let repeatFeed: Repeat?
    @Binding var configOpen: Bool
    @Binding var rep: Repeat
    var commit: (Repeat) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: configPulse) { _, _ in withAnimation(.easeInOut(duration: 0.2)) { configOpen = true } }
            .onChange(of: repeatFeed) { _, r in
                guard let r else { return }
                rep = r
                commit(r)
            }
    }
}
