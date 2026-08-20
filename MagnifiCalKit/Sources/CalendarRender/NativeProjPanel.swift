// The NATIVE PROJ (gantt) panel — the Swift port of dashboard.ts projChartHTML (webview
// retirement phase 2), shown for the pinned week/month panel's PROJ tab behind cc.nativeDash.
// Per project: a label column of REAL todo rows (the house 15px DashCheckbox toggles the source
// line, titles open the event) beside a percent-projected timeline — every row gets a GREY
// ROUNDED TRACK (the web's .cc-proj-track) with its bars inset inside; crossed-due segments are
// hatched; uncrossed dues render as ticks; deadline rules + labels, event boxes, the wall-clock
// now pill, the This Week/Month band, and two axis rows. Sized for readability: 26pt row pitch,
// 13pt labels (the TODO list's size), 10pt+ chrome text.

import CalendarEngine
import CalendarGeometry
import SwiftUI

#if os(macOS)
    import AppKit
#endif

public struct NativeProjPanel: View {
    let engine: CalendarEngine
    let scope: String // "week" | "month"
    let key: String
    let theme: Theme
    var onOpen: (String, Int?, String?) -> Void
    var onJump: (String, Int?) -> Void = { _, _ in }
    /// Row-menu Delete: publish (item text, confirm action) up to the window-level dialog host
    /// — the confirm's blur must cover the WHOLE window, not just this panel.
    var onDeleteRequest: (String, @escaping () -> Void) -> Void = { _, _ in }

    /// Explicit init mirroring the old memberwise defaults (public — the module boundary
    /// dropped the free memberwise init when the panel moved to CalendarRender).
    public init(engine: CalendarEngine, scope: String, key: String, theme: Theme,
                onOpen: @escaping (String, Int?, String?) -> Void,
                onJump: @escaping (String, Int?) -> Void = { _, _ in },
                onDeleteRequest: @escaping (String, @escaping () -> Void) -> Void = { _, _ in }) {
        self.engine = engine
        self.scope = scope
        self.key = key
        self.theme = theme
        self.onOpen = onOpen
        self.onJump = onJump
        self.onDeleteRequest = onDeleteRequest
    }

    @State private var expanded: String? // accordion: at most one project shows ALL rows

    /// The TODO panel's freeze pattern: the project ORDER and each project's score-ranked task
    /// membership are frozen per render basis and refreshed only at full-render boundaries
    /// (first render, panel re-key, or an EXTERNAL data change). A self-toggle adopts its own
    /// write's stamp instead, so checking a box re-renders the same chart shape — no project
    /// reshuffle mid-click — and the @State write is ALSO what re-renders the panel instantly
    /// while the carousel's render clock sleeps (nothing else invalidates a paused panel).
    private struct Frozen {
        var basis: String // scope|key
        var stamp: String // engine.todoDataStamp the structure was built from / has adopted
        var order: [(key: String, ranked: [String])] // project → byScore task anchors
    }

    @State private var frozen: Frozen?
    @State private var quickAddHovering = false // pointer over ANY chart's quick-add row

    public static let rowH: CGFloat = 26 // row pitch (label row == track row)
    public static let trackH: CGFloat = 20 // the grey track's height within the row
    /// Bar-segment opacity — tune to taste. LIGHT: .60 of the hue over a near-white track
    /// reads as a pleasant tint (the web shipped .85). DARK needs MORE alpha, not less: the
    /// same alpha composites the color into the dark track and washes it grey — the "faded,
    /// low-saturation" dark gantt.
    static let barOpacity: Double = 0.60
    static let barOpacityDark: Double = 0.85

    static func barOpacity(dark: Bool) -> Double {
        dark ? barOpacityDark : barOpacity
    }

    public var body: some View {
        // OBSERVABLE dependency on note content (NoteEditGen, the preview-repaint pattern):
        // a quick-add or row-menu write at REST must repaint through Observation — wake()'s
        // ticks can be ZERO on an idle ProMotion display, and unlike a checkbox toggle these
        // writes touch no @State (the "new item only shows after app-switching" bug).
        let _ = engine.noteEdits.gen
        let today = NativeDashPanel.todayIso()
        let (rs, re) = range
        let feed = ProjIndex.shown(engine.projFeed(today: today), rs: rs, re: re)
        let order = frozenOrder(feed, today: today)
        let byKey = Dictionary(feed.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let liveTask = Dictionary(feed.flatMap { p in p.tasks.map { (NativeDashPanel.anchor($0.todo), $0) } },
                                  uniquingKeysWith: { a, _ in a })
        ScrollView {
            // LAZY charts: a dense store mounts only near-viewport projects — the full-list
            // build was the "first ⌘J is the most noticeable" hitch (every chart's rows,
            // tracks, and axes entered the AttributeGraph at once).
            LazyVStack(alignment: .leading, spacing: 22) {
                if order.isEmpty {
                    Text("No projects here yet. Tag todo items with @project:your-project — they show up right here.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text.opacity(0.5))
                        .padding(.top, 6)
                }
                ForEach(order, id: \.key) { entry in
                    if let p = byKey[entry.key] {
                        projectSection(p, ranked: entry.ranked, liveTask: liveTask,
                                       today: today, rs: rs, re: re)
                    }
                }
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        #if os(macOS)
            // Click-away unfocus: a click anywhere in the panel OUTSIDE the quick-add row drops
            // the field's focus. Simultaneous → row/checkbox/title clicks keep working untouched;
            // the row's own tap re-sets focus and its hover guard keeps this no-op there.
            // (macOS-only: iOS has no NSApp; the drawer dismiss handles keyboard resign there.)
            .simultaneousGesture(TapGesture().onEnded {
                if !quickAddHovering {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            })
        #endif
    }

    // ── Row-menu writes (the right-click callout's actions) ──────────────────────────────────

    /// One-line token rewrite through toggleTodo's exact source routing + the serve-stale
    /// refresh. `adopt` = the onToggle pattern (our own write keeps the frozen order — no
    /// reshuffle); structural writes (hide/delete) pass false so the refreeze drops the row.
    private func rewrite(_ t: ParsedTodo, adopt: Bool, _ transform: (String, Int) -> String?) {
        NativeDashPanel.rewriteTodoLine(engine, t, transform)
        engine.wake() // repaint now — the paused render clock won't (see quickAdd)
        if adopt {
            frozen?.stamp = engine.todoDataStamp
        }
    }

    /// The row callout's write actions — assignment-style construction (EventMenuActions'
    /// pattern; never grow a many-argument call here). All closures act on the ParsedTodo
    /// source line (the shared TodoRowCallout shape); Check/Uncheck and Go to Definition
    /// reuse the chart rows' exact toggle/open behavior.
    private func rowMenuActions() -> TodoRowMenuActions {
        var a = TodoRowMenuActions()
        a.toggle = { t in
            NativeDashPanel.toggleTodo(engine, t)
            engine.todoFeedRefreshNow(today: NativeDashPanel.todayIso()) // serve-stale: land it NOW
            frozen?.stamp = engine.todoDataStamp // our own write — no refreeze/reshuffle
        }
        a.openTodo = { t in
            if t.source == "event" {
                onOpen(t.eventId, t.line, t.occurrenceKey)
            } // event drawer
            else if let key = t.dailyDate {
                onJump(key, t.line)
            } // fly to the note
        }
        a.setColor = { t, c in rewrite(t, adopt: true) { TodoIndex.setColorToken($0, line: $1, color: c) } }
        a.pin = { t in rewrite(t, adopt: true) { TodoIndex.addTag($0, line: $1, tag: "proj-pinned") } }
        a.unpin = { t in rewrite(t, adopt: true) { TodoIndex.removeTag($0, line: $1, tag: "proj-pinned") } }
        a.setPriority = { t, n in rewrite(t, adopt: true) { TodoIndex.setPriority($0, line: $1, level: n) } }
        a.clearPriority = { t in rewrite(t, adopt: true) { TodoIndex.removePriority($0, line: $1) } }
        a.hide = { t in rewrite(t, adopt: false) { TodoIndex.addTag($0, line: $1, tag: "proj-hide") } }
        a.delete = { t in // window-level confirm dialog first; the closure is the yes-path
            onDeleteRequest(t.text) { confirmDelete(t) }
        }
        return a
    }

    private func confirmDelete(_ t: ParsedTodo) {
        rewrite(t, adopt: false) { TodoIndex.removeTodoLine($0, line: $1) }
    }

    /// See Frozen. Rebuilt only when basis/stamp move; @State writes hop off the render pass.
    private func frozenOrder(_ projects: [Project], today: String) -> [(key: String, ranked: [String])] {
        let basis = "\(scope)|\(key)"
        let stamp = engine.todoDataStamp
        if let f = frozen, f.basis == basis, f.stamp == stamp {
            return f.order
        }
        return NativeDash.diagTime("projFrozenOrder(\(scope)|\(key))") {
            // Scores are computed ONCE per task, then sorted — a score inside the comparator ran
            // O(n log n) times and made this the single hottest block on tab open (~90ms release,
            // several× that in debug, on a 500-task year).
            let order = projects.map { p in
                (key: p.key,
                 ranked: p.tasks
                     .map { (score: ProjIndex.taskScore($0, today: today), anchor: NativeDashPanel.anchor($0.todo)) }
                     .sorted { $0.score > $1.score }
                     .map(\.anchor))
            }
            let f = Frozen(basis: basis, stamp: stamp, order: order)
            DispatchQueue.main.async { frozen = f }
            return order
        }
    }

    private var range: (String, String) {
        switch scope {
        case "day": (key, key)
        case "week": (key, TodoIndex.addDuration(key, 6, "d"))
        default: ("\(key)-01", CalendarEngine.monthEndIso(key))
        }
    }

    @ViewBuilder
    private func projectSection(_ p: Project, ranked: [String], liveTask: [String: ProjTask],
                                today: String, rs: String, re: String) -> some View {
        let showAll = expanded == p.key
        // FROZEN membership/rank, LIVE rows: each anchor renders the current parse of its line
        // in its frozen slot (checked state updates in place, no reshuffle).
        let byScore = ranked.compactMap { liveTask[$0] }
        // Chart order: pinned rows on top (newest first), the rest chronological. Pinned rows
        // are ALWAYS members — the quick-add's "appears on top" guarantee must survive the
        // collapsed view's score clamp, so #proj-pinned rows join the visible set even when
        // their score ranks below the top maxRows.
        let clamped = showAll ? byScore : Array(byScore.prefix(ProjIndex.maxRows))
        let clampedOut = showAll ? [] : byScore.dropFirst(ProjIndex.maxRows)
            .filter { $0.todo.tags.contains("proj-pinned") }
        let visible = ProjIndex.chartRows(clamped + clampedOut)
        let foldable = byScore.count > ProjIndex.maxRows
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: p.key, count: byScore.count,
                          hidden: showAll ? 0 : byScore.count - visible.count,
                          chevron: foldable, open: showAll, theme: theme) {
                withAnimation(.easeInOut(duration: 0.28)) { // = PROJ_ANIM_MS
                    expanded = showAll ? nil : p.key // accordion: opening one closes the other
                }
            }
            ProjChart(project: p, tasks: visible, today: today, rs: rs, re: re, scope: scope,
                      theme: theme,
                      onToggle: { t in
                          NativeDashPanel.toggleTodo(engine, t.todo)
                          engine.todoFeedRefreshNow(today: today) // serve-stale: land it NOW
                          // Our own write: adopt its stamp (no refreeze/reshuffle) — and this
                          // @State write is what re-renders the panel RIGHT NOW; the paused
                          // render clock wouldn't until the next mouse move woke it.
                          frozen?.stamp = engine.todoDataStamp
                      },
                      onOpen: onOpen,
                      onOpenTodo: { t in
                          if t.source == "event" {
                              onOpen(t.eventId, t.line, t.occurrenceKey)
                          } // event drawer
                          else if let key = t.dailyDate {
                              onJump(key, t.line)
                          } // fly to the note
                      },
                      onQuickAdd: { quickAdd(p.key, $0) },
                      onQuickAddHover: { quickAddHovering = $0 },
                      menuActions: rowMenuActions())
        }
    }

    /// The quick-add submit: append the typed todo into THIS panel's scope note (the same
    /// storage key the NOTE tab edits — see NativeNotePanel), @project-tagged + pinned +
    /// created-stamped, then land the coalesced feed refresh NOW so the chart gains its row
    /// immediately. No navigation — the field stays put for the next item.
    private func quickAdd(_ project: String, _ text: String) {
        let todo = text.trimmingCharacters(in: .whitespaces)
        guard !todo.isEmpty else { return }
        let storageKey = scope == "day" ? key
            : scope == "week" ? "week:\(key)" : "month:\(key)"
        // The note editor's stampCreated() format: minute precision, YYYY-MM-DDTHH:mm.
        let stamp = NativeDashPanel.todayIso() + "T" + String(NativeDashPanel.clockNow().prefix(5))
        let next = TodoIndex.appendProjectTodo(note: engine.dailyNote(storageKey),
                                               project: project, todo: todo, stamp: stamp)
        engine.setDailyNote(storageKey, next)
        engine.todoFeedRefreshNow(today: NativeDashPanel.todayIso())
        engine.wake() // repaint now — the paused render clock won't (see NativeNotePanel)
    }
}

/// One project's chart: the label column (32% of the width, like the web) beside the projected
/// plot; label rows and grey tracks share the same row pitch so they stay aligned 1:1.
private struct ProjChart: View {
    let project: Project
    let tasks: [ProjTask]
    let today: String
    let rs: String
    let re: String
    let scope: String
    let theme: Theme
    var onToggle: (ProjTask) -> Void
    var onOpen: (String, Int?, String?) -> Void
    var onOpenTodo: (ParsedTodo) -> Void
    var onQuickAdd: (String) -> Void
    var onQuickAddHover: (Bool) -> Void = { _ in } // reports up: the panel's click-away guard
    var menuActions: TodoRowMenuActions = .init()

    @State private var frontLabel: String? // hovered deadline/event label: raised above the rest
    @State private var draft = "" // the quick-add field's in-progress text
    @State private var quickAddHover = false // one hover state for the whole row, "+" included
    @State private var hoveredRow: String? // the ONE hovered gantt row (rowId); others' bars dim
    @State private var menuPreview: String? // palette hover in the row callout → live bar tint
    @State private var rowMenu: RowMenu? // the right-click callout's row + anchor rect
    @FocusState private var draftFocused: Bool

    private struct RowMenu {
        var task: ProjTask
        var anchor: CGRect // in chart space (the popover's attachment rect)
    }

    private var headroom: CGFloat {
        // 1-row case: 24 (was 18) so the quick-add row keeps breathing room under the project
        // header; the deadline/event-label case stays 36.
        project.deadlines.isEmpty && project.events.isEmpty ? 24 : 36
    }

    private var chartHeight: CGFloat {
        headroom + CGFloat(tasks.count) * NativeProjPanel.rowH + 36 // + the two axis rows
    }

    var body: some View {
        let scale = ChartScale(project: project, tasks: tasks, today: today, rs: rs, re: re)
        GeometryReader { geo in
            let labelW = max(120, geo.size.width * 0.32)
            let plotW = max(40, geo.size.width - labelW - 10)
            ZStack(alignment: .topLeading) {
                #if os(macOS)
                    // BEHIND the columns: ONE AppKit mouse layer per chart. NSView tracking areas
                    // fire regardless of the SwiftUI content drawn above (unlike .onHover, which
                    // goes to the topmost hit-testable view — strips behind the row buttons/plot
                    // shapes never heard a thing: the "hover doesn't show" bug). It owns hover
                    // row-tracking AND the right-click; left clicks pass through untouched.
                    // iOS compiles it out: hover/right-click are pointer affordances, and the
                    // phone client is read-only.
                    ChartMouseLayer(headroom: headroom, rowH: NativeProjPanel.rowH,
                                    rowCount: tasks.count,
                                    onHover: { idx in
                                        hoveredRow = idx.map { tasks[$0].rowId }
                                    },
                                    onRightClick: { idx, p in
                                        guard idx < tasks.count else { return }
                                        rowMenu = RowMenu(task: tasks[idx],
                                                          anchor: CGRect(x: p.x, y: p.y,
                                                                         width: 1, height: 1))
                                    })
                #endif
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The quick-add row rides INSIDE the existing headroom strip (bottom-
                        // aligned, right above the top row) — no extra chart height.
                        Color.clear.frame(height: headroom)
                            .overlay(alignment: .bottomLeading) {
                                if !NativeDash.readOnly {
                                    quickAddRow // read-only drawer (iPhone): no authoring row
                                }
                            }
                        ForEach(tasks, id: \.rowId) { t in
                            labelRow(t).transition(.rowReveal)
                        }
                    }
                    .frame(width: labelW, alignment: .leading)
                    plot(scale, w: plotW)
                        .frame(width: plotW, alignment: .topLeading)
                }
                // IN FRONT of the columns: the wash strips, rendering-only (no hit-testing) —
                // behind the columns the wash vanished under the plot's opaque grey tracks.
                // At 0.05 alpha the over-wash reads as a row highlight, not a tint.
                rowStrips(fullW: geo.size.width)
                    .allowsHitTesting(false)
            }
            .popover(isPresented: menuShown,
                     attachmentAnchor: .rect(.rect(rowMenu?.anchor ?? .zero)),
                     arrowEdge: .trailing) {
                if let m = rowMenu {
                    TodoRowCallout(todo: m.task.todo, done: m.task.end != nil,
                                   pinTag: "proj-pinned", theme: theme, actions: menuActions,
                                   onColorPreview: { menuPreview = $0 },
                                   onClose: { rowMenu = nil; menuPreview = nil })
                }
            }
        }
        .frame(height: chartHeight)
    }

    private var menuShown: Binding<Bool> {
        Binding(get: { rowMenu != nil }, set: { v in
            if !v {
                rowMenu = nil
                menuPreview = nil // a closed menu leaves no preview tint behind
            }
        })
    }

    /// The full-width row layer: per row, ONE strip aligned to y = headroom + index·rowH that
    /// (a) paints the quick-add row's exact hover wash across label column + plot, (b) tracks
    /// the single hovered row (other rows' bars dim off it), and (c) carries the right-click
    /// catcher. It sits BEHIND the row content and owns no left-click gesture, so checkbox
    /// toggles and title clicks land exactly as before.
    private func rowStrips(fullW: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.rowId) { i, t in
                rowStrip(t, index: i, fullW: fullW).transition(.rowReveal)
            }
        }
        .padding(.top, headroom)
        .animation(.easeOut(duration: 0.12), value: hoveredRow)
    }

    private func rowStrip(_ t: ProjTask, index _: Int, fullW: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6) // = the quick-add wash (same fill, all corners round)
            .fill(theme.text.opacity(hoveredRow == t.rowId ? 0.05 : 0))
            .frame(width: fullW, height: NativeProjPanel.rowH)
    }

    /// The compact quick-add input: a "+" in the checkbox column (15pt + the row's 8pt gap),
    /// then a borderless field aligned with the todo titles. Enter submits into the panel's
    /// scope note, clears, and KEEPS focus so several items can be typed in a row. The whole
    /// row (including the "+") hovers as one and a click anywhere on it focuses the field.
    private var quickAddRow: some View {
        HStack(spacing: 8) {
            Text("+")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text.opacity(quickAddHover ? 0.5 : 0.3))
                .frame(width: 15) // = DashCheckbox(size: 15)'s column
            TextField("", text: $draft,
                      prompt: Text("new todo...") // lowercase + extra-light: an affordance, not a row
                          .foregroundStyle(theme.text.opacity(quickAddHover ? 0.35 : 0.2)))
                .textFieldStyle(.plain)
                .font(.system(size: 13)) // the row-title size
                .foregroundStyle(theme.text.opacity(0.55))
                .focused($draftFocused)
                .onSubmit {
                    onQuickAdd(draft)
                    draft = ""
                    draftFocused = true
                }
        }
        // Row pitch = the TODO rows' (26pt), bottom-aligned in the headroom — the content
        // sits a touch higher than the old 18pt strip and the spacing above the first row
        // matches the list's own rhythm.
        .frame(height: NativeProjPanel.rowH, alignment: .center)
        .contentShape(Rectangle()) // the "+" and the blank tail are clickable too
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.text.opacity(quickAddHover ? 0.05 : 0))
                // Trailing only: a -4 leading poked past the column's x=0 clip, which squared
                // the wash's LEFT corners; at 0 all four corners render rounded and the "+" /
                // text alignment with the checkbox/title columns is untouched.
                .padding(.trailing, -4)
        )
        .onHover { quickAddHover = $0; onQuickAddHover($0) }
        .onTapGesture { draftFocused = true } // clicking the "+" region focuses the field
        .animation(.easeOut(duration: 0.12), value: quickAddHover)
    }

    private func labelRow(_ t: ProjTask) -> some View {
        let done = t.end != nil
        return HStack(spacing: 8) {
            DashCheckbox(checked: done, size: 15) { onToggle(t) }
                .handCursor()
            Button { onOpenTodo(t.todo) } label: {
                HStack(spacing: 4) {
                    // Pinned rows (#proj-pinned, THIS panel's tag — the TODO panel's #pinned
                    // shows no pin here): the accent pin, the shared pin language.
                    if t.todo.tags.contains(where: { $0.lowercased() == "proj-pinned" }) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    // The title is render-only (allowsHitTesting false): Text otherwise claims
                    // the pointer over a clickable row — the label's contentShape carries the
                    // clicks, handCursor the pointing hand.
                    ProjLabelTitle(text: t.todo.text, done: done,
                                   hovering: hoveredRow == t.rowId, theme: theme)
                }
                .allowsHitTesting(false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
        }
        .frame(height: NativeProjPanel.rowH, alignment: .leading)
        .help(t.todo.text)
    }

    private func plot(_ scale: ChartScale, w: CGFloat) -> some View {
        let rowsH = CGFloat(tasks.count) * NativeProjPanel.rowH
        let plotH = headroom + rowsH
        // Vertical marks span the TRACK ROWS only (the web's plotarea: 2px above the first
        // track to 2px past the last), never the headroom strip — labels live up there.
        let trackInset = (NativeProjPanel.rowH - NativeProjPanel.trackH) / 2
        let rowTop = headroom + trackInset - 2
        let marksH = rowsH - 2 * trackInset + 4
        return ZStack(alignment: .topLeading) {
            viewMark(scale, w: w, rowTop: rowTop, marksH: marksH)
            deadlineRules(scale, w: w, rowTop: rowTop, marksH: marksH)
            nowLine(scale, w: w, rowTop: rowTop, marksH: marksH)
            taskTracks(scale, w: w)
            eventBoxes(scale, w: w, rowsH: rowsH)
            axes(scale, w: w, plotH: plotH)
        }
    }

    // ── Overlays ─────────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func viewMark(_ s: ChartScale, w: CGFloat, rowTop: CGFloat, marksH: CGFloat) -> some View {
        let l = s.x(rs) * w
        let r = s.x(TodoIndex.addDuration(re, 1, "d")) * w // end-day inclusive
        if scope == "day" {
            // .cc-proj-dayline: the viewed day as a single solid dark rule (no band, no label).
            Rectangle().fill(theme.accentDark.opacity(0.9))
                .frame(width: 1.5, height: marksH)
                .offset(x: l, y: rowTop)
        } else {
            // .cc-proj-viewband: neutral GREY (the accent red is reserved for the now line) —
            // grey wash + solid accent-grey edges, spanning the track rows only.
            Rectangle().fill(Color.gray.opacity(0.14))
                .frame(width: max(1, r - l), height: marksH)
                .offset(x: l, y: rowTop)
            Rectangle().fill(theme.accentGrey).frame(width: 1.5, height: marksH).offset(x: l, y: rowTop)
            Rectangle().fill(theme.accentGrey).frame(width: 1.5, height: marksH).offset(x: r - 1.5, y: rowTop)
            Text(scope == "week" ? "This Week" : "This Month")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.accentGrey)
                .position(x: (l + r) / 2, y: headroom - 9)
        }
    }

    private func deadlineRules(_ s: ChartScale, w: CGFloat, rowTop: CGFloat, marksH: CGFloat) -> some View {
        ForEach(project.deadlines, id: \.id) { d in
            let iso = String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)
            let px = s.x(iso) * w
            let color = theme.eventBorder(d.color)
            // The rule runs from just under its top-layer label all the way down the tracks.
            let lineTop: CGFloat = 15
            Path { p in // .cc-proj-dlline: thin + DASHED in the deadline's own color
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: 0, y: rowTop + marksH - lineTop))
            }
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(width: 1, height: rowTop + marksH - lineTop)
            .offset(x: px, y: lineTop)
            Button { onOpen(d.id, nil, nil) } label: {
                Text(d.title.isEmpty ? "(deadline)" : d.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .kerning(0.3)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .handCursor()
            .labelChip(theme, hover: { frontLabel = $0 ? d.id : nil })
            .position(x: px, y: 7)
            .zIndex(frontLabel == d.id ? 10 : 3)
        }
    }

    @ViewBuilder
    private func nowLine(_ s: ChartScale, w: CGFloat, rowTop: CGFloat, marksH: CGFloat) -> some View {
        let cal = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let frac = Double((cal.hour ?? 0) * 60 + (cal.minute ?? 0)) / 1440
        let px = s.x(today, frac: frac) * w
        let accent = theme.eventBorder("red")
        Rectangle().fill(accent.opacity(0.95)).frame(width: 1.5, height: marksH)
            .offset(x: px, y: rowTop)
        // The top pill on the now-line stays "now" (wall-clock marker); only the AXIS label
        // under the chart says "today" (user spec).
        Text("now")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(accent))
            .position(x: px, y: headroom - 9)
    }

    /// The row area: one GREY ROUNDED TRACK per task (the web's .cc-proj-track — full plot
    /// width, rgba-grey wash), with the task's bars inset 1pt inside it.
    private func taskTracks(_ s: ChartScale, w: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(tasks, id: \.rowId) { t in
                trackRow(t, s, w: w).transition(.rowReveal)
            }
        }
        .padding(.top, headroom)
        .animation(.easeOut(duration: 0.12), value: hoveredRow) // hover dim fade
    }

    @ViewBuilder
    private func trackRow(_ t: ProjTask, _ s: ChartScale, w: CGFloat) -> some View {
        // Palette hover in the open row menu tints THIS row's bars live (commit rewrites the
        // line's color: token; the preview is render-only).
        // DARK: the border palette is deliberately PASTEL (tuned for 1-2px strokes on a dark
        // ground) — as an area fill it has no saturation to give. Fills take the saturated
        // hue (eventColor); light mode keeps the border hue it was tuned on.
        let key = (rowMenu?.task.rowId == t.rowId ? menuPreview : nil) ?? t.color
        let color = theme.dark ? theme.eventColor(key) : theme.eventBorder(key)
        let end = t.end ?? today
        // Row hover: every OTHER row's bar segments (and due ticks) fade back; the hovered
        // row's stay at barOpacity. Grey tracks and axes are untouched.
        let dim = hoveredRow != nil && hoveredRow != t.rowId
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.12)) // the missing grey track
                .frame(width: w, height: NativeProjPanel.trackH)
            // The bar taxonomy: one solid bar to done/now; a crossed due splits solid|hatched;
            // an uncrossed future due renders as a tick in the row's color.
            if let due = t.due, end > due {
                if t.start < due {
                    bar(s, w, t.start, due, color, over: false, dim: dim)
                    bar(s, w, due, end, color, over: true, dim: dim)
                } else {
                    bar(s, w, t.start, end, color, over: true, dim: dim)
                }
            } else {
                bar(s, w, t.start, end, color, over: false, dim: dim)
                if let due = t.due, due > end {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.opacity(0.8 * (dim ? 0.35 : 1)))
                        .frame(width: 2, height: NativeProjPanel.trackH)
                        .offset(x: s.x(due) * w - 1)
                }
            }
        }
        .frame(width: w, height: NativeProjPanel.rowH, alignment: .leading)
    }

    private func bar(_ s: ChartScale, _ w: CGFloat, _ a: String, _ b: String, _ color: Color,
                     over: Bool, dim: Bool) -> some View {
        let l = s.x(a) * w
        let width = max(5, s.x(b) * w - l)
        return RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(NativeProjPanel.barOpacity(dark: theme.dark) * (dim ? 0.35 : 1))) // open and done alike
            .overlay {
                if over { // past-due portion: the web's 45° hatch
                    Hatch().stroke(Color.black.opacity(0.3), lineWidth: 2.2)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(width: width, height: NativeProjPanel.trackH - 2)
            .offset(x: l)
    }

    private func eventBoxes(_ s: ChartScale, w: CGFloat, rowsH: CGFloat) -> some View {
        ForEach(project.events.indices, id: \.self) { i in
            let ev = project.events[i]
            let color = theme.dark ? theme.eventColor(ev.color) : theme.eventBorder(ev.color)
            let l = s.x(ev.start) * w
            let width = max(8, s.x(TodoIndex.addDuration(ev.end, 1, "d")) * w - l)
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(color.opacity(0.6), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.08)))
                .frame(width: width, height: rowsH)
                .offset(x: l, y: headroom)
                .allowsHitTesting(false)
            // The name rides centered on the box: SAME placement chain as the box itself
            // (a box-width positioning frame + the identical offset), so the two centers
            // coincide by construction — the chip just overhangs symmetrically if wider.
            Button { onOpen(ev.id, nil, nil) } label: {
                Text(ev.title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .handCursor()
            .labelChip(theme, hover: { frontLabel = $0 ? ev.id : nil })
            .frame(width: width, height: 18)
            .offset(x: l, y: headroom - 33)
            .zIndex(frontLabel == ev.id ? 10 : 2)
        }
    }

    /// Two axis rows below the plot: relative days from now, then calendar boundaries
    /// (Sundays on short spans, month firsts otherwise).
    @ViewBuilder
    private func axes(_ s: ChartScale, w: CGFloat, plotH: CGFloat) -> some View {
        let span = s.span
        let step = span <= 42 ? 7 : span <= 100 ? 30 : span <= 240 ? 60 : 90
        let firstK = Int(ceil(Double(-ProjIndex.daysBetween(s.lo, today)) / Double(step))) * step
        let axisColor = theme.text.opacity(0.5)
        let lineY = plotH + 17 // the .cc-proj-months border-top: between the two axis rows
        Rectangle().fill(Color.gray.opacity(0.25))
            .frame(width: w, height: 1)
            .offset(y: lineY)
        ForEach(Array(stride(from: firstK, through: firstK + 12 * step, by: step)), id: \.self) { k in
            let iso = TodoIndex.addDuration(today, k, "d")
            if iso >= s.lo, iso <= s.hi {
                Text(k == 0 ? "today" : k < 0 ? "\(-k)d ago" : "in \(k)d")
                    .font(.system(size: 10))
                    .foregroundStyle(axisColor)
                    .position(x: s.x(iso) * w, y: plotH + 9)
                Rectangle().fill(axisColor) // its tick: above the line, pointing down at it
                    .frame(width: 1, height: 3)
                    .position(x: s.x(iso) * w, y: lineY - 1)
            }
        }
        ForEach(calendarTicks(s), id: \.0) { iso, label in
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(axisColor)
                .position(x: s.x(iso) * w, y: plotH + 26)
            Rectangle().fill(axisColor) // its tick: below the line
                .frame(width: 1, height: 3)
                .position(x: s.x(iso) * w, y: lineY + 2)
        }
    }

    private func calendarTicks(_ s: ChartScale) -> [(String, String)] {
        let mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var out: [(String, String)] = []
        if s.span <= 60 { // week boundaries: Sundays as "Jul 6"
            let p = s.lo.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3,
                  let d0 = utcCalendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
            else { return out }
            let dow = utcCalendar.component(.weekday, from: d0) - 1 // 0 = Sunday
            var iso = TodoIndex.addDuration(s.lo, (7 - dow) % 7, "d")
            while iso <= s.hi, out.count < 16 {
                let q = iso.split(separator: "-").compactMap { Int($0) }
                if q.count == 3 {
                    out.append((iso, "\(mo[q[1] - 1]) \(q[2])"))
                }
                iso = TodoIndex.addDuration(iso, 7, "d")
            }
        } else { // month firsts, year-stamped at January
            var p = s.lo.split(separator: "-").compactMap { Int($0) }
            guard p.count >= 2 else { return out }
            p[1] += 1
            if p[1] > 12 {
                p[1] = 1; p[0] += 1
            }
            while out.count < 16 {
                let iso = String(format: "%04d-%02d-01", p[0], p[1])
                if iso > s.hi {
                    break
                }
                out.append((iso, "\(mo[p[1] - 1])\(p[1] == 1 ? " ’\(String(format: "%02d", p[0] % 100))" : "")"))
                p[1] += 1
                if p[1] > 12 {
                    p[1] = 1; p[0] += 1
                }
            }
        }
        return out
    }
}

#if os(macOS)
    /// An AppKit right-click catcher riding as a row strip's BACKGROUND: SwiftUI controls ignore
    /// rightMouseDown, so this NSView hit-tests ONLY right-button events — left clicks (and the
    /// panel's tap gesture) fall through to the SwiftUI content above untouched. Reports the click
    /// point in the view's own top-left-origin space (the strip is flipped to match SwiftUI).
    /// One AppKit mouse layer per chart: hover row-tracking via an NSTrackingArea — which fires
    /// regardless of the SwiftUI content drawn above it, unlike .onHover — plus the right-click.
    /// hitTest bites ONLY on right-button events, so every left click passes through to the
    /// SwiftUI rows exactly as before. Reports row indices computed from the shared row grid
    /// (headroom + index·rowH) and points in the chart's (flipped) coordinate space.
    private struct ChartMouseLayer: NSViewRepresentable {
        var headroom: CGFloat
        var rowH: CGFloat
        var rowCount: Int
        var onHover: (Int?) -> Void
        var onRightClick: (Int, CGPoint) -> Void

        func makeNSView(context _: Context) -> Layer {
            let v = Layer()
            apply(to: v)
            return v
        }

        func updateNSView(_ v: Layer, context _: Context) {
            apply(to: v)
        }

        private func apply(to v: Layer) {
            v.headroom = headroom
            v.rowH = rowH
            v.rowCount = rowCount
            v.onHover = onHover
            v.onRightClick = onRightClick
        }

        final class Layer: NSView {
            var headroom: CGFloat = 0
            var rowH: CGFloat = 26
            var rowCount = 0
            var onHover: ((Int?) -> Void)?
            var onRightClick: ((Int, CGPoint) -> Void)?
            private var lastRow: Int? = -1 // -1 ≠ nil: force the first report

            override var isFlipped: Bool {
                true
            } // row 0 at the top, like the SwiftUI layout

            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                trackingAreas.forEach(removeTrackingArea)
                addTrackingArea(NSTrackingArea(
                    rect: .zero,
                    options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self, userInfo: nil
                ))
            }

            private func row(at p: CGPoint) -> Int? {
                let i = Int((p.y - headroom) / rowH)
                return p.y >= headroom && i >= 0 && i < rowCount ? i : nil
            }

            private func report(_ r: Int?) {
                if r != lastRow {
                    lastRow = r
                    onHover?(r)
                }
            }

            override func mouseEntered(with event: NSEvent) {
                guard effectivelyVisible else { return }
                report(row(at: convert(event.locationInWindow, from: nil)))
            }

            override func mouseMoved(with event: NSEvent) {
                guard effectivelyVisible else { return }
                report(row(at: convert(event.locationInWindow, from: nil)))
            }

            override func mouseExited(with _: NSEvent) {
                report(nil)
            }

            /// Never the hit-test target: every click belongs to the SwiftUI rows. Right-clicks
            /// arrive via a LOCAL EVENT MONITOR instead — AppKit hit-testing routed them to other
            /// views over the row text / timeline shapes, which made the menu work only on the
            /// row's empty stretches.
            override func hitTest(_: NSPoint) -> NSView? {
                nil
            }

            /// Parked/warmed twins of this chart stay mounted at opacity 0 AT THE SAME SCREEN
            /// POSITION — their monitors must not steal the live chart's right-clicks (they
            /// resolved a DIFFERENT month/week's row at the click point: the "menu shows the
            /// wrong check state on some items" bug). Same guard as the TODO panel's layer.
            private var effectivelyVisible: Bool {
                guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
                var l = layer
                while let cur = l {
                    if cur.opacity < 0.01 {
                        return false
                    }
                    l = cur.superlayer
                }
                return true
            }

            private var rightClickMonitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window == nil {
                    if let m = rightClickMonitor {
                        NSEvent.removeMonitor(m)
                        rightClickMonitor = nil
                    }
                } else if rightClickMonitor == nil {
                    rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) {
                        [weak self] e in
                        guard let self, e.window === self.window, self.effectivelyVisible
                        else { return e }
                        let p = self.convert(e.locationInWindow, from: nil)
                        guard self.bounds.contains(p), let r = self.row(at: p) else { return e }
                        self.onRightClick?(r, p)
                        return nil // consumed — no pass-through context menus underneath
                    }
                }
            }

            deinit {
                if let m = rightClickMonitor {
                    NSEvent.removeMonitor(m)
                }
            }
        }
    }
#endif

/// The gantt label's check/uncheck animation — the TODO panel's mechanism, single-line: two
/// copies of the SAME text under COMPLEMENTARY left/right masks, the struck accent-grey copy
/// REPLACING the plain one as the `strike` front sweeps (0.26s), retracting on uncheck.
private struct ProjLabelTitle: View {
    let text: String
    let done: Bool
    /// Row hover (the chart's hoveredRow): open titles tint to the ACCENT, done titles lift
    /// to the full text color — the TODO panel's exact hover rule.
    var hovering = false
    let theme: Theme

    @State private var strike: CGFloat = -1 // -1 = unseeded (first render settles, no sweep)

    var body: some View {
        ZStack(alignment: .leading) {
            title(struck: false)
                .mask(
                    GeometryReader { g in
                        Rectangle()
                            .frame(width: g.size.width * max(0, 1 - strike), alignment: .trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                )
            title(struck: true)
                .mask(
                    GeometryReader { g in
                        Rectangle()
                            .frame(width: g.size.width * max(0, strike), alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                )
        }
        .onChange(of: done, initial: true) { _, d in
            if strike < 0 {
                strike = d ? 1 : 0
            } else {
                withAnimation(.easeInOut(duration: 0.26)) { strike = d ? 1 : 0 }
            }
        }
    }

    private func title(struck: Bool) -> some View {
        Text(text)
            .font(.system(size: 13)) // the TODO list's row size
            .strikethrough(struck, color: theme.accentGrey)
            .foregroundStyle(struck ? (hovering ? theme.text : theme.accentGrey)
                : (hovering ? Theme.accent : theme.text))
            .lineLimit(1)
    }
}

private extension ProjTask {
    /// Stable row identity across expand/collapse re-sorts — the TODO panel's anchor
    /// (source scope key + line number). Index identity made SwiftUI read a mid-list
    /// insertion as "every row after it changed content, new rows appended at the end".
    var rowId: String {
        NativeDashPanel.anchor(todo)
    }
}

/// Expand/collapse row reveal — the web's unmasking clip: the row's SLOT animates
/// 0 -> full height over full-size content (no glyph scaling), fading in alongside.
private struct RowReveal: ViewModifier, Animatable {
    var f: CGFloat // 0 = collapsed slot, 1 = full row
    var animatableData: CGFloat {
        get { f }
        set { f = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: NativeProjPanel.rowH * f, alignment: .center)
            .clipped()
            .opacity(Double(f))
    }
}

private extension AnyTransition {
    static let rowReveal = AnyTransition.modifier(active: RowReveal(f: 0),
                                                  identity: RowReveal(f: 1))
}

private extension View {
    /// Headroom-label chip: an opaque page-background pill behind deadline/event names so
    /// overlapping labels mask each other instead of colliding glyph-on-glyph; slight
    /// horizontal padding extends the mask past the text, and hover reports up so the
    /// hovered chip can be raised above every other label.
    func labelChip(_ theme: Theme, hover: @escaping (Bool) -> Void) -> some View {
        padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.bg))
            .onHover(perform: hover)
    }
}

/// The 45° hatch for past-due bar segments (the web's repeating-linear-gradient stripes).
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 6
        var x = -rect.height // start off-left so diagonals cover the whole rect
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return p
    }
}

/// The chart's time projection: earliest visible start → max(now, latest deadline/due/event),
/// the current view window always in frame, plus breathing room (−1d / +3d). x() → 0…1.
private struct ChartScale {
    let lo: String
    let hi: String
    let span: Int

    init(project: Project, tasks: [ProjTask], today: String, rs: String, re: String) {
        var rlo = today, rhi = today
        for t in tasks {
            if t.start < rlo {
                rlo = t.start
            }
            if t.start > rhi {
                rhi = t.start
            }
            let e = t.end ?? today
            if e > rhi {
                rhi = e
            }
            if let due = t.due, due > rhi {
                rhi = due
            }
        }
        for d in project.deadlines {
            let iso = String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)
            if iso < rlo {
                rlo = iso
            }
            if iso > rhi {
                rhi = iso
            }
        }
        for ev in project.events {
            if ev.start < rlo {
                rlo = ev.start
            }
            if ev.end > rhi {
                rhi = ev.end
            }
        }
        if rs < rlo {
            rlo = rs
        }
        if re > rhi {
            rhi = re
        }
        lo = TodoIndex.addDuration(rlo, -1, "d")
        hi = TodoIndex.addDuration(rhi, 3, "d")
        span = max(1, ProjIndex.daysBetween(lo, hi))
    }

    func x(_ iso: String, frac: Double = 0) -> CGFloat {
        let v = (Double(ProjIndex.daysBetween(lo, String(iso.prefix(10)))) + frac) / Double(span)
        return CGFloat(min(1, max(0, v)))
    }
}
