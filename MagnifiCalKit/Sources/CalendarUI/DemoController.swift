// Automated tutorial-GIF recording. When the app is launched with env CC_DEMO=<scene>, this drives a
// deterministic, scripted "scene" — a synthetic cursor + engine actions over a fixed timeline — while an
// external script (scripts/record-tutorial.sh) screen-records a fixed window rect and ffmpeg-crops it to a
// GIF. The engine runs against a throwaway store with Apple import off (see ItemStore / isDemoMode), so a
// recording never touches personal data.
//
// Scenes drive the app through its OWN public APIs (jumpToDay, demoAddTimed, cmdZoom*) rather than OS-level
// event injection — deterministic, no Accessibility permission, and it sidesteps the un-synthesizable pinch
// gesture (zoom is driven directly). The cursor is a drawn sprite, not the OS pointer.

import AppKit
import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

@MainActor @Observable
public final class DemoController {
    public var cursor: CGPoint? // calendar-view-local point of the synthetic cursor (nil = hidden)
    public var pressed = false // mouse-down visual (a small ring around the cursor)
    public var pinchDots: (CGPoint, CGPoint)? // two fingertips for the pinch-zoom gesture (nil = hidden)
    public var keyCap: String? // floating keycap pill (e.g. "⌘ B") for keyboard-driven beats
    public private(set) var active = false

    // ai-assistant scene: an in-window demo panel showing a staged (offline) conversation. The real
    // assistant is a separate window/popover the recorder can't frame; this reuses ConversationView in a
    // panel overlaid on the main window so the whole exchange sits inside the recorded rect.
    public var showAssistantPanel = false
    public var assistant: AssistantState?

    // markdown-notes scene: text streamed into the open drawer's editor (typed live) + the edit/preview cue.
    public var noteFeed = ""
    public var notePreview = false

    // recurring scene: expand the drawer's Configuration section + apply a repeat rule through the drawer.
    public var configPulse = 0
    public var repeatFeed: Repeat?

    // promote scene hooks (wired by CalendarView): open/close the right-click event callout.
    @ObservationIgnored var eventMenuHook: ((String, CGRect) -> Void)?
    @ObservationIgnored var closeEventMenuHook: (() -> Void)?

    // daily-dashboard scene hooks (wired by CalendarView): drive the native panel's REAL todo
    // toggle — keyboard-focus the first row, then activate it (check animation + strike-through + persist).
    @ObservationIgnored var dashTodoFocusHook: (() -> Void)?
    @ObservationIgnored var dashTodoToggleHook: (() -> Void)?
    // help-shot scenes: flip the pinned dashboard's tab exactly like a tab click — no editor
    // focus, so a written note stays in its content-default PREVIEW (⌘E would force edit mode).
    @ObservationIgnored var dashSetTabHook: ((DashTab) -> Void)?

    // search-demo scene hooks (wired by CalendarView.setupOnAppear): open the toolbar search bar, and the
    // live SearchState the field binds to — the scene types into it and reads the results.
    @ObservationIgnored var openSearchHook: (() -> Void)?
    @ObservationIgnored var searchState: SearchState?

    /// The synthetic cursor is hosted in its own transparent, click-through PANEL WINDOW above the app:
    /// the right-click callout is an NSPopover (an AppKit child window over the whole SwiftUI tree), so an
    /// in-tree overlay would draw UNDER it. True → CalendarView skips its in-tree cursor overlay.
    @ObservationIgnored public internal(set) var cursorPanelUp =
        false // internal(set): written by DemoController+HelpGIFs.swift
    @ObservationIgnored var cursorPanel: NSPanel? // internal: read by DemoController+HelpGIFs.swift

    weak var engine: CalendarEngine? // internal: read by DemoController+Bench.swift/+HelpGIFs.swift
    var size: CGSize = .zero // internal: read by DemoController+Bench.swift/+HelpGIFs.swift
    private var goTime: Date? // set when recording starts (go.txt) → measures on-camera duration

    // bench-year-scroll: per-frame timestamps recorded while the scripted scroll runs (see benchTick).
    // @ObservationIgnored: these mutate EVERY FRAME from the render closure — they must not churn the
    // observation machinery or invalidate any view.
    @ObservationIgnored var benchActive = false // internal: read by DemoController+Bench.swift
    @ObservationIgnored var benchMoves: [(Double, Double)] =
        [] // moving-phase windows (start, end); internal: read by DemoController+Bench.swift
    @ObservationIgnored var moveStart: Double = 0 // internal: read by DemoController+Bench.swift
    @ObservationIgnored var benchFrames: [Double] = [] // internal: read by DemoController+Bench.swift
    @ObservationIgnored var hudRing: [Double] =
        [] // recent frame timestamps (HUD window); internal: read by DemoController+Bench.swift

    /// One 60Hz frame — the scenes' unit pause between scripted steps.
    static let frameStep = 0.016 // internal: read by DemoController+Bench.swift

    public init() {}

    /// Kick off the scene named by CC_DEMO once the view has a real size. Safe to call repeatedly.
    public func startIfDemo(engine: CalendarEngine, size: CGSize) {
        guard CalendarEngine.isDemoMode, !active, size.width > 100 else { return }
        active = true
        self.engine = engine
        self.size = size
        // Script-launched app bundles (BIN=MagnifiCal.app/... bench runs) start UNACTIVATED: no key
        // window, and the bench window can sit occluded behind the user's session — which pauses
        // presents and records a run that measures nothing. Front the window like the CLI shell does.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        // The manual-benchmark scene ("idle") drives NOTHING — the human scrolls the real pointer — so it
        // must NOT install the synthetic click-through cursor panel that scripted scenes use.
        if !Self.isIdleScene {
            installCursorPanel()
        }
        Task { await run(CalendarEngine.demoScene) }
    }

    /// CC_DEMO=idle (or bench-idle): the manual-benchmark mode. isDemoMode is TRUE, so every background
    /// source (iCloud sync, ICS feeds, Apple-Calendar import, notifications, the now-timer) is off and the
    /// store is the throwaway CC_DEMO_DATADIR — identical to the CalendarMac bench — but no scene scripts
    /// input. Point CC_DEMO_DATADIR at a dir holding a data.json copy of bench/year-display-2026.json and
    /// turn on CC_FPS_HUD=1 to A/B the Xcode CalendarApp against the CalendarMac harness by hand.
    static var isIdleScene: Bool {
        CalendarEngine.demoScene == "idle" || CalendarEngine.demoScene == "bench-idle"
    }

    private func run(_ scene: String) async {
        switch scene {
        case "idle", "bench-idle": return // manual benchmark: load fixture, everything off, human drives
        case "timed-week": await sceneTimedWeek()
        case "band-year": await sceneBandYear()
        case "pinch-zoom": await scenePinchZoom()
        case "markdown-notes": await sceneMarkdownNotes()
        case "ai-assistant": await sceneAIAssistant()
        case "move-resize": await sceneMoveResize()
        case "edit-drawer": await sceneEditDrawer()
        case "deadline-add": await sceneDeadlineAdd()
        case "recurring": await sceneRecurring()
        case "search-demo": await sceneSearchDemo()
        case "promote": await scenePromote()
        case "promote-manual": await scenePromoteManual()
        case "daily-dashboard": await sceneDailyDashboard()
        case "dashboard-tour": await sceneDashboardTour()
        case "proj-gantt": await sceneHelpShot(tab: "proj")
        case "todo-panel": await sceneHelpShot(tab: "todo")
        case "note-preview": await sceneHelpShot(tab: "note")
        case "bench-year-scroll": await sceneBenchYearScroll()
        case "bench-year-fling": await sceneBenchYearFling()
        case "bench-month-swipe": await sceneBenchMonthSwipe()
        case "bench-week-swipe": await sceneBenchWeekSwipe()
        case "bench-dash-toggle": await sceneBenchDashToggle()
        case "bench-dash-edit": await sceneBenchDashEdit()
        case "bench-dash-zoomin": await sceneBenchDashZoomIn()
        case "bench-day-swipe": await sceneBenchDaySwipe()
        case "bench-day-roundtrip": await sceneBenchDayRoundtrip()
        case "bench-day-boundary": await sceneDayBoundaryCheck()
        case "bench-hotkey-spam": await sceneBenchHotkeySpam()
        case "bench-weekday-zoom": await sceneBenchWeekDayZoom()
        case "bench-day-zoomin": await sceneBenchDayZoomIn()
        case "bench-pinch-zoom": await sceneBenchPinchZoom()
        case "bench-notify-plan": await sceneBenchNotifyPlan()
        default:
            NSLog("DemoController: UNKNOWN scene '%@' — falling back to timed-week (check the CC_DEMO value)", scene)
            await sceneTimedWeek()
        }
        // Signal the scene's exact end so the recorder can trim the GIF to length (screencapture -V can't be
        // stopped early, so it over-records and we cut back to here). Then idle on the final frame.
        signalDone()
    }

    /// ── Scenes ───────────────────────────────────────────────────────────────────────────────
    /// Timed event in WEEK view: a vertical drag on a day column's timeline creates it (live grow-preview).
    private func sceneTimedWeek() async {
        guard let engine else { return }
        writeCrop(x: 0.09, y: 0.24, w: 0.56, h: 0.42) // hour labels + a few columns around the event
        // OFF-CAMERA setup: seed, then land on the WEEK view (the jump-in + zoom-out animations happen before
        // recording starts, so the GIF is just the drag-create).
        engine.demoClearEvents()
        seedWeek()
        engine.jumpToDay(engine.year, 6, 15) // into the day…
        try? await pause(2.2)
        engine.cmdZoomOut() // …out one level to the WEEK
        try? await pause(1.6)
        signalReady()
        await waitForGo()
        try? await pause(0.3)

        // ON CAMERA: drag down a day column (Mon, ~centered in the crop). x lands inside a column; y0 an
        // empty morning slot.
        let x = size.width * 0.34
        let (y0, y1) = (size.height * 0.40, size.height * 0.60)
        cursor = CGPoint(x: x, y: y0 - 46)
        await move(to: CGPoint(x: x, y: y0), over: 0.55)
        pressed = true
        engine.demoPointerDown(atView: CGPoint(x: x, y: y0))
        await drag(from: CGPoint(x: x, y: y0), to: CGPoint(x: x, y: y1), over: 1.2) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: x, y: y1))
        engine.demoRenameSelected("Coffee with Sam")
        pressed = false
        try? await pause(1.3)
    }

    /// Multi-day BAND in YEAR view: a horizontal drag across days on a month's lane creates it.
    private func sceneBandYear() async {
        guard let engine else { return }
        writeCrop(x: 0.0, y: 0.28, w: 1.0, h: 0.36) // the centered month's row (full day span)
        // OFF-CAMERA setup: seed + land on the year view with July centered, then hold ready.
        engine.demoClearEvents()
        seedYear() // ambient bands across months/lanes so the year isn't empty
        engine.demoGoToYear(centerMonth: 6) // July centered
        try? await pause(0.4)
        signalReady()
        await waitForGo()
        try? await pause(0.4)

        // ON CAMERA: drag horizontally across ~a week on a lane row of the centered month.
        let (x0, x1) = (size.width * 0.30, size.width * 0.46)
        let y = size.height * 0.52
        cursor = CGPoint(x: x0 - 40, y: y)
        await move(to: CGPoint(x: x0, y: y), over: 0.6)
        pressed = true
        engine.demoPointerDown(atView: CGPoint(x: x0, y: y))
        await drag(from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), over: 1.2) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: x1, y: y))
        engine.demoRenameSelectedBand("Conference")
        pressed = false
        try? await pause(1.9)
    }

    /// ── Ambient (decoy) data so the recordings don't look empty ────────────────────────────────
    /// Generic timed events across the visible week (Sun 12 – Sat 18 July). Mon (13) is left clear over
    /// ~10:30–13:45 so the drag has an empty slot to create in.
    func seedWeek(wedCoffee: Bool = true) { // internal: read by DemoController+HelpGIFs.swift
        guard let e = engine else { return }
        let m = 6
        e.demoAddTimed(month: m, day: 13, startHour: 8, endHour: 9, title: "Standup", color: "blue")
        e.demoAddTimed(month: m, day: 13, startHour: 16.5, endHour: 17.5, title: "Gym", color: "green")
        e.demoAddTimed(month: m, day: 12, startHour: 11, endHour: 12, title: "Brunch", color: "orange")
        e.demoAddTimed(month: m, day: 14, startHour: 9, endHour: 10, title: "1:1 with Alex", color: "purple")
        e.demoAddTimed(month: m, day: 14, startHour: 12.5, endHour: 14, title: "Design review", color: "cyan")
        e.demoAddTimed(month: m, day: 15, startHour: 10, endHour: 11, title: "Sprint planning", color: "blue")
        if wedCoffee { // the ai-assistant scene omits this so its created "Coffee chat with Sam" is unique
            e.demoAddTimed(month: m, day: 15, startHour: 13.5, endHour: 14.5, title: "Coffee chat", color: "yellow")
        }
        e.demoAddTimed(month: m, day: 16, startHour: 9, endHour: 9.5, title: "Standup", color: "blue")
        e.demoAddTimed(month: m, day: 16, startHour: 12, endHour: 13, title: "Lunch", color: "orange")
        e.demoAddTimed(month: m, day: 17, startHour: 10.5, endHour: 11.5, title: "Interview", color: "red")
        e.demoAddTimed(month: m, day: 17, startHour: 15, endHour: 16, title: "Retro", color: "green")
        e.demoAddTimed(month: m, day: 18, startHour: 11, endHour: 12, title: "Yoga", color: "purple")
    }

    /// Generic all-day bands across several months + lanes. July's Travel lane (track 3) is left clear over
    /// days ~5–17 so the horizontal drag creates its band there.
    func seedYear() { // internal: read by DemoController+HelpGIFs.swift
        guard let e = engine else { return }
        e.demoAddBand(month: 6, track: 0, startDay: 3, endDay: 8, title: "Course prep", color: "blue")
        e.demoAddBand(month: 6, track: 1, startDay: 10, endDay: 15, title: "Paper draft", color: "purple")
        e.demoAddBand(month: 6, track: 2, startDay: 19, endDay: 24, title: "Committee", color: "green")
        e.demoAddBand(month: 6, track: 3, startDay: 23, endDay: 28, title: "Retreat", color: "orange")
        e.demoAddBand(month: 5, track: 0, startDay: 12, endDay: 18, title: "Workshop", color: "cyan")
        e.demoAddBand(month: 5, track: 2, startDay: 22, endDay: 27, title: "Review", color: "red")
        e.demoAddBand(month: 7, track: 1, startDay: 5, endDay: 11, title: "Summit", color: "indigo")
        e.demoAddBand(month: 7, track: 3, startDay: 14, endDay: 20, title: "Vacation", color: "green")
        e.demoAddBand(month: 4, track: 1, startDay: 8, endDay: 14, title: "Sprint", color: "yellow")
        e.demoAddBand(month: 8, track: 0, startDay: 3, endDay: 9, title: "Onboarding", color: "blue")
    }

    /// Interpolated drag in any direction: moves the synthetic cursor AND feeds each point to `step` (the
    /// engine's real drag handler), so the created event/band tracks the cursor precisely.
    func drag(
        from a: CGPoint,
        to b: CGPoint,
        over duration: Double,
        steps: Int = 34, // internal: read by DemoController+HelpGIFs.swift
        step: (CGPoint) -> Void
    ) async {
        for i in 1 ... steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let p = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            cursor = p; step(p)
            try? await pause(duration / Double(steps))
        }
    }

    private func scenePinchZoom() async {
        guard let engine else { return }
        // No crop: the pinch spans the whole view (year → month → week → day), so record the full window.
        try? await pause(0.5)
        engine.demoClearEvents()
        seedYear() // bands so the year/month levels have content…
        seedWeek() // …and timed events so the week/day levels do too
        engine.demoGoToYear(centerMonth: 6)
        // A distinct, mid-cell pinch location per zoom level (never on a day boundary), so the three zooms
        // don't look static and each clearly targets one month/week/day.
        let centers = [
            CGPoint(x: size.width * 0.46, y: size.height * 0.48), // year → month  (over July's row)
            CGPoint(x: size.width * 0.52, y: size.height * 0.45), // month → week
            CGPoint(x: size.width * 0.58, y: size.height * 0.52), // week → day
        ]

        // Set up off-camera, then wait for the recorder's "go" so the GIF opens exactly on the year view
        // (see record-tutorial.sh), then hold a generous pre-roll on the year view before the first pinch.
        signalReady()
        await waitForGo()
        try? await pause(2.0)

        // Zoom IN through every level (year → month → week → day), then a single zoom-OUT back to the week
        // to show the pinch works both ways — without the full return trip (keeps the GIF short).
        for i in 0 ..< 3 {
            await pinch(around: centers[i], over: 0.55, spreadOut: true); try? await pause(0.9)
        }
        try? await pause(0.7)
        await pinch(around: centers[2], over: 0.55, spreadOut: false) // day → week
        try? await pause(0.9)
        pinchDots = nil
        try? await pause(0.6)
    }

    /// Markdown NOTES in an event: double-click a right-side event → its drawer opens (event highlighted),
    /// then type a markdown TODO checklist into the notes editor and hit Preview to render it.
    private func sceneMarkdownNotes() async {
        guard let engine else { return }
        writeCrop(x: 0.30, y: 0.0, w: 0.70, h: 1.0) // the selected event (recentred) + the drawer
        // OFF-CAMERA: seed the week, add the focus event with EMPTY notes (so its drawer opens in edit mode),
        // land on the week. Thursday (16) sits in the right half → within the crop, a clean double-click target.
        engine.demoClearEvents()
        seedWeek()
        let id = engine.demoAddTimed(month: 6, day: 16, startHour: 14, endHour: 16,
                                     title: "Paper draft review", color: "purple")
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut() // → week view
        try? await pause(1.6)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // ON CAMERA — double-click the event on Thursday (right half of the week; 14:00–16:00, well below
        // the day's other seeds so the double-click lands on it cleanly).
        // Aim by the event's LIVE rect (the week's scroll follows the pinned clock — fixed fractions miss).
        guard let evRect = engine.demoEventRectView(id) else { return }
        let evPt = CGPoint(x: evRect.midX, y: evRect.midY)
        cursor = CGPoint(x: evPt.x - 44, y: evPt.y - 34)
        await move(to: evPt, over: 0.7)
        await doubleClickPulse() // two press rings
        engine.demoDoubleClick(atView: evPt) // select + open drawer (event highlights, slides beside drawer)
        try? await pause(1.3)

        // Click into the notes editor, then type the checklist live.
        let editorPt = CGPoint(x: size.width * 0.86, y: size.height * 0.52)
        await move(to: editorPt, over: 0.7)
        pressed = true; try? await pause(0.16); pressed = false
        try? await pause(0.4)
        await typeNote("""
        ## Prep checklist
        - [ ] Run final experiments  due:2026-07-20 p:!!!
        - [ ] Polish figures  #paper
        - [ ] Email co-authors  @alex
        """)
        try? await pause(0.7)

        // Click the Preview toggle (the eye, bottom-left of the drawer footer) → the markdown renders. Kept
        // above the window's visible bottom (the SwiftUI space overflows the window; see the crop clamp).
        let previewBtn = CGPoint(x: size.width * 0.74, y: size.height * 0.855)
        await move(to: previewBtn, over: 0.8)
        pressed = true; notePreview = true; try? await pause(0.16); pressed = false
        try? await pause(2.6)
    }

    /// Reveal `text` in the drawer's editor progressively, as if typed (a few chars per tick).
    private func typeNote(_ text: String) async {
        noteFeed = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let step = min(2, chars.count - i) // 2 chars/tick → brisk but legibly "typing"
            i += step
            noteFeed = String(chars[0 ..< i])
            try? await pause(0.05)
        }
    }

    /// Two quick press rings — the double-click affordance.
    func doubleClickPulse() async { // internal: read by DemoController+HelpGIFs.swift
        for _ in 0 ..< 2 {
            pressed = true; try? await pause(0.11)
            pressed = false; try? await pause(0.10)
        }
    }

    /// AI ASSISTANT: click the toolbar AI button, then a staged (offline) conversation plays out in an
    /// in-window panel — the user asks, a tool-activity chip appears, the assistant replies — while the
    /// requested event is really added to the calendar behind it.
    private func sceneAIAssistant() async {
        guard let engine else { return }
        // Record the RIGHT HALF: the chat panel plus the strip of calendar beside it (where the created
        // event lands). The real AI button is a native toolbar item we can't overlay a synthetic cursor onto
        // cleanly, so this scene doesn't fake the click — the panel simply opens.
        writeCrop(x: 0.50, y: 0.0, w: 0.50, h: 1.0)
        engine.demoClearEvents()
        seedWeek(wedCoffee: false) // omit the seed "Coffee chat" on Wed → no name clash
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut() // week view
        try? await pause(1.6)

        // Build the offline assistant session (no network — turns are staged directly).
        let a = AssistantState(store: ConversationStore())
        a.engine = engine
        assistant = a
        signalReady()
        await waitForGo()
        try? await pause(0.8)

        // The panel opens (no faked toolbar click — the real AI button is a native toolbar item).
        withAnimationPanel { showAssistantPanel = true }
        try? await pause(0.7)

        // Cursor into the composer, then TYPE the message live (drives state.draft → the real editor).
        let composerPt = CGPoint(x: size.width * 0.82, y: size.height * 0.62)
        cursor = CGPoint(x: composerPt.x - 40, y: composerPt.y + 44)
        await move(to: composerPt, over: 0.7)
        pressed = true; try? await pause(0.14); pressed = false
        try? await pause(0.3)
        let prompt = "Coffee chat with Sam, Wed at 3pm" // fits the composer on one line (no clip/wrap)
        await typeDraft(a, prompt)
        try? await pause(0.4)

        // Move to the send button (bottom-right of the pill) and click it.
        let sendBtn = CGPoint(x: size.width * 0.965, y: size.height * 0.62)
        await move(to: sendBtn, over: 0.6)
        pressed = true; try? await pause(0.18); pressed = false

        // Send (no network): the draft becomes a user bubble, then the assistant "works" — a typing dot, a
        // tool-activity chip for the create, another typing dot, then the reply.
        a.draft = ""
        a.messages.append(ChatTurn(role: .user, text: prompt))
        try? await pause(0.9)
        a.messages.append(ChatTurn(role: .typing, text: ""))
        try? await pause(1.4)
        // Really add the event on Wednesday (visible beside the panel) and select it so it appears
        // highlighted, as a real create would.
        let id = engine.demoAddTimed(month: 6, day: 15, startHour: 15, endHour: 16,
                                     title: "Coffee chat with Sam", color: "blue")
        engine.demoSelect(id)
        a.messages.removeAll { $0.role == .typing }
        a.messages.append(ChatTurn(role: .action, text: "Created “Coffee chat with Sam”", icon: "calendar.badge.plus"))
        try? await pause(1.0)
        a.messages.append(ChatTurn(role: .typing, text: ""))
        try? await pause(1.2)
        a.messages.removeAll { $0.role == .typing }
        a.messages.append(ChatTurn(role: .assistant,
                                   text: "Done — added **Coffee chat with Sam** on Wednesday, July 15 from 3:00–4:00 PM."))
        try? await pause(0.5) // hold on the rendered reply, then end (recorder trims to here)
    }

    /// Reveal `text` in the assistant composer progressively, as if typed (drives state.draft, which the
    /// editor reflects live).
    private func typeDraft(_ a: AssistantState, _ text: String) async {
        a.draft = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let step = min(2, chars.count - i)
            i += step
            a.draft = String(chars[0 ..< i])
            try? await pause(0.045)
        }
    }

    /// A tiny wrapper so the panel's appearance animates (SwiftUI `withAnimation` needs a synchronous body).
    private func withAnimationPanel(_ body: () -> Void) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { body() }
    }

    /// Animate two fingertips spreading apart (`spreadOut`, zoom IN) or together (zoom OUT), driving the real
    /// pinch path (`demoMagnify`) anchored on the centre `c` so the zoom target matches the drawn gesture.
    /// Hides the arrow cursor for the duration so only the two dots + centre marker show.
    private func pinch(around c: CGPoint, over duration: Double, spreadOut: Bool, steps: Int = 24) async {
        guard let engine else { return }
        cursor = nil
        let near: CGFloat = 20, far: CGFloat = 130
        // Total magnification to cross exactly one level: PINCH_SENS=1.6, so ~0.7·1.6≈1.1 Δz — past the .5
        // snap boundary, short of a double jump. `ended` then settles onto the rounded level.
        let totalMag: CGFloat = spreadOut ? 0.70 : -0.70
        func ease(_ x: Double) -> Double {
            x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        }
        var prevE = 0.0
        for i in 0 ... steps {
            let e = ease(Double(i) / Double(steps))
            let r = spreadOut ? near + (far - near) * CGFloat(e) : far - (far - near) * CGFloat(e)
            pinchDots = (CGPoint(x: c.x - r, y: c.y + r * 0.32),
                         CGPoint(x: c.x + r, y: c.y - r * 0.32))
            if i == 0 {
                engine.demoMagnify(delta: 0, atView: c, began: true, ended: false)
            } else if i == steps {
                engine.demoMagnify(delta: 0, atView: c, began: false, ended: true)
            } else {
                engine.demoMagnify(delta: totalMag * CGFloat(e - prevE), atView: c, began: false, ended: false)
            }
            prevE = e
            try? await pause(duration / Double(steps))
        }
    }

    /// ── Cursor motion ──────────────────────────────────────────────────────────────────────────
    func move(to p: CGPoint, over duration: Double,
              steps: Int = 34) async { // internal: read by DemoController+HelpGIFs.swift
        let from = cursor ?? p
        for i in 1 ... steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 // easeInOut
            cursor = CGPoint(x: from.x + (p.x - from.x) * e, y: from.y + (p.y - from.y) * e)
            try? await pause(duration / Double(steps))
        }
    }

    func pause(_ s: Double) async throws { // internal: read by DemoController+Bench.swift/+HelpGIFs.swift
        try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    /// Tell the recorder the scene has finished its OFF-CAMERA setup (seeding, navigating to the starting
    /// view) and is holding, ready to be filmed. The script waits for this before it starts recording, so
    /// setup animations (e.g. zooming into the week) never end up in the GIF.
    func signalReady() { // internal: read by DemoController+HelpGIFs.swift
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty else { return }
        try? "ready\n".write(
            toFile: (dir as NSString).appendingPathComponent("ready.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Block until the recorder drops a `go.txt` in the data dir (or ~4s elapse as a fallback for a manual
    /// run with no recorder). Lets a scene align its first visible frame with the start of the recording.
    func waitForGo() async { // internal: read by DemoController+HelpGIFs.swift
        defer { goTime = Date() } // recording is now rolling — start the on-camera clock
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty else { return }
        let flag = (dir as NSString).appendingPathComponent("go.txt")
        for _ in 0 ..< 40 {
            if FileManager.default.fileExists(atPath: flag) {
                return
            }
            try? await pause(0.1)
        }
    }

    /// Write the on-camera duration (seconds since `go`) to `done.txt` so the recorder can trim the
    /// over-recorded video to the scene's exact end.
    private func signalDone() {
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty,
              let go = goTime else { return }
        let elapsed = Date().timeIntervalSince(go)
        try? String(format: "%.2f\n", elapsed).write(toFile: (dir as NSString).appendingPathComponent("done.txt"),
                                                     atomically: true, encoding: .utf8)
    }

    /// Write the scene's crop region (a fraction of the view) to $CC_DEMO_DATADIR/crop.txt in VIEW-LOCAL
    /// points (top-left origin, relative to the content area). The recording script records only this
    /// region, so each GIF is tight around the events/timeline instead of the whole window.
    /// Internal: the help-shot scenes (DemoController+HelpGIFs.swift) crop to the dashboard panel.
    func writeCrop(x fx: CGFloat, y fy: CGFloat, w fw: CGFloat, h fh: CGFloat) {
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty else { return }
        // Even integers keep the encoder happy; clamp inside the content.
        let x = Int((size.width * fx).rounded()), y = Int((size.height * fy).rounded())
        let w = Int((size.width * fw).rounded()) & ~1, h = Int((size.height * fh).rounded()) & ~1
        let line = "\(x) \(y) \(w) \(h)\n"
        try? line.write(toFile: (dir as NSString).appendingPathComponent("crop.txt"), atomically: true, encoding: .utf8)
    }
}
