// The calendar surface: a per-frame Canvas driven by TimelineView(.animation),
// with an AppKit input bridge overlay for scroll-wheel / pinch / click / hover.

import CalendarEngine
import CalendarGeometry
import SwiftUI

public struct CalendarView: View {
    @State private var engine = CalendarEngine()
    @State private var ui = CalendarUIState()
    @State private var drawerWidth: CGFloat = 410
    // The drawer's slide-in is a .move transition; a state-mutating hover inside it (the resize
    // handle sweeping under a stationary mouse) re-renders the transitioning subtree and FREEZES
    // the presentation mid-flight (model already final → snaps at the end). Mouse-transparent
    // until the entrance settles, so no hover can fire during the animation.
    @State private var drawerSettling = false
    @State private var monthBridge = MonthPagerBridge()
    @State private var weekBridge = WeekPagerBridge()
    @State private var dayBridge = DayPagerBridge()
    @State private var dashAnim = DashCarouselAnim() // per-frame carousel state for the native tabs
    @State private var catcherHandle = CatcherHandle() // menu/toolbar → catcher clipboard routing
    @State private var dashFrac: CGFloat = 0.45 // mirrors engine.daily.frac; updated live on resize
    @State private var dashTab: DashTab = .todo // dashboard TODO/NOTE tab
    @State private var demo = DemoController() // scripted GIF-recording cursor + scenes (CC_DEMO mode)
    @State private var noteMode: NotesMode = .edit // daily-note edit/preview (native toggle mirrors JS)
    @State private var dashNav = NativeDashNavModel() // native pinned-panel keyboard row cursor
    @State private var dashPinchMag: CGFloat? // in-flight pinch over the native panels (nil = none)
    @State private var search = SearchState() // toolbar event search (⌘F / magnifyingglass)
    @State private var searchAnchor: CGPoint = .zero // content stack's window-space origin (for dropdown alignment)
    @State private var searchCloseWork: DispatchWorkItem? // pending "unmount the bar after it collapses"
    @State private var showTagFilter = false // View ▸ Filter by Tags popover (toolbar-anchored)
    /// Global Performance Mode: render events as flat tinted fills instead of Liquid Glass
    /// (glass is one GPU pass per sticker). Persisted; defaults on for now.
    @AppStorage("cc.performanceMode") private var perfMode = true
    // Bench override: CC_PERF_OFF=1 forces the Liquid-Glass path on (Performance Mode OFF) so the
    // profiler can measure the GPU-heavy path the throwaway store's default (perfMode on) never hits.
    private static let forcePerfOff = ProcessInfo.processInfo.environment["CC_PERF_OFF"] != nil
    private var effPerfMode: Bool {
        perfMode && !Self.forcePerfOff
    }

    // The View-menu prefs (show-hidden, current/alt timezone) → repaint observers live in ViewPrefObservers
    // (bundled into one modifier to keep the body's modifier chain within the Swift type-checker's budget).
    @AppStorage("cc.tutorial.seen") private var tutorialSeen = false // auto-show the onboarding carousel once
    @AppStorage("cc.fpsHUD") private var fpsHUDPref = false // Settings ▸ Developer ▸ frame-rate HUD
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow // opens the standalone Calendar AI window
    // The quick-ask callout's OWN assistant session (app-level; independent of the standalone
    // window's session, sharing only the conversation store). nil (dev shell) → window only.
    private let assistant: AssistantState?
    // The standalone window's session — "Open in window" hands the callout's thread to it.
    private let windowAssistant: AssistantState?
    @State private var showAssistantCallout = false
    @State private var icsDropActive = false // an .ics drag is over the window → show the drop mask

    // Dashboard TODO layering (sources / collections / deadlines per scope) + its callout menu.
    // The menu controller is long-lived state (NSMenuItem.target is weak) and resolves the CURRENT
    // dashboard scope at pop time from the engine's chrome level.
    @State private var todoSettings: DashTodoSettings
    @State private var todoMenu: DashTodoMenuController

    /// Inject a shared engine so another scene (the standalone Calendar AI window) can read the
    /// same live calendar state. Defaults to a fresh engine when hosted standalone.
    @MainActor public init(engine: CalendarEngine? = nil, assistant: AssistantState? = nil,
                           windowAssistant: AssistantState? = nil) {
        let e = engine ?? CalendarEngine()
        _engine = State(initialValue: e)
        let settings = DashTodoSettings()
        _todoSettings = State(initialValue: settings)
        _todoMenu = State(initialValue: DashTodoMenuController(settings: settings, scope: {
            e.chrome.level == 3 ? .day : (e.chrome.level == 2 ? .week : .month)
        }))
        self.assistant = assistant
        self.windowAssistant = windowAssistant
    }

    /// After an inline editor (title / track name) commits, its text field was first responder; return
    /// first-responder to the calendar canvas so keyboard shortcuts keep working (e.g. Enter → edit
    /// title → Enter → back to selected → Enter → edit again). Deferred so it runs after the field is
    /// torn down. `catcherHandle.catcher` is the live CatcherView (set by the InputCatcher).
    private func refocusCatcher() {
        DispatchQueue.main.async {
            if let c = catcherHandle.catcher {
                c.window?.makeFirstResponder(c)
            }
        }
    }

    /// Context menu's "Rename": the same inline editor each kind's hotkey uses; deadlines have no
    /// inline editor, so their title is edited in the drawer (opened with the title pre-selected).
    private func renameInline(_ id: String) {
        switch engine.kind(of: id) {
        case .timed: engine.editTimed(id)
        case .band: engine.editBand(id)
        case .deadline: ui.selectTitleOnOpen = true; ui.openEventId = sourceId(of: id)
        default: break
        }
    }

    /// The blocking-modal bundle, built OUTSIDE the body chain: the chain is ONE expression to
    /// the type checker, and adding closure arguments to a call inside it is what pushed solves
    /// into the minutes (bisected 2026-07-18). Constructed here, the closures never enter it.
    private func modalOverlays(theme: Theme) -> ModalOverlays {
        ModalOverlays(ui: ui, engine: engine, theme: theme,
                      onDelete: { performDelete($0) },
                      onRename: { renameInline($0) },
                      onCopy: { (catcherHandle.catcher as? CatcherView)?.copySelection() },
                      onCut: { (catcherHandle.catcher as? CatcherView)?.cutSelection() },
                      onPaste: { (catcherHandle.catcher as? CatcherView)?.performPaste() },
                      readClip: { (catcherHandle.catcher as? CatcherView)?.readClip() })
    }

    /// The AppKit input bridge, built OUTSIDE the body chain and assignment-style: the chain is
    /// ONE expression to the type checker, and a many-closure call inside it (or anywhere — the
    /// cost is exponential in argument count) is what pushed solves into the minutes (bisected
    /// 2026-07-18). One tiny statement per hook keeps this trivially cheap forever.
    private func inputCatcher() -> InputCatcher {
        var ic = InputCatcher(engine: engine, monthBridge: monthBridge,
                              weekBridge: weekBridge, dayBridge: dayBridge)
        ic.forwarder = catcherHandle
        ic.onOpenEvent = { ui.openEventId = $0 }
        ic.onEventMenu = { (id: String, anchor: CGRect) in
            ui.eventMenu = CalendarUIState.EventMenuTarget(id: id, anchor: anchor)
        }
        ic.onSpaceMenu = { (spot: CalendarEngine.EmptySpot, anchor: CGRect) in
            ui.spaceMenu = CalendarUIState.SpaceMenuTarget(spot: spot, anchor: anchor)
        }
        ic.onEditTrack = { te in engine.trackEditing = true; ui.editingTrack = te }
        // The keyboard state machine + the Cmd+K guide toggle. `onKey` reads
        // live engine/ui state each press; returns whether it consumed the key.
        ic.onKey = { KeyboardModel(engine: engine, ui: ui).handle($0) }
        ic.onKeyGuide = { ui.showKeyGuide = $0 }
        ic.isEditingText = { ui.drawerFieldEditing }
        ic.onSearch = { openSearch() }
        ic.isModalDelete = {
            ui.pendingDelete != nil || ui.pendingBatchDelete != nil || ui.notice != nil
                || ui.calendarPrompt != nil || ui.pendingCalendarRemove
                || ui.pendingTodoDelete != nil
        }
        ic.onDeleteDialogKey = { handleDeleteDialogKey($0) }
        ic.isBatchRenaming = { ui.batchRenaming }
        ic.onBatchRenameCancel = { cancelBatchRename(ui: ui, engine: engine) }
        ic.onBatchRenameCommit = { commitBatchRename(ui: ui, engine: engine) }
        ic.onRequestDelete = {
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
        ic.isTutorialUp = { ui.showTutorial }
        ic.onTutorialKey = { handleTutorialKey($0) }
        return ic
    }

    /// ── Delete-confirm dialog ─────────────────────────────────────────────────────
    /// Carry out a chosen scope, then dismiss the dialog (and the drawer, on an actual delete).
    private func performDelete(_ choice: DeleteChoice) {
        guard let pd = ui.pendingDelete else { return }
        switch choice {
        case .cancel: break
        case .thisEvent: engine.deleteOccurrence(pd.id, pd.occKey)
        case .thisAndFuture: engine.deleteFuture(pd.id, pd.occKey)
        case .deleteAll: engine.remove(pd.id)
        case .hide: engine.hideImportedSeries(pd.id) // imported → hide (can't truly delete)
        case .hideOccurrence: engine.hideImportedOccurrence(pd.id) // imported → hide just this one
        case .removeFromLane: engine.unpromote(pd.id) // ghost bar → clear the promotion, keep the item
        case .unhide: engine.unhideImportedSeries(pd.id) // revealed-hidden → bring it back
        }
        ui.pendingDelete = nil
        // Close the drawer only when the item actually left the calendar; lane removal and unhide
        // keep it around (and possibly still open in the drawer).
        if choice.isDestructive {
            ui.openEventId = nil
        }
        refocusCatcher() // keys go back to the calendar
        engine.wake()
    }

    /// The key monitor's ←/→/Enter/Esc while the dialog is up.
    private func handleDeleteDialogKey(_ key: DeleteDialogKey) {
        // Informational notice: any Enter/Esc dismisses.
        if ui.notice != nil {
            if key == .confirm || key == .cancel {
                ui.notice = nil; engine.wake()
            }
            return
        }
        // PROJ row-menu delete confirm: Enter deletes, Esc cancels.
        if let td = ui.pendingTodoDelete {
            if key == .confirm {
                td.confirm()
            }
            if key == .confirm || key == .cancel {
                ui.pendingTodoDelete = nil; engine.wake()
            }
            return
        }
        // Batch-delete confirm (multi-selection): Enter deletes, Esc cancels.
        if ui.pendingBatchDelete != nil {
            switch key {
            case .confirm: engine.performBatchDelete(); ui.pendingBatchDelete = nil
            case .cancel: ui.pendingBatchDelete = nil
            case .left, .right: break
            }
            engine.wake(); return
        }
        // Remove-calendar confirm: Enter removes, Esc cancels. (The New/Rename prompt owns its own text
        // field, so its keys never reach here.)
        if ui.pendingCalendarRemove {
            switch key {
            case .confirm: engine.removeCurrentCalendar(); ui.pendingCalendarRemove = false
            case .cancel: ui.pendingCalendarRemove = false
            case .left, .right: break
            }
            engine.wake(); return
        }
        guard let pd = ui.pendingDelete else { return }
        switch key {
        case .left: ui.moveDeleteFocus(-1)
        case .right: ui.moveDeleteFocus(1)
        case .cancel: performDelete(.cancel)
        case .confirm: performDelete(pd.choices[pd.focus ?? pd.primaryIndex])
        }
        engine.wake()
    }

    /// One-time wiring on the calendar's first appearance. Extracted from `body` so the view's long
    /// modifier chain stays within the Swift type-checker's budget.
    private func setupOnAppear(size: CGSize) {
        // BUILD BANNER: stale binaries burned us (a Finder-launched app was still running the
        // pre-native-default webview while we compared "the same code") — every launch now
        // states exactly WHICH binary this is and what it runs, so no measurement is ever
        // ambiguous about its build again.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "?"
        let mtime = (try? FileManager.default.attributesOfItem(atPath: exe)[.modificationDate])
            .flatMap { $0 as? Date }
        print("[build] \(exe)")
        print("[build] built \(mtime.map { ISO8601DateFormatter().string(from: $0) } ?? "?") | "
            + "dashboard=NATIVE | "
            + "trace=\(CCTrace.on) diag=\(NativeDash.diag) hud=\(DemoController.hudEnabled) "
            + "demo=\(CalendarEngine.isDemoMode)")
        WindowBeepSilencer.installOnce() // stop the window beeping on keys the calendar leaves unhandled
        PresentGuard.install() // starved runloop ⇒ still present frames (the "⌘J pop" fix)
        // App shell only: the calendar WindowGroup used to carry .frame(minWidth:minHeight:) at
        // the root, which makes the window's NSHostingView re-derive min-size constraints
        // through the toolbar's Auto Layout engine on every tick (~46% of per-tick cost in the
        // ⌘J-pop traces). The frame modifier is gone; the window's own contentMinSize enforces
        // the same 900×600 floor once, for free. (CLI shell windows have no identifier.)
        DispatchQueue.main.async {
            if let win = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("calendar") == true }) {
                win.contentMinSize = NSSize(width: 900, height: 600)
            }
        }
        if CalendarEngine.isDemoMode {
            demo.openSearchHook = { openSearch() } // search-demo scene drives the real toolbar search
            demo.eventMenuHook = { id, r in ui.eventMenu = CalendarUIState.EventMenuTarget(id: id, anchor: r) }
            demo.dashTodoFocusHook = { [dashNav] in dashTab = .todo; dashNav.focus() }
            demo.dashTodoToggleHook = { [dashNav, engine] in
                if let t = dashNav.currentRow {
                    NativeDashPanel.toggleTodo(engine, t)
                }
            }
            demo.closeEventMenuHook = { ui.eventMenu = nil }
            demo.dashSetTabHook = { dashTab = $0 } // help-shot scenes: a tab click, nothing more
            demo.searchState = search
            demo.startIfDemo(engine: engine, size: size)
        } // GIF recording session
        else if !tutorialSeen {
            tutorialSeen = true; ui.tutorialIndex = 0; ui.showTutorial = true
        } // first launch
        // Native dashboard: pre-build the todo/proj feeds shortly after launch (in EVERY mode —
        // this used to sit inside the demo branch, so real launches paid the cold full-database
        // parse inline on first panel open, inside its zoom tween). The build itself runs on the
        // background feed queue; +0.4s keeps the snapshot off the launch render burst.
        do {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                engine.prewarmFeeds(today: NativeDashPanel.todayIso())
            }
        }
        engine.setViewport(size)
        dashFrac = engine.daily.frac
        engine.onEditBand = { id, rect in engine.bandEditing = true; ui.editingBand = BandEdit(id: id, rect: rect) }
        engine.onEditTimed = { id, rect in engine.timedEditing = true; ui.editingTimed = TimedEdit(id: id, rect: rect) }
        engine.onEditTrackName = { m, t, rect in engine.trackEditing = true; ui.editingTrack = TrackEdit(
            month: m,
            track: t,
            rect: rect
        ) }
        engine.onRequestOpenDrawer = { id, selectTitle in ui.openEventId = id; ui.selectTitleOnOpen = selectTitle }
        // An external data change removed the item a drawer / delete-dialog / inline editor was showing
        // (e.g. deleted in Apple Calendar, then re-imported on foreground) → dismiss it.
        engine.onExternalDataChange = { [engine] in
            if let id = ui.openEventId, !engine.itemExists(id) {
                ui.openEventId = nil
            }
            if let pd = ui.pendingDelete,
               !engine.itemExists(pd.id) {
                ui.pendingDelete = nil; engine.inputModalUp = false
            }
            if let te = ui.editingTimed,
               !engine.itemExists(sourceId(of: te.id)) {
                ui.editingTimed = nil; engine.timedEditing = false
            }
            if let be = ui.editingBand,
               !engine.itemExists(sourceId(of: be.id)) {
                ui.editingBand = nil; engine.bandEditing = false
            }
        }
        // Dashboard Tab stops (TODO / NOTE): the engine's keyboard system drives the native
        // panels' row cursor + note-editor focus, and switches the TODO/NOTE tab to match.
        engine.onDashCommand = { [tabBinding = $dashTab, engine, dashNav, ui] cmd in
            guard (1 ... 3).contains(engine.chrome.level) else { return }
            switch cmd {
            case let .focus(stop):
                if stop == .todo {
                    tabBinding.wrappedValue = .todo; dashNav.focus()
                } else {
                    dashNav.blur(); if stop == .note {
                        tabBinding.wrappedValue = .note
                    }
                }
            case let .move(d):
                dashNav.move(d)
            case .activate:
                if let t = dashNav.currentRow {
                    NativeDashPanel.toggleTodo(engine, t)
                }
            case .open:
                if let t = dashNav.currentRow {
                    if t.source == "event" {
                        // Enter on an event row: drawer, note editor at the row's line
                        // (occurrence note when the todo lives there) — same as a click.
                        ui.openNoteTarget = CalendarUIState
                            .OpenNoteTarget(line: t.line, occurrenceKey: t.occurrenceKey)
                        ui.openEventId = sourceId(of: t.eventId)
                    } else if let key = t.dailyDate {
                        // Enter on a note row: fly to its note, landing in the EDITOR
                        // focused with the row's source line selected.
                        jumpToNoteKey(key, line: t.line)
                    }
                }
            case let .fold(open):
                if let t = dashNav.currentRow {
                    let a = NativeDashPanel.anchor(t)
                    if open {
                        dashNav.collapsedSubs.remove(a)
                    } else {
                        dashNav.collapsedSubs.insert(a)
                    }
                    engine.wake()
                }
            case .editNote:
                dashNav.noteFocusSeq += 1 // the active panel's editor takes the keyboard
            }
            engine.wake()
        }
    }

    /// The key monitor's ←/→/Enter/Esc while the tutorial carousel is up.
    private func handleTutorialKey(_ key: DeleteDialogKey) {
        let last = TutorialView.slides.count - 1
        switch key {
        case .left: ui.tutorialIndex = max(0, ui.tutorialIndex - 1)
        case .right: ui.tutorialIndex = min(last, ui.tutorialIndex + 1)
        case .confirm: if ui.tutorialIndex >= last {
                ui.showTutorial = false
            } else {
                ui.tutorialIndex += 1
            }
        case .cancel: ui.showTutorial = false
        }
        engine.wake()
    }

    /// ── Toolbar search ───────────────────────────────────────────────────────────────
    private func openSearch() {
        engine.wake()
        searchCloseWork?.cancel(); searchCloseWork = nil // cancel a pending collapse (re-open mid-close)
        if search.open {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { search.expanded = true } // re-expand
        } else {
            search.open = true // mounts the bar; its onAppear animates the expand from the button
        }
    }

    /// Animate the bar collapsing back to the button, THEN unmount it (swap in the round button). Clearing
    /// the query first drops the dropdown; the delayed work is cancellable so a quick re-open aborts it.
    private func closeSearch() {
        search.query = ""; search.results = []; search.sel = 0
        withAnimation(.easeOut(duration: 0.24)) { search.expanded = false }
        searchCloseWork?.cancel()
        let work = DispatchWorkItem { search.open = false; refocusCatcher() }
        searchCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func commitSearch() {
        guard search.results.indices.contains(search.sel) else { return }
        engine.revealAndSelect(id: search.results[search.sel].id)
        closeSearch()
    }

    /// The calendar scene for one frame's `input`. Rendered inside a `TimelineView(.animation)` while
    /// awake (per-frame), and as a plain static view while idle — NOT via `TimelineView(paused:)`, which
    /// keeps a display-cycle observer alive that re-lays-out the NSHostingView (and re-runs these Canvas
    /// draws) 60×/sec even when paused. Dropping the TimelineView from the tree entirely is what actually
    /// stops the idle redraw.
    private func calendarScene(_ input: SceneInput, vp: Viewport, theme: Theme) -> some View {
        // Rest-year layer cache (see YearLayerCache.swift): non-nil at z==0 with no page-turn/flip.
        let g0 = yearCacheInput(input)
        // Gutter hide: the scene lays out gutterShift wider (input.vp is inflated) and every
        // layer TRANSLATES left by the same amount — pure draw-transform motion, no view resize
        // (resizing the hosted WKWebView/NSScrollViews per frame is what tanks the framerate).
        let sceneDX = Layout.padLeft - engine.gutterShift
        return ZStack {
            // 1. scene below events — clipped to the content area. At rest-year the scroll-RIGID
            // slice records once at full year height and CA translates it; only the hover
            // highlights re-draw per frame. Elsewhere: the classic single per-frame canvas.
            if let g0 {
                Color.clear.overlay(alignment: .top) {
                    YearRigidBelow(g0: g0, theme: theme)
                        .equatable()
                        .frame(height: g0.vp.h)
                        .offset(y: -input.scrollY)
                }
                Canvas { ctx, _ in
                    var c = ctx
                    c.translateBy(x: sceneDX, y: 0)
                    RenderProf.measure("drawBelow", "1_drawBelow") {
                        SceneRenderer.drawBelow(input: input, filter: .hoverOnly, in: &c, theme: theme)
                    }
                }
            } else {
                Canvas { ctx, _ in
                    var c = ctx
                    c.translateBy(x: sceneDX, y: 0)
                    RenderProf.measure("drawBelow", "1_drawBelow") {
                        SceneRenderer.drawBelow(input: input, in: &c, theme: theme)
                    }
                }
            }
            // 2. events (bands + timed), Liquid Glass stickers
            EventsOverlay(input: input, events: engine.viewEvents(), bands: engine.viewBands(),
                          bandBadges: engine.viewBandBadges(), eventBadges: engine.viewEventBadges(),
                          selected: engine.selectedId, selectedIds: engine.selectedIds, hovered: engine.hoveredEventId,
                          drawerOpen: ui.openEventId != nil, editingId: ui.editingBand?.id ?? ui.editingTimed?.id,
                          editingRect: ui.editingTimed?.rect, // hide the title only on the segment being edited
                          draggingId: engine.activeTimedDragId,
                          perfMode: effPerfMode, monthLive: engine.monthGestureActive, editGen: engine.displayGen,
                          hideBox: ui.openEventId != nil ? engine.selectedId : nil, // lifted sharp above
                          yearG0: g0,
                          theme: theme)
                .offset(x: sceneDX)
            // 3. deadlines: the moment line + dots are drawn in the Canvas… When the drawer is open the
            // SELECTED deadline is HIDDEN here (drawn sharp in the lift below, like band/timed events).
            let liftDdl = ui.openEventId != nil ? engine.selectedId : nil
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: sceneDX, y: 0)
                RenderProf.measure("drawMid", "3_drawMid") {
                    SceneRenderer.drawMid(
                        input: input,
                        deadlines: engine.viewDeadlines(),
                        selected: engine.selectedId,
                        drawerOpen: ui.openEventId != nil,
                        hovered: engine.hoveredEventId,
                        hide: liftDdl,
                        in: &c,
                        theme: theme
                    )
                }
            }
            // …and the labels are SwiftUI glass pills (activation styling), above the line.
            DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(),
                             sides: engine.deadlineSides(),
                             selected: engine.selectedId, selectedIds: engine.selectedIds,
                             hovered: engine.hoveredEventId,
                             drawerOpen: ui.openEventId != nil, hide: liftDdl, theme: theme)
                .offset(x: sceneDX)
            // 4. chrome on top of the glass: gutter labels/borders, track names, now-line/cursor, dashboard title.
            // Rest-year: the gutter (month names + track names + borders) is scroll-rigid → cached layer;
            // the per-frame pass keeps only the gutter hover strip + foreground + pull hints.
            if let g0 {
                Color.clear.overlay(alignment: .top) {
                    YearRigidAbove(g0: g0, tracks: engine.items.trackNames,
                                   hideTrack: ui.editingTrack.map { ($0.month, $0.track) }, theme: theme)
                        .equatable()
                        .frame(height: g0.vp.h)
                        .offset(y: -input.scrollY)
                }
                Canvas { ctx, _ in
                    var c = ctx
                    c.translateBy(x: sceneDX, y: 0)
                    RenderProf.measure("drawAbove", "5_drawAbove") {
                        SceneRenderer.drawAbove(input: input, tracks: engine.items.trackNames,
                                                hideTrack: ui.editingTrack.map { ($0.month, $0.track) },
                                                filter: .hoverOnly, in: &c, theme: theme)
                    }
                }
            } else {
                Canvas { ctx, _ in
                    var c = ctx
                    c.translateBy(x: sceneDX, y: 0)
                    RenderProf.measure("drawAbove", "5_drawAbove") {
                        SceneRenderer.drawAbove(input: input, tracks: engine.items.trackNames,
                                                hideTrack: ui.editingTrack.map { ($0.month, $0.track) }, in: &c,
                                                theme: theme)
                    }
                }
            }
            // 4b. time tags ABOVE the chrome: the CURRENT TIME pill + cursor time tag render over the
            // gutter hour labels/borders, so their frosted glass blurs the labels instead of the
            // labels drawing crisp across the tag (the day-view left-gutter collision).
            TimeTagsOverlay(input: input, theme: theme)
                .offset(x: sceneDX)
            // Keyboard-navigation cursor (dashed sliding ring).
            CursorRing(rect: engine.blockCursorRect(), theme: theme, cornerRadius: 6,
                       geometryAnimating: engine.isAnimating)
                .offset(x: sceneDX)
            // Band cursor: a dashed cell over one lane × one day.
            CursorRing(rect: engine.bandCursorRect(), theme: theme, cornerRadius: 4,
                       geometryAnimating: engine.isAnimating)
                .offset(x: sceneDX)
            // Track-name cursor (month view's extra Tab stops): a dashed cell over the gutter name slot.
            CursorRing(rect: engine.trackNameCursorRect(), theme: theme, cornerRadius: 4,
                       geometryAnimating: engine.isAnimating)
                .offset(x: sceneDX)
            // Event cursor: dashed ring around the SELECTED event box (keyboard mode).
            CursorRing(rect: engine.selectionRingRect().map { $0.insetBy(dx: -2, dy: -2) },
                       theme: theme, cornerRadius: 8, geometryAnimating: engine.isAnimating)
                .offset(x: sceneDX)
            // Marquee selection box: dashed border + shaded fill. Positive select = red; negative = gray.
            if let m = engine.marqueeRect {
                let c = engine.marqueeNegative ? Color.secondary : theme.eventBorder("red")
                RoundedRectangle(cornerRadius: 2)
                    .fill(c.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(
                        c,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    ))
                    .frame(width: m.width, height: m.height)
                    .position(x: m.midX, y: m.midY)
                    .offset(x: sceneDX)
                    .allowsHitTesting(false)
            }
            // Deadline quick-add "+" — a small circle on the hovered day column's left edge at the nearest
            // hour line (week/day view). Visual only (the whole scene is non-hit-testing); the click is
            // caught by the InputCatcher → onPointerDown → deadlineAddSpot. Hidden while the drawer is open.
            if ui.openEventId == nil, let spot = engine.deadlineAddSpot(input) {
                DeadlineAddButton(theme: theme, hovering: spot.hovering)
                    .position(x: spot.x, y: spot.y)
                    .offset(x: sceneDX)
            }
            // Per-frame carousel driver for the native dashboard chrome (invisible). Carries
            // {dir,p} for day paging and `reveal` for the panel's slide-in-from-right + fade.
            if input.z > 1.5 || input.dashPin > 0.01 {
                let c = engine.dashboardCarousel()
                // Zoom-scope carousel: pure function of z (mirrors SceneRenderer's scopePair) —
                // the finer scope enters from the LEFT zooming in, returns from the RIGHT out.
                let sT: Double = input.z >= 2
                    ? Double(easeInOut(clamp(input.z - 2, 0, 1)))
                    : (input.z >= 1 ? Double(easeInOut(clamp(input.z - 1, 0, 1))) : 0)
                // Header anchor: the focused band's animated frame (accordion + page-turns) keeps
                // the Canvas header and the native tabs vertically in lock-step.
                let fHeader = frameFor(input.focus, input, anim: input.monthAnim)
                // The INCOMING month's band frame during a page-turn (tabs ride both headers).
                let fHeader2 = input.monthAnim.map { a in
                    frameFor(input.focus + a.dir, input, anim: input.monthAnim)
                } ?? fHeader
                let (mDir, mP): (Int, Double) = input.monthAnim.map { ($0.dir, Double($0.p)) } ?? (0, 0)
                // Week-to-week carousel (weekly dashboard): driven by the continuous week
                // scroll — the SAME function the Canvas week header draws with.
                let wt = weekDashTurn(input)
                // Per-panel geometry from the SAME function the Canvas header draws with
                // (dashScopePanels) — each panel's own (left, width, opacity), frame-local px.
                let scopeGeom = dashScopePanels(input)
                CarouselDriver(anim: dashAnim,
                               dir: c.dir, p: c.p, reveal: c.reveal,
                               scopeT: sT,
                               headerTopY: Double(fHeader.bandY),
                               headerTopY2: Double(fHeader2.bandY),
                               panelLeft: Double(dashboardLeftAnimated(input) - engine.gutterShift),
                               mDir: mDir, mP: mP,
                               wP: Double(wt.p),
                               aName: scopeGeom?.a.name ?? "",
                               aX: Double((scopeGeom?.a.x ?? 0) - Layout.labelW - engine.gutterShift),
                               aW: Double(scopeGeom?.a.w ?? 0),
                               aOp: Double(scopeGeom?.a.op ?? 0),
                               bName: scopeGeom?.b?.name ?? "",
                               bX: Double((scopeGeom?.b?.x ?? 0) - Layout.labelW - engine.gutterShift),
                               bW: Double(scopeGeom?.b?.w ?? 0),
                               bOp: Double(scopeGeom?.b?.op ?? 0),
                               gutterShiftX: Double(engine.gutterShift))
                    .frame(width: 0, height: 0)
            }
        }
        .opacity(input.flipFade) // whole-calendar fade during a year flip
        .blur(radius: ui.openEventId != nil ? 5 : 0) // drawer open → soft-blur behind the scrim
        .offset(x: -engine.drawerShift) // slide left so the drawer item is revealed/centered
    }

    /// A note storage key ("YYYY-MM-DD" / "week:<sunday>" / "month:<YYYY-MM>") → fly to its view
    /// and land on the NOTE tab — the native version of the webview's onJumpDay flow (line focus
    /// inside the editor arrives with the editor's selectLine later).
    private func jumpToNoteKey(_ date: String, line: Int? = nil) {
        let land = { [dashNav] in
            dashTab = .note
            if let line {
                dashNav.requestNoteJump(key: date, line: line)
            }
        }
        if date.hasPrefix("week:") {
            let c = date.dropFirst(5).split(separator: "-").compactMap { Int($0) }
            guard c.count == 3 else { return }
            engine.jumpToWeek(c[0], c[1] - 1, c[2], onLand: land)
            engine.pinDashboard()
        } else if date.hasPrefix("month:") {
            let c = date.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard c.count == 2 else { return }
            engine.jumpToMonth(c[0], c[1] - 1, onLand: land)
            engine.pinDashboard()
        } else {
            let c = date.split(separator: "-").compactMap { Int($0) }
            guard c.count == 3 else { return }
            engine.jumpToDay(c[0], c[1] - 1, c[2], onLand: land)
        }
    }

    /// The native dashboard BODY panels for this frame (cc.nativeDash): ONE container framed to
    /// the mask region (scope.mask → right edge) and clipped — the header's clipRect — with each
    /// sub-panel from dashBodyPanels placed by the header's OWN inset math (drawPanelChrome):
    /// content left = panelLeft + 25, right = panelLeft + width − 18, top = the header's bottom
    /// bar (topY + Layout.monthH, dy-anchored to the band frame) + the overlay's 14px gap.
    /// The dashboard reveal clip: everything right of `x`. A SHAPE, not a frame — its
    /// animation is rendering-only, so the panels' layout (and their lazy content) is
    /// untouched by the slide.
    private struct RevealFrom: Shape {
        var x: CGFloat
        func path(in rect: CGRect) -> Path {
            Path(CGRect(x: x, y: rect.minY, width: max(0, rect.width - x), height: rect.height))
        }
    }

    @ViewBuilder
    private func nativeDashOverlay(theme: Theme) -> some View {
        let input = engine.snapshotInput()
        let bodyPanels = dashBodyPanels(input)
        let c = engine.dashboardCarousel()
        let sg = dashScopePanels(input)
        let liveIds = Set(bodyPanels.map(\.panelId))
        let _ = {
            // Array/dictionary bookkeeping only when the live SET changes — parkPanels'
            // churn + trimNavRows' filter ran at 120Hz (profile: _NativeDictionary
            // setValue/merge among the top self-time frames during hotkey spam).
            if liveIds != NativeDash.lastLiveIds {
                NativeDash.lastLiveIds = liveIds
                NativeDash.parkPanels(bodyPanels)
                NativeDash.trimNavRows(dashNav, liveIds: liveIds)
            }
            if let settled = bodyPanels.first(where: { $0.op >= 0.999 && abs($0.dx) < 0.5 }) {
                dashNav.activePanel = settled.panelId // plain per-frame assignment
                // SUSTAINED rest (0.5s) → the settled panel warms its unvisited tabs, so the
                // first ⌘E/⌘J from a pinned dashboard flips instantly instead of mounting the
                // tab mid-flip. (Momentary settles — swipe-tour gaps — must NOT warm.)
                if NativeDash.settledSince?.id != settled.panelId {
                    NativeDash.settledSince = (settled.panelId, Date())
                } else if let s0 = NativeDash.settledSince,
                          Date().timeIntervalSince(s0.at) > 0.5 {
                    NativeDash.warmIds.insert(settled.panelId)
                }
                // At rest: pre-mount ONE not-yet-parked neighbor per frame (staggered
                // so a landing never pays two mounts in one frame). Invisible (op 0).
                let parkedIds = Set(NativeDash.parkedPanels.map(\.panelId))
                if bodyPanels.count == 1,
                   let n = NativeDash.neighborPanels(of: settled)
                   .first(where: { !parkedIds.contains($0.panelId) }) {
                    NativeDash.parkPanels([n])
                }
            }
            // NO scope panels on screen (year level, or month/week with the pin retracted):
            // nothing above pre-builds, so the first ⌘B/⌘E/⌘J (or the year→month zoom) paid
            // the whole triple-tab panel mount INSIDE its slide — the "first ⌘J" hitch.
            // Pre-build the focused scope's panel parked while resting here.
            if sg == nil, engine.chrome.level <= 2 {
                let scope: String
                let key: String
                let w: CGFloat
                if engine.chrome.level == 2 {
                    let wt = weekDashTurn(input)
                    scope = "week"
                    key = wt.p >= 0.999 && !wt.toKey.isEmpty ? wt.toKey : wt.fromKey
                    w = input.dashWeekFrac * (input.vp.w - Layout.labelW)
                } else {
                    scope = "month"
                    key = String(format: "%04d-%02d", input.year, input.focus + 1)
                    w = dashMonthPanelW(input.vp, frac: input.dashMonthFrac)
                }
                if !key.isEmpty {
                    // Warm REGARDLESS of how the panel got parked: a panel parked by earlier
                    // live use skipped the warm (only fresh pre-builds got it), so the first
                    // ⌘J still mounted PROJ inside the pin tween — the "no animation, then
                    // pop" report. The host re-checks warmAllTabs via onChange, so flipping
                    // this after mount still triggers the staggered warm.
                    NativeDash.warmIds.insert(scope + "|" + key)
                    if !NativeDash.parkedPanels.contains(where: { $0.panelId == scope + "|" + key }) {
                        // x = 0: INSIDE the container viewport (bx = 25) so lazy content
                        // actually materializes during the warm — offscreen x parked the
                        // panel where LazyVStack builds nothing.
                        NativeDash.parkPanels([DashBodyPanel(
                            scope: scope, key: key, x: 0, w: w, dx: 0, dy: 0, op: 0
                        )])
                    }
                }
            }
        }()
        // STABLE order (sorted by id): the parking LRU re-appends per frame, and a
        // reordered ForEach makes SwiftUI re-layout moved children every frame.
        let parked = NativeDash.parkedPanels.filter { !liveIds.contains($0.panelId) }
            .sorted { $0.panelId < $1.panelId }
        if !bodyPanels.isEmpty || !parked.isEmpty {
            // THE CONTAINER'S LAYOUT SIZE NEVER CHANGES (traces 5-6): it used to be a clipped
            // frame whose WIDTH animated with the reveal — at slide start the viewport
            // collapsed to ~1px and regrew per frame, so LazyVStack content DEmaterialized
            // and rebuilt MID-SLIDE (dense months rebuilt hundreds of views inside one
            // transaction → 300ms display freezes; empty February was smooth — the user's
            // decisive A/B). Now the container is always full-size and the reveal is a CLIP
            // SHAPE animation: rendering-only, zero child relayout, warm content stays
            // materialized through the whole slide.
            let mask = sg?.mask ?? 0
            ZStack(alignment: .topLeading) {
                // Identity = scope|key (state never bleeds between keys sharing a list slot);
                // built panels that LEFT the carousel stay mounted, parked at opacity 0
                // (isLive false) — unmounting made every revisit re-pay the full mount (row
                // creation + text layout) on a gesture frame. Every mounted panel renders its
                // REAL content at all times; nothing is ever blanked.
                ForEach(bodyPanels + parked, id: \.panelId) { panel in
                    let isLive = liveIds.contains(panel.panelId)
                    let bx = panel.x + panel.dx + 25 // absolute: the container spans the vp
                    let pw = max(1, panel.w - 25 - 18)
                    let top = Layout.topPad + panel.dy + Layout.monthH + 14
                    let ph = max(1, input.vp.h - top - Layout.bottomPad)
                    NativePanelHost(engine: engine, scope: panel.scope, key: panel.key,
                                    tab: dashTab, theme: theme,
                                    dataStamp: engine.todoDataStamp,
                                    settings: todoSettings,
                                    nav: dashNav, noteMode: $noteMode,
                                    // Event rows open the DRAWER (the web's data-open path) —
                                    // landing in the note editor at the row's source line;
                                    // note rows fly to their note, landing on the NOTE tab.
                                    onOpen: { id, line, occKey in
                                        guard !NativeDash.tapsSuppressed else { return }
                                        ui.openNoteTarget = line.map {
                                            CalendarUIState.OpenNoteTarget(line: $0,
                                                                           occurrenceKey: occKey)
                                        }
                                        ui.openEventId = sourceId(of: id)
                                    },
                                    onJump: { key, line in
                                        guard !NativeDash.tapsSuppressed else { return }
                                        jumpToNoteKey(key, line: line)
                                    },
                                    onDeleteRequest: { text, confirm in
                                        ui.pendingTodoDelete = CalendarUIState
                                            .PendingTodoDelete(text: text, confirm: confirm)
                                    },
                                    warmAllTabs: NativeDash.warmIds.contains(panel.panelId),
                                    trimToActiveTab: !isLive
                                        && !NativeDash.warmIds.contains(panel.panelId))
                        .equatable() // per-frame re-eval stops HERE; only frame/opacity move
                        .frame(width: pw, height: ph)
                        .position(x: bx + pw / 2, y: top + ph / 2)
                        .opacity(isLive ? Double(panel.op) * Double(c.reveal) : 0)
                        .allowsHitTesting(isLive)
                }
            }
            .frame(width: input.vp.w, height: input.vp.h, alignment: .topLeading)
            .clipShape(RevealFrom(x: mask)) // the animated reveal, layout-neutral
            .position(x: input.vp.w / 2, y: input.vp.h / 2)
            .offset(x: Layout.padLeft - engine.gutterShift)
        }
    }

    /// The clicked event lifted sharp above the drawer scrim (a second render of just that box).
    @ViewBuilder
    private func liftedBox(sel: String, theme: Theme) -> some View {
        let input = engine.snapshotInput()
        EventsOverlay(input: input, events: engine.viewEvents(), bands: engine.viewBands(),
                      bandBadges: engine.viewBandBadges(), eventBadges: engine.viewEventBadges(),
                      selected: sel, hovered: nil, drawerOpen: true, editingId: nil,
                      draggingId: nil, perfMode: effPerfMode,
                      // The REAL edit generation, like the base overlay — the default (0) froze the
                      // lifted copy on a stale cached layout, so events created after the first
                      // drawer-open of a session never appeared in the lift (they "disappeared"
                      // behind the scrim while the base layer hid them as "drawn by the lift").
                      editGen: engine.displayGen,
                      onlyBox: sel, theme: theme)
            .offset(x: Layout.padLeft - engine.drawerShift - engine.gutterShift)
    }

    /// The clicked DEADLINE lifted sharp above the drawer scrim — its moment line + end dots (Canvas)
    /// and its label pill (SwiftUI), only that one deadline. Same idea as `liftedBox` for band/timed.
    @ViewBuilder
    private func liftedDeadline(sel: String, theme: Theme) -> some View {
        let input = engine.snapshotInput()
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: Layout.padLeft - engine.drawerShift - engine.gutterShift, y: 0)
                SceneRenderer.drawMid(input: input, deadlines: engine.viewDeadlines(), selected: sel,
                                      drawerOpen: true, hovered: nil, only: sel, in: &c, theme: theme)
            }
            DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(), sides: engine.deadlineSides(),
                             selected: sel, hovered: nil, drawerOpen: true, only: sel, theme: theme)
                .offset(x: Layout.padLeft - engine.drawerShift - engine.gutterShift)
        }
    }

    /// One stable `TimelineView`: `paused` just toggles whether it ticks per-frame. The view TYPE is the
    /// same whether awake or idle, so the tree (and the stateful pagers / key monitor hung off it) is
    /// NEVER rebuilt — only the frame schedule stops. Idle-CPU relief comes from breaking the
    /// layout→setViewport→wake feedback loop (see setViewport), not from swapping the view out.
    private func calendarSurface(awake: Bool, vp: Viewport, theme: Theme) -> some View {
        TimelineView(.animation(paused: !awake)) { tl in
            // One evaluation = one rendered frame → the benchmark's frame counter (no-op outside CC_DEMO
            // bench scenes; reads only @ObservationIgnored state, so it can't invalidate the view).
            let _ = demo.benchTick(tl.date)
            let _ = CCTrace.frame(engine) // CC_TRACE interaction profiler
            calendarScene(engine.sceneInput(at: tl.date, viewport: vp), vp: vp, theme: theme)
        }
    }

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        ZStack(alignment: .top) {
            GeometryReader { geo in
                let vp = Viewport(w: geo.size.width - Layout.padLeft - Layout.padRight, h: geo.size.height)
                // Pause the per-frame render loop when idle: reading `awake` (an @Observable bit the engine
                // wakes on any input/animation/edit) here makes SwiftUI re-evaluate and unpause the instant
                // activity resumes. When nothing's moving, the whole-scene 60fps redraw simply stops.
                // Awake → drive the scene per-frame with a TimelineView. Idle → render ONE static frame with
                // no TimelineView at all (see calendarSurface / calendarScene): that's what stops the
                // display-cycle redraw and takes idle CPU to ~0.
                let awake = engine.renderClock.awake
                // Gutter hide (narrow window + pinned week/month dashboard): the SCENE lays out
                // gShift wider and translates left internally (see calendarScene/sceneDX + the
                // CarouselDriver's compensated panel geometry — CSS motion in a fixed webview
                // frame). NOTHING here changes frame per frame; gShift (mirrored through the
                // per-frame observable dashAnim) only feeds the split handle's x.
                let gShift = CGFloat(dashAnim.gutterShift)
                let vpX = Viewport(w: vp.w + gShift, h: vp.h)
                calendarSurface(awake: awake, vp: vp, theme: theme)
                    // The visual layers are purely presentational — never let them intercept
                    // mouse events (the Canvas layers are hit-testable and re-render every
                    // frame, which otherwise steals clicks/drags from the input catcher).
                    // No opaque background: the window is translucent (see CalendarApp),
                    // so the desktop tint shows through.
                    .allowsHitTesting(false)
                    // Invisible month-paging driver, behind everything: an NSScrollView-backed SwiftUI
                    // ScrollView doing native .paging; the catcher forwards month-view scroll into it.
                    .background { MonthPager(engine: engine, bridge: monthBridge) }
                    .background { WeekPager(engine: engine, bridge: weekBridge) }
                    .background { DayPager(engine: engine, bridge: dayBridge) }
                    .overlay(inputCatcher())
                    // Native dashboard BODY: its own overlay ABOVE the input catcher so
                    // scroll/click interactions are real (the scene subtree is
                    // allowsHitTesting(false) wholesale). A second TimelineView on the same
                    // clock reading snapshotInput() — the frame the main loop already computed —
                    // so tweens never double-advance and the body stays in per-frame lockstep
                    // with the Canvas header. (The WKWebView dashboard this replaced is in
                    // legacy/ — retired phase 4a, 2026-08-02.)
                    .overlay {
                        TimelineView(.animation(minimumInterval: nil,
                                                paused: !engine.renderClock.awake)) { _ in
                            nativeDashOverlay(theme: theme)
                                // Drawer open: the panels are part of the calendar surface —
                                // they ride the SAME slide + soft-blur the scene gets. INSIDE
                                // the per-frame pass: drawerShift is an engine tween, so
                                // reading it out here would sample once per body eval and
                                // TELEPORT into place.
                                .blur(radius: ui.openEventId != nil ? 5 : 0)
                                .offset(x: -engine.drawerShift)
                        }
                        // Pinch over the native panels must still zoom the CALENDAR (a
                        // hit-testable SwiftUI overlay would swallow it). Feed the exact same
                        // engine call, with the same geometry-space conversion point(e) does.
                        .simultaneousGesture(
                            MagnifyGesture()
                                .onChanged { v in
                                    let pt = CGPoint(
                                        x: v.startLocation.x - Layout.padLeft
                                            + engine.drawerShift + engine.gutterShift,
                                        y: v.startLocation.y
                                    )
                                    let delta = v.magnification - (dashPinchMag ?? 1)
                                    engine.onMagnify(delta: delta, at: pt,
                                                     began: dashPinchMag == nil, ended: false,
                                                     fromPanel: true)
                                    dashPinchMag = v.magnification
                                    NativeDash.lastPinch = Date() // suppress row taps
                                }
                                .onEnded { v in
                                    let pt = CGPoint(
                                        x: v.startLocation.x - Layout.padLeft
                                            + engine.drawerShift + engine.gutterShift,
                                        y: v.startLocation.y
                                    )
                                    engine.onMagnify(delta: 0, at: pt, began: false, ended: true,
                                                     fromPanel: true)
                                    dashPinchMag = nil
                                    NativeDash.lastPinch = Date() // lift-off click grace
                                }
                        )
                        .allowsHitTesting(ui.openEventId == nil
                            && (engine.chrome.level == 3
                                || (engine.chrome.dashPinned
                                    && (1 ... 2).contains(engine.chrome.level))))
                    }
                    // TODO/NOTE tabs + note edit/preview toggle — separate overlays; carousel via dashAnim.
                    .overlay {
                        if ui.openEventId == nil {
                            DashTabsOverlay(engine: engine, anim: dashAnim, tab: $dashTab, frac: dashFrac, vp: vp,
                                            containerWidth: geo.size.width, theme: theme)
                        }
                    }
                    .overlay {
                        if ui.openEventId == nil {
                            NoteModeToggleOverlay(engine: engine, anim: dashAnim, tab: dashTab, noteMode: $noteMode,
                                                  containerWidth: geo.size.width, height: geo.size.height, theme: theme)
                        }
                    }
                    // TODO: layering cog (bottom-right on the TODO tab) → the native callout menu.
                    .overlay {
                        if ui.openEventId == nil {
                            TodoCogOverlay(engine: engine, anim: dashAnim, tab: dashTab, controller: todoMenu,
                                           containerWidth: geo.size.width, height: geo.size.height, theme: theme)
                        }
                    }
                    // Day-view split handle: drag the timeline↔dashboard boundary to resize. Above the catcher
                    // so it grabs the mouse in its narrow zone (the rest passes through). Shown in day view;
                    // reads chrome.level (@Observable) so it appears/disappears as you zoom.
                    .overlay {
                        if engine.chrome.level == 3
                            || (engine.chrome.dashPinned && (1 ... 2).contains(engine.chrome.level)),
                            ui.openEventId == nil {
                            DashboardSplitHandle(engine: engine, vp: vpX, gutterShift: gShift,
                                                 height: geo.size.height, theme: theme,
                                                 onFrac: { dashFrac = $0 })
                        }
                    }
                    // Timeline scale bar (week + day views): the video-editor thumb on the leftmost day's
                    // left border — drag the body to scroll, drag an end circle to rescale the hour height.
                    // Wrapped in the per-frame TimelineView (like liftedBox): tlScroll/hourH are hot,
                    // observation-ignored fields, so the thumb must re-read geometry every frame to track
                    // scrolling and its own drags.
                    .overlay {
                        if engine.chrome.level >= 2, ui.openEventId == nil {
                            TimelineView(.animation(paused: !awake)) { ctx in
                                // ctx.date passes through as `tick` so the bar's body re-evaluates every
                                // frame (equal inputs would be diff-skipped, freezing the thumb).
                                TimelineScaleBar(engine: engine, theme: theme, tick: ctx.date)
                            }
                        }
                    }
                    // inline track-name editor
                    .overlay {
                        if let te = ui.editingTrack {
                            TrackNameEditor(engine: engine, target: te, theme: theme,
                                            onDone: {
                                                ui.editingTrack = nil; engine.trackEditing = false; refocusCatcher()
                                            })
                        }
                    }
                    // inline band-title editor
                    .overlay {
                        if let be = ui.editingBand {
                            BandTitleEditor(engine: engine, target: be, theme: theme,
                                            onDone: {
                                                ui.editingBand = nil; engine.bandEditing = false; refocusCatcher()
                                            })
                        }
                    }
                    // inline timed-event-title editor (keyboard "Enter → edit title", or click-a-selected-event)
                    .overlay {
                        if let te = ui.editingTimed {
                            TimedTitleEditor(engine: engine, target: te, theme: theme,
                                             onDone: {
                                                 ui.editingTimed = nil; engine.timedEditing = false; refocusCatcher()
                                             })
                        }
                    }
                    // 4a. scrim — blocks the canvas + closes on outside-click (fades). Light dim; the blur behind
                    // it carries most of the "inactive" cue.
                    .overlay {
                        if ui.openEventId != nil {
                            Rectangle()
                                .fill(.black.opacity(0.12))
                                .contentShape(Rectangle())
                                .onTapGesture { ui.openEventId = nil }
                                .transition(.opacity)
                        }
                    }
                    // 4a′. the clicked event, LIFTED sharp above the scrim so the user sees what they're focused
                    // on. A second render of the events with `onlyBox` = the selected box: everything packs as
                    // usual (exact position) but only that box draws, un-blurred. Reads the same frame the main
                    // TimelineView computed (snapshotInput — no double tween-advance) + the live drawer shift.
                    .overlay {
                        if ui.openEventId != nil, let sel = engine.selectedId {
                            TimelineView(.animation(paused: !awake)) { _ in liftedBox(sel: sel, theme: theme) }
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    // 4a″. …and the lifted DEADLINE (moment line + dots + tag), sharp above the scrim too.
                    .overlay {
                        if ui.openEventId != nil, let sel = engine.selectedId {
                            TimelineView(.animation(paused: !awake)) { _ in liftedDeadline(sel: sel, theme: theme) }
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    // 4b. the drawer panel — slides in from the trailing edge
                    .overlay(alignment: .trailing) {
                        if let id = ui.openEventId {
                            EventDrawer(
                                engine: engine,
                                id: id,
                                width: $drawerWidth,
                                containerWidth: geo.size.width,
                                theme: theme,
                                onClose: { ui.openEventId = nil },
                                ui: ui,
                                refocus: { refocusCatcher() },
                                demoNoteFeed: demo.noteFeed,
                                demoNotePreview: demo.notePreview,
                                demoConfigOpen: demo.configPulse,
                                demoRepeatFeed: demo.repeatFeed
                            )
                            .allowsHitTesting(!drawerSettling) // see drawerSettling
                            .transition(.move(edge: .trailing))
                        }
                    }
                    .animation(.easeOut(duration: 0.26), value: ui.openEventId)
                    // Cmd+K shortcut guide — held-open overlay showing the current state's keys (fades in/out).
                    // Also opened (latched) by Help → Keyboard Shortcuts; a tap anywhere dismisses it (the ⌘K
                    // hold path releases on keyUp as before, so the tap layer is only the exit for the latched case).
                    .overlay {
                        if ui.showKeyGuide {
                            ZStack {
                                Color.black.opacity(0.001).contentShape(Rectangle())
                                    .onTapGesture { ui.showKeyGuide = false; engine.wake() }
                                KeyGuideOverlay(model: KeyboardModel(engine: engine, ui: ui), theme: theme)
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: ui.showKeyGuide)
                    .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
                        ui.showKeyGuide = true; engine.wake()
                    }
                    // Blocking-modal overlays (delete-confirm dialog + onboarding tutorial) bundled into one
                    // modifier so the body's modifier chain stays within the type-checker's budget.
                    .modifier(modalOverlays(theme: theme))
                    // ai-assistant recording scene: a staged, offline chat panel in the main window (the real
                    // assistant is a separate window the recorder can't frame). No-op outside that scene.
                    .overlay(alignment: .topTrailing) {
                        if demo.showAssistantPanel, let a = demo.assistant {
                            AssistantCalloutView(state: a, onOpenWindow: {})
                                .background(
                                    .regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12)))
                                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                                .padding(.top, 48)
                                .padding(.trailing, 14) // clear the toolbar (full-size content window)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if !demo.cursorPanelUp {
                            DemoCursorOverlay(demo: demo)
                        }
                    } // synthetic pointer during a GIF recording (panel-hosted when possible; no-op otherwise)
                    // Live frame-rate HUD (Settings ▸ Developer, or CC_FPS_HUD=1) — measures THIS run,
                    // whatever it is: Xcode-attached, standalone, or the signed app. Reads the render
                    // loop's own tick. @AppStorage so the Settings toggle applies live.
                    .overlay(alignment: .bottomLeading) {
                        if fpsHUDPref || DemoController.hudEnabled {
                            FPSHUD(demo: demo)
                        }
                    }
                    .onAppear { setupOnAppear(size: geo.size) }
                    .onChange(of: geo.size) { _, s in engine.setViewport(s) }
                    .onChange(of: ui.openEventId) { old, v in
                        engine.drawerOpen = v != nil
                        engine.chrome.drawerOpen = v != nil
                        if v != nil, old == nil { // opening: let the slide-in own the mouse
                            drawerSettling = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drawerSettling = false }
                        }
                        if let id = v {
                            engine.onHoverExit() // clear any lingering highlight now
                            engine.openDrawerShift(id: id, drawerWidth: drawerWidth)
                            NSCursor.arrow.set() // reset a stale hover cursor; SwiftUI takes over while open
                            // Keep the canvas as first responder while the drawer is open (no field focused), so its
                            // keys work — e.g. Space to close. (The notes WebView no longer steals focus; this covers
                            // any other control the appearing overlay might grab.)
                            if ui.drawerFocus == nil {
                                refocusCatcher()
                            }
                        } else {
                            ui.drawerFocus = nil
                            engine.closeDrawerShift()
                            refocusCatcher() // drawer closed → canvas keeps the keys (so Space re-opens it)
                        }
                    }
                    .onChange(of: drawerWidth) { _, w in
                        if let id = ui.openEventId {
                            engine.updateDrawerShift(id: id, drawerWidth: w)
                        }
                    }
                    // The dashboard tab/mode toggles are SwiftUI overlays (not routed through the engine), and
                    // their transition animates via the timeline's CarouselDriver — so wake the render loop when
                    // they change, else the switch would freeze while the calendar is idle.
                    .onChange(of: dashTab) { _, _ in engine.wake() }
                    .onChange(of: noteMode) { _, _ in engine.wake() }
                    // Apple Calendar import: pull on first appearance, whenever the app returns to the foreground
                    // (auto-refresh), and when the Settings window changes the connection.
                    .onAppear {
                        // Feed subscriptions are PER MagnifiCal calendar — always resolve against the
                        // engine's ACTIVE calendar at call time (switching repoints automatically).
                        engine.icsFeedURLs = { [weak engine] in
                            ICSFeeds.list(calendarId: engine?.activeCalendarId ?? "")
                        } // engine-triggered refreshes (Sync Now, calendar switch)
                        engine.importAppleCalendar()
                        engine.importICSFeeds(urls: ICSFeeds.list(calendarId: engine.activeCalendarId))
                    }
                    .onReceive(NotificationCenter.default
                        .publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                            engine.importAppleCalendar()
                            engine.importICSFeeds(urls: ICSFeeds.list(calendarId: engine.activeCalendarId))
                            engine.syncNow() // also pull/push iCloud on foreground (was never wired before)
                    }
                    // Settings changed the ICS feed list (add/remove) → re-import right away.
                    .onReceive(NotificationCenter.default.publisher(for: .icsFeedsChanged)) { _ in
                        engine.importICSFeeds(urls: ICSFeeds.list(calendarId: engine.activeCalendarId))
                    }
                    // Settings changed a feed's DEFAULT color → re-color its non-overridden items.
                    .onReceive(NotificationCenter.default.publisher(for: .icsFeedColorsChanged)) { _ in
                        engine.feedColorsChanged()
                    }
                    // A "How to…" deep link (e.g. from Settings) → open the Help window; HelpView
                    // itself selects the topic (HelpNav.pending / the same notification).
                    .onReceive(NotificationCenter.default.publisher(for: .openHelpTopic)) { _ in
                        openWindow(id: "help")
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .appleCalendarSettingsChanged)) { _ in
                        engine.importAppleCalendar()
                    }
                    // View-menu prefs (show-hidden / timezone pickers), the prefs-changed notification, and
                    // the tag-filter toggle — bundled into one modifier (see the type-check note above).
                    .modifier(ViewPrefObservers(engine: engine, showTagFilter: $showTagFilter,
                                                ui: ui, dashTab: $dashTab, dashNav: dashNav))
            }
            .ignoresSafeArea()
            // Search overlays — siblings inside the ZStack, so they respect the toolbar safe-area inset
            // (the dropdown lands just BELOW the toolbar) while the calendar above stays full-bleed. The
            // dropdown is right-aligned under the (trailing) search field and styled like the drawer.
            if search.open {
                Color.black.opacity(0.001).contentShape(Rectangle()) // click-outside closes search
                    .onTapGesture { closeSearch() }
            }
            if search.open, !search.query.isEmpty {
                // Pin the dropdown's top-left to the search bar's bottom-left. Both frames are measured in
                // the window's content-view space (WindowRectReader), so subtracting this stack's origin
                // gives the local offset — aligning across the toolbar↔content hierarchy boundary.
                Color.clear
                    .background(WindowRectReader { searchAnchor = $0.origin })
                    .overlay(alignment: .topLeading) {
                        SearchDropdown(search: search, theme: theme, onPick: { search.sel = $0; commitSearch() })
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(x: search.fieldFrame.minX - searchAnchor.x,
                                    y: search.fieldFrame.maxY - searchAnchor.y + 3)
                    }
                    .transition(.opacity)
            }
        } // ZStack
        .animation(.easeOut(duration: 0.12), value: search.query.isEmpty)
        // Drag an .ics file (from Finder, Mail, …) anywhere over the window: full-window
        // dashed-border mask while hovering; dropping imports via the File ▸ Import path.
        .overlay {
            if icsDropActive {
                ICSDropOverlay(theme: theme)
            }
        }
        .onDrop(of: [.fileURL], delegate: ICSDropDelegate(engine: engine, active: $icsDropActive))
        .toolbar { mainToolbar }
        // Let the translucent window material show through the toolbar (native tint).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Full screen: hide the toolbar entirely (full-bleed calendar); it slides in with the
        // menu bar when the mouse reaches the top, Safari-style.
        .windowToolbarFullScreenVisibility(.onHover)
        // …and re-assert transparency across fullscreen transitions, where AppKit re-applies its
        // own toolbar backdrop that the SwiftUI modifier doesn't reach (see TransparentTitlebar).
        .background(TransparentTitlebar())
        // Publish the quick-ask callout binding for the app's ⌘I command: calendar window key →
        // ⌘I toggles the callout; no calendar window → the command falls back to the full window.
        .focusedSceneValue(\.assistantCallout, $showAssistantCallout)
    }

    /// The window toolbar. Extracted to a builder so the type-checker doesn't choke on the whole body,
    /// and so the search field can swap in for the magnifyingglass button (expanding from it) when open.
    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { Breadcrumb(engine: engine) }
        ToolbarSpacerCompat(.flexible)
        ToolbarItem(placement: .primaryAction) {
            if search.open {
                SearchBar(engine: engine, search: search,
                          onCommit: { commitSearch() }, onClose: { closeSearch() })
            } else {
                Button { openSearch() } label: { Image(systemName: "magnifyingglass") }
                    .glassButtonStyleCompat().buttonBorderShape(.circle).help("Search (⌘F)")
            }
        }
        ToolbarSpacerCompat(.fixed)
        ToolbarItem(placement: .primaryAction) {
            // With a shared assistant: a quick-ask CALLOUT anchored to this button (an NSPopover —
            // caret + glass, may extend beyond the window). Without one (dev shell): the window.
            Button {
                if assistant != nil {
                    showAssistantCallout.toggle()
                } else {
                    openWindow(id: "assistant")
                }
            } label: { Image(systemName: "sparkles") }
                .glassButtonStyleCompat().buttonBorderShape(.circle).help("MagnifiCal AI (⌘I)")
                .popover(isPresented: $showAssistantCallout, arrowEdge: .bottom) {
                    if let assistant {
                        AssistantCalloutView(state: assistant) {
                            // Hand the callout's thread to the window: flush it to the store,
                            // point the window's session at it, close the callout, open the window.
                            showAssistantCallout = false
                            assistant.persistNow()
                            if let id = assistant.currentId {
                                windowAssistant?.selectConversation(id)
                            }
                            openWindow(id: "assistant")
                        }
                        // Publish from INSIDE the popover too, so ⌘I still toggles (closes) while
                        // the popover itself holds keyboard focus.
                        .focusedSceneValue(\.assistantCallout, $showAssistantCallout)
                    }
                }
        }
        ToolbarSpacerCompat(.fixed)
        ToolbarItem(placement: .primaryAction) {
            // View ▸ Filter by Tags lives here as a stay-open checklist popover (a menu can't stay open
            // while multi-toggling). The View-menu item in both shells toggles it via .toggleTagFilter.
            Button { showTagFilter.toggle() } label: { Image(systemName: "tag") }
                .glassButtonStyleCompat().buttonBorderShape(.circle).help("Filter by Tags (⌘G)")
                .popover(isPresented: $showTagFilter, arrowEdge: .bottom) {
                    TagFilterPopover(engine: engine)
                }
        }
        ToolbarSpacerCompat(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Button { engine.goToToday() } label: { Text("Today") }
                .glassButtonStyleCompat().buttonBorderShape(.capsule)
                .help("Go to today (⌘T)")
        }
    }
}

/// The View-menu preference observers, bundled so CalendarView's body modifier chain stays within the
/// Swift type-checker's budget (see swift-typecheck-cliff). Each @AppStorage mirrors the UserDefaults key
/// its menu control writes; the notifications catch the AppKit dev-shell menu's direct writes.
private struct ViewPrefObservers: ViewModifier {
    let engine: CalendarEngine
    @Binding var showTagFilter: Bool
    var ui: CalendarUIState
    @Binding var dashTab: DashTab
    var dashNav: NativeDashNavModel
    @AppStorage(PrefKeys.showHiddenImported) private var showHidden = false
    @AppStorage(PrefKeys.mainTz) private var mainTz = "auto"
    @AppStorage(PrefKeys.altTz) private var altTz = "none"
    func body(content: Content) -> some View {
        content
            .onChange(of: showHidden) { _, _ in engine.viewPrefsChanged() } // Show Hidden Imported Events
            .onChange(of: mainTz) { _, _ in engine.viewPrefsChanged() } // Current Timezone picker
            .onChange(of: altTz) { _, _ in engine.viewPrefsChanged() } // Alternative Timezone picker
            .onReceive(NotificationCenter.default.publisher(for: .calendarViewPrefsChanged)) { _ in
                engine.viewPrefsChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTagFilter)) { _ in
                showTagFilter.toggle() // View ▸ Filter by Tags (menu item, either shell)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusDashTodo)) { _ in
                dashHotkey(.todo) // View ▸ TODO List (⌘B)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusDashNote)) { _ in
                dashHotkey(.note) // View ▸ Note Editor (⌘E)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusDashProj)) { _ in
                dashHotkey(.proj) // View ▸ Projects (⌘J)
            }
    }

    /// ⌘B / ⌘E / ⌘J — faces of one coin: focus the dashboard's TODO / NOTE / PROJ tab.
    /// Day view: switch + keyboard-focus the tab (⌘E lands in the markdown editor; PROJ has no
    /// keyboard stop yet, so ⌘J drops any TODO/NOTE ring and hands keys to the calendar).
    /// Month/week: closed → open the panel on that tab; open on another tab → flip to it;
    /// already open on that tab → retract the panel. No-op at year or under the drawer.
    private func dashHotkey(_ stop: DashTab) {
        guard ui.openEventId == nil else { return }
        CCTrace.event("hotkey ⌘\(stop == .todo ? "B" : stop == .note ? "E" : "J")")
        switch engine.chrome.level {
        case 3:
            dashTab = stop
            switch stop {
            case .todo: engine.dashFocusEntry(.todo)
            case .note: engine.dashFocusEntry(.note)
            case .proj: engine.dashExitFocus()
            }
        case 1, 2:
            if !engine.dashPinned {
                engine.toggleDashPin()
                dashTab = stop
                focusWeekMonthTab(stop)
                if stop == .todo {
                    engine.dashFocusEntry(.todo)
                }
            } else if dashTab != stop {
                dashTab = stop
                focusWeekMonthTab(stop)
                if stop == .todo {
                    engine.dashFocusEntry(.todo)
                }
                engine.wake()
            } else {
                engine.toggleDashPin() // already on that tab → retract
                engine.dashExitFocus()
            }
        default:
            break
        }
    }

    /// Week/month landing focus: ⌘E puts the caret in the live note editor.
    private func focusWeekMonthTab(_ stop: DashTab) {
        if stop == .note {
            dashNav.noteFocusSeq += 1 // native editor takes the keyboard
        }
    }
}
