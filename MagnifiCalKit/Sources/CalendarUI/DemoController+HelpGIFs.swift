// Help-GIF demo scenes (move-resize … daily-dashboard) + the synthetic-cursor panel window.
// Split from DemoController.swift (audit round, 2026-08-02).

import AppKit
import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

extension DemoController {
    /// ── Help-GIF scenes (docs/help-gif-suggestions.md) ──────────────────────────────────────────
    /// MOVE then RESIZE a timed event in week view: drag its body to a later slot, then drag its bottom
    /// edge to lengthen it — both through the real pointer paths, so previews track live. The target is
    /// aimed by its LIVE on-screen rect (the week's scroll follows the clock, so fixed fractions break).
    func sceneMoveResize() async {
        guard let engine else { return }
        // Full-window recording (no crop).
        engine.demoClearEvents()
        seedWeek()
        let target = engine.demoAddTimed(month: 6, day: 14, startHour: 10.25, endHour: 11.75,
                                         title: "Client call", color: "purple")
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        engine.demoSelect(target)
        engine.demoRevealSelected() // scroll the timeline so the target is comfortably visible
        try? await pause(0.9)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // MOVE: grab the event's centre and drag it ~2 hours later.
        guard let r0 = engine.demoEventRectView(target) else { return }
        let perHour = r0.height / 1.5 // the event spans 1.5h → px per hour
        let grab = CGPoint(x: r0.midX, y: r0.midY)
        cursor = CGPoint(x: grab.x - 60, y: grab.y - 46)
        await move(to: grab, over: 0.7)
        pressed = true
        engine.demoPointerDown(atView: grab)
        await drag(from: grab, to: CGPoint(x: grab.x, y: grab.y + perHour * 2), over: 1.2) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: grab.x, y: grab.y + perHour * 2))
        pressed = false
        try? await pause(1.0)

        // RESIZE: re-read the moved event's rect, grab its bottom edge, pull it an hour longer.
        guard let r1 = engine.demoEventRectView(target) else { return }
        let edge = CGPoint(x: r1.midX, y: r1.maxY - 2)
        await move(to: edge, over: 0.7)
        pressed = true
        engine.demoPointerDown(atView: edge)
        await drag(from: edge, to: CGPoint(x: edge.x, y: edge.y + perHour), over: 1.0) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: edge.x, y: edge.y + perHour))
        pressed = false
        try? await pause(1.4)
    }

    /// EDIT in the drawer: double-click an event → drawer opens (event highlighted) → pick a new color
    /// (cursor over the swatches; the change applies through the engine, so the event recolors live).
    func sceneEditDrawer() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        let id = engine.demoAddTimed(month: 6, day: 16, startHour: 14, endHour: 16,
                                     title: "Paper draft review", color: "purple")
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // Aim by the event's LIVE rect (the week's scroll follows the pinned clock — fixed fractions miss).
        guard let evRect = engine.demoEventRectView(id) else { return }
        let evPt = CGPoint(x: evRect.midX, y: evRect.midY)
        cursor = CGPoint(x: evPt.x - 44, y: evPt.y - 34)
        await move(to: evPt, over: 0.7)
        await doubleClickPulse()
        engine.demoDoubleClick(atView: evPt)
        try? await pause(1.5)

        // Glide across the swatch row with LIVE hover previews, then click ORANGE. Swatch geometry from
        // the drawer's layout: card right margin 10 + width 410 → content left = W−420+18; 17pt circles at
        // 8pt spacing → center x = left + 8.5 + i·25 (EVENT_COLORS order; orange = 7). Row y ≈ 142/840.
        let rowY = size.height * 0.169
        func swatchX(_ i: Int) -> CGFloat {
            size.width - 420 + 18 + 8.5 + CGFloat(i) * 25
        }
        await move(to: CGPoint(x: swatchX(4), y: rowY), over: 0.8)
        engine.setColorPreview(id, "green") // the drawer's real hover preview
        try? await pause(0.55)
        await move(to: CGPoint(x: swatchX(7), y: rowY), over: 0.5)
        engine.setColorPreview(id, "orange")
        try? await pause(0.55)
        pressed = true
        engine.clearColorPreview()
        engine.update(id) { $0.color = "orange" } // commit (what the swatch tap does)
        try? await pause(0.18)
        pressed = false
        try? await pause(2.0)
    }

    /// ADD a DEADLINE via the hover "+": glide along a day column until the quick-add spot appears,
    /// click it (real pointer path → deadline created, drawer opens with the title selected).
    func sceneDeadlineAdd() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        signalReady()
        await waitForGo()
        try? await pause(0.4)

        // The "+" appears only while hovering NEAR A DAY COLUMN'S LEFT EDGE on an hour line — sweep
        // hover probes (invisible) around Thursday ~afternoon until the engine offers the spot, then
        // glide the visible cursor straight onto it and click through the real pointer path.
        let target = CGPoint(x: size.width * 0.665, y: size.height * 0.47)
        cursor = CGPoint(x: target.x - 70, y: target.y - 50)
        await move(to: target, over: 0.8)
        var plus: CGPoint?
        sweep: for dx in stride(from: -34.0, through: 44.0, by: 3.0) {
            for dy in stride(from: -24.0, through: 24.0, by: 6.0) {
                engine.demoHover(atView: CGPoint(x: target.x + dx, y: target.y + dy))
                if let s = engine.demoDeadlineSpotView() {
                    plus = s; break sweep
                }
            }
        }
        guard let plus else { return }
        // Press a few px RIGHT of the spot: the "+" sits exactly on the day's left boundary, and a
        // fraction left of it resolves to the PREVIOUS day (a plain click there navigates instead).
        // Still well inside the click's 12px tolerance.
        let press = CGPoint(x: plus.x + 5, y: plus.y)
        await move(to: press, over: 0.6)
        engine.demoHover(atView: press) // over the "+" → it brightens
        try? await pause(0.6)
        pressed = true
        engine.demoPointerDown(atView: press)
        engine.demoPointerUp(atView: press)
        try? await pause(0.18)
        pressed = false
        try? await pause(1.0)
    }

    /// RECURRING: drag-create a BAND in year view, open its drawer, expand Configuration, and set a
    /// weekly repeat — ghost bars populate across the following weeks/months, which the year view makes
    /// instantly visible (a timed event's ghosts would hide inside single weeks).
    func sceneRecurring() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedYear()
        engine.demoGoToYear(centerMonth: 6) // July centered
        try? await pause(0.5)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // Drag-create a short band on July's Travel lane (same mechanics as the band-year scene).
        let (x0, x1) = (size.width * 0.30, size.width * 0.37)
        let y = size.height * 0.52
        cursor = CGPoint(x: x0 - 40, y: y)
        await move(to: CGPoint(x: x0, y: y), over: 0.6)
        pressed = true
        engine.demoPointerDown(atView: CGPoint(x: x0, y: y))
        await drag(from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), over: 0.9) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: x1, y: y))
        engine.demoRenameSelectedBand("Sprint")
        pressed = false
        try? await pause(0.9)

        // Double-click the band → its drawer opens.
        let mid = CGPoint(x: (x0 + x1) / 2, y: y)
        await doubleClickPulse()
        engine.demoDoubleClick(atView: mid)
        try? await pause(1.4)

        // Expand Configuration, then choose a weekly repeat with an end date — ghost bars appear across
        // the year view's months as the rule lands (driven through the drawer's own state + commit).
        await move(to: CGPoint(x: size.width * 0.79, y: size.height * 0.205), over: 0.8)
        pressed = true; try? await pause(0.15); pressed = false
        configPulse += 1
        try? await pause(1.0)
        await move(to: CGPoint(x: size.width * 0.80, y: size.height * 0.30), over: 0.6)
        pressed = true; try? await pause(0.15); pressed = false
        repeatFeed = Repeat(kind: "weekly")
        try? await pause(1.3)
        await move(to: CGPoint(x: size.width * 0.79, y: size.height * 0.36), over: 0.5)
        pressed = true; try? await pause(0.15); pressed = false
        repeatFeed = Repeat(kind: "weekly", until: String(format: "%04d-09-30", engine.year))
        try? await pause(2.0)
    }

    /// SEARCH: open the toolbar search, type a fuzzy/date query, and fly to the top hit.
    func sceneSearchDemo() async {
        guard let engine, let search = searchState else { return }
        // Full window: toolbar field + dropdown + the fly-to.
        engine.demoClearEvents()
        seedWeek()
        engine.demoGoToYear(centerMonth: 6)
        try? await pause(1.2)
        signalReady()
        await waitForGo()
        try? await pause(0.6)

        // Cursor → the toolbar search button, click, bar expands.
        let btn = CGPoint(x: size.width * 0.885, y: size.height * 0.035)
        cursor = CGPoint(x: btn.x - 60, y: btn.y + 40)
        await move(to: btn, over: 0.7)
        pressed = true; try? await pause(0.15); pressed = false
        openSearchHook?()
        try? await pause(0.7)

        // Type the query (drives the bound SearchState; the async matcher fills the dropdown).
        let query = "coffee wed"
        for i in 1 ... query.count {
            search.query = String(query.prefix(i))
            try? await pause(0.07)
        }
        try? await pause(1.4)
        // Fly to the top hit (what Enter does), then close the bar.
        if let hit = search.results.first {
            engine.revealAndSelect(id: hit.id)
        }
        try? await pause(2.2)
        search.reset()
        try? await pause(0.5)
    }

    /// PROMOTE: right-click an early-morning DEADLINE in week view → "Promote" mirrors it onto the top
    /// track lane (T1) — then drag the ghost bar DOWN two lanes (the lane-only promoted-band drag) to T3.
    func scenePromote() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        let did = engine.createDeadline(year: engine.year, month: 6, day: 16, hour: 7 + 59.0 / 60.0,
                                        title: "Milestone due", color: "red")
        engine.demoSelect(nil)
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        engine.demoScrollTimelineToHour(10) // bring the 7:59 deadline on screen (scroll pins to 16:00)
        try? await pause(0.8)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // Right-click the deadline's moment line → the context callout opens.
        guard let pt = engine.demoDeadlinePointView(did) else { return }
        cursor = CGPoint(x: pt.x - 70, y: pt.y + 55)
        await move(to: pt, over: 0.8)
        pressed = true; try? await pause(0.15); pressed = false
        eventMenuHook?(did, CGRect(x: pt.x, y: pt.y, width: 2, height: 2))
        try? await pause(1.1)

        // Glide down the menu to "Promote" and click it → ghost bar appears on the TOP free lane (T1).
        await move(to: CGPoint(x: pt.x + 180, y: pt.y + 40), over: 0.9) // the callout's Promote row
        pressed = true; try? await pause(0.15); pressed = false
        closeEventMenuHook?()
        engine.togglePromote(did)
        try? await pause(1.5)

        // Drag the ghost DOWN two lanes → T3 (only the lane moves; the date mirrors the deadline).
        guard let ghost = engine.viewBands().first(where: { sourceId(of: $0.id) == did }),
              let r = engine.demoBandRectView(ghost.id) else { return }
        let from = CGPoint(x: r.midX, y: r.midY)
        await move(to: from, over: 0.8)
        pressed = true
        engine.demoPointerDown(atView: from)
        let to = CGPoint(x: from.x, y: from.y + r.height * 2.4)
        await drag(from: from, to: to, over: 1.1) { p in engine.demoPointerDrag(atView: p) }
        engine.demoPointerUp(atView: to)
        pressed = false
        try? await pause(1.4)
    }

    /// PROMOTE (manual): stage the promote scene — seeded week + the 7:59 deadline, morning in view —
    /// then just stay alive: the USER drives the real mouse while the recorder captures.
    func scenePromoteManual() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        _ = engine.createDeadline(year: engine.year, month: 6, day: 16, hour: 7 + 59.0 / 60.0,
                                  title: "Milestone due", color: "red")
        engine.demoSelect(nil)
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        engine.demoScrollTimelineToHour(10)
        try? await pause(0.6)
        signalReady()
        await waitForGo()
        while true {
            engine.wake(); try? await pause(0.5)
        } // recorder kills the app when done
    }

    /// DAILY DASHBOARD: day view's TODO list — varied items (priorities, due dates, tags, people,
    /// links; from the daily note AND an event's notes) — then a click checks one off live.
    func sceneDailyDashboard() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        let gr = engine.demoAddTimed(month: 6, day: 15, startHour: 15, endHour: 16,
                                     title: "Grant review", color: "indigo")
        engine.setNotes(gr, """
        - [ ] Score the proposals p:!! due:2026-07-17
        - [ ] Send summary to the committee @chair
        """)
        let iso = String(format: "%04d-07-15", engine.year)
        // A #pinned row up front so the GIF shows the Pinned section (accent pin) leading
        // the TODO list — the panel's post-webview look.
        let note = """
        ## Today
        - [ ] Rehearse the demo run-through #pinned p:!!
        - [ ] Review the draft due:today p:!!!
        - [ ] Email Alex about the demo @alex
        - [ ] Book flights for the conference #travel due:2026-07-22
        - [ ] Read [the segmentation paper](https://arxiv.org) #reading
        - [x] Post the standup notes
        """
        engine.setDailyNote(iso, note)
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.6)
        signalReady()
        await waitForGo()
        try? await pause(1.0)

        // Cursor onto the FIRST row's checkbox, then the webview's real toggle path — focus the row and
        // activate it, so the genuine check animation + strike-through plays and the note persists.
        _ = iso
        let row = CGPoint(x: size.width * 0.452, y: size.height * 0.414 - 35)
        cursor = CGPoint(x: row.x - 70, y: row.y + 60)
        await move(to: row, over: 0.9)
        dashTodoFocusHook?()
        try? await pause(0.6)
        pressed = true; try? await pause(0.16); pressed = false
        dashTodoToggleHook?()
        try? await pause(2.2)
    }

    /// DASHBOARD TOUR (the tutorial's dashboard page): MONTH view → ⌘B pins the dashboard open on
    /// the TODO tab (the real hotkey path, keycap shown) → the cursor clicks "PROJ" and the
    /// per-project gantt charts appear. Seeded with a month of tokenized todos across two
    /// @project:s (created/done/due histories → interesting bars, a crossed due → hatch, a
    /// milestone deadline + a band event box) so both tabs look lived-in.
    func sceneDashboardTour() async {
        guard let engine else { return }
        // Full-window recording: the month grid + the panel sliding in over its right side.
        engine.demoClearEvents()
        seedWeek()
        seedYear()
        seedDashboardTour()
        if engine.dashPinned {
            engine.toggleDashPin() // defaults leak across runs — always OPEN ON CAMERA
        }
        engine.jumpToMonth(engine.year, 6) // July's month view
        try? await pause(2.4)
        signalReady()
        await waitForGo()
        try? await pause(1.2)

        // ⌘B (the real View ▸ TODO List path: closed month panel → pin open on the TODO tab).
        keyCap = "⌘ B"
        try? await pause(0.8)
        NotificationCenter.default.post(name: .focusDashTodo, object: nil)
        try? await pause(1.4)
        keyCap = nil
        try? await pause(2.6) // dwell: the month's TODO list

        // Click "PROJ": glide onto the tab row (from the SAME dashScopePanels geometry the tab
        // overlay places with) and flip through the real ⌘J path — exactly what the tab does.
        let tab = projTabPoint() ?? CGPoint(x: size.width * 0.9, y: Layout.topPad + Layout.monthH - 14)
        cursor = CGPoint(x: tab.x - 110, y: tab.y + 90)
        await move(to: tab, over: 0.9)
        try? await pause(0.25)
        pressed = true; try? await pause(0.16); pressed = false
        NotificationCenter.default.post(name: .focusDashProj, object: nil)
        try? await pause(3.4) // dwell: the gantt charts
    }

    /// The PROJ tab's view-local point: the tabs row right-aligns 18pt inside the month panel's
    /// right edge (DashTabs order TODO·PROJ·NOTE, ~43pt per label at 11pt tracked caps), on the
    /// row 14pt above the month band's bottom — the DashTabsOverlay formulas, panel geometry from
    /// dashScopePanels (view x = padLeft + panel.x; gutterShift is 0 in demo mode).
    private func projTabPoint() -> CGPoint? {
        guard let engine, let sp = dashScopePanels(engine.snapshotInput()) else { return nil }
        let p = sp.a
        let right = Layout.padLeft + p.x + p.w
        return CGPoint(x: right - 86, y: Layout.topPad + Layout.monthH - 14)
    }

    /// A month of dashboard fodder (July, the demo month): two @project:s with created/done/due
    /// histories in the MONTHLY note, general todos in the monthly + a daily note, an event-note
    /// pair (provenance prefixes), a #pinned row (the Pinned section), a project milestone
    /// deadline, and a band event box on the apollo chart.
    private func seedDashboardTour() {
        guard let engine else { return }
        let y = engine.year
        func d(_ day: Int) -> String {
            String(format: "%04d-07-%02d", y, day)
        }
        engine.setDailyNote(String(format: "month:%04d-07", y), """
        ## Apollo
        - [x] Draft the architecture @project:apollo created:\(d(2)) done:\(d(8))T14:00 due:\(d(7))
        - [x] Build the data importer @project:apollo created:\(d(5)) done:\(d(15))T11:20
        - [ ] Ship the beta build @project:apollo created:\(d(10)) due:\(d(24)) p:!!!
        - [ ] Write onboarding docs @project:apollo created:\(d(16)) due:\(d(29)) #pinned

        ## Paper
        - [x] Run the ablation sweep @project:neurips-paper created:\(d(3)) done:\(d(12))T16:00
        - [ ] Final experiments @project:neurips-paper created:\(d(8)) due:\(d(20)) p:!!
        - [ ] Polish the figures @project:neurips-paper created:\(d(14)) due:\(d(26)) #figures
        - [ ] Camera-ready pass @project:neurips-paper created:\(d(19)) due:\(d(30))

        ## This month
        - [ ] Book flights for the conference #travel due:\(d(22))
        - [x] Submit the expense report done:\(d(9))T10:00
        """)
        engine.setDailyNote(d(21), """
        - [ ] Prepare the demo script due:\(d(22))
        - [ ] Send the agenda to Sam @sam due:\(d(21))
        """)
        let review = engine.demoAddTimed(month: 6, day: 23, startHour: 15, endHour: 16,
                                         title: "Grant review", color: "indigo")
        engine.setNotes(review, """
        - [ ] Score the proposals p:!! due:\(d(24))
        - [ ] Send summary to the committee @chair due:\(d(25))
        """)
        // The apollo chart's milestone rule + event box (bare @project: lines in their notes).
        let launch = engine.createDeadline(year: y, month: 6, day: 28, hour: 17,
                                           title: "Beta launch", color: "red")
        engine.setNotes(launch, "@project:apollo")
        let sprint = engine.demoAddBand(month: 6, track: 1, startDay: 18, endDay: 23,
                                        title: "Apollo sprint", color: "purple")
        engine.setNotes(sprint, "@project:apollo")
        engine.demoSelect(nil)
        engine.todoFeedRefreshNow(today: NativeDashPanel.todayIso()) // land the seeds NOW
    }

    /// ── STILL help shots (scripts/capture-help-shots.sh) ────────────────────────────────────────
    /// One SETTLED frame per scene, not a motion demo: month view, the dashboard pinned open on
    /// `tab` ("todo" | "proj" | "note"), seeded today-relative so every re-capture shows live
    /// bars (a crossed due → hatch, future dues → ticks, a pinned row, the milestone rule and
    /// event box). The scene crops to the panel, signals ready, and holds; the capture script
    /// grabs a single PNG instead of recording a movie.
    func sceneHelpShot(tab: String) async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        seedYear()
        seedHelpShots()
        engine.demoSetDashMonthFrac(0.5) // double the default 0.25 — readable rows/bars in a still
        let today = NativeDashPanel.todayIso()
        let month = (Int(today.dropFirst(5).prefix(2)) ?? 7) - 1
        engine.jumpToMonth(engine.year, month) // this month's month view
        try? await pause(2.4)

        // Pin the panel open at MONTH level (the pin can also LEAK open from a previous run's
        // UserDefaults — then it's already out and posting ⌘B again would retract it). The
        // hotkey is a no-op while the month-jump is still in flight (dashHotkey ignores the
        // year level), so post-and-poll until the pin actually lands.
        for _ in 0 ..< 4 where !engine.dashPinned {
            NotificationCenter.default.post(name: .focusDashTodo, object: nil)
            for _ in 0 ..< 15 where !engine.dashPinned {
                try? await pause(0.1)
            }
        }
        // Land on the target tab like a TAB CLICK (dashSetTabHook), not the ⌘E/⌘J hotkeys:
        // ⌘E forces the note EDITOR (the shot wants the arrival-rule PREVIEW of a written
        // note), and a re-posted hotkey on its own tab retracts the panel.
        try? await pause(1.2)
        dashSetTabHook?(tab == "proj" ? .proj : tab == "note" ? .note : .todo)
        try? await pause(2.0) // tab mount + slide-in fully settled
        cropToDashPanel(tab: tab)
        signalReady()
        await waitForGo()
        try? await pause(0.8) // hold the settled frame while the script grabs it
    }

    /// Crop to the open dashboard panel — the scope panel's rect from dashScopePanels, the same
    /// geometry the chrome draws with (see projTabPoint). Vertically: from just above the header
    /// block (kicker + title + tabs live in the band's lower half) to the panel bottom — except
    /// the PROJ tab, whose content-sized chart stack would leave the still half dead space, so
    /// its bottom is estimated from the feed (NativeProjPanel's row metrics).
    private func cropToDashPanel(tab: String) {
        guard let engine else { return }
        let input = engine.snapshotInput()
        guard let sp = dashScopePanels(input) else { return }
        let p = sp.a
        let dy = dashBodyPanels(input).first?.dy ?? 0
        // Geometry space → view: −gutterShift (the pinned month view reclaims the label gutter,
        // shifting the whole scene left — p.x alone landed the crop ~275pt right of the panel).
        let x = max(0, Layout.padLeft + p.x - engine.gutterShift - 8)
        let y = max(0, Layout.topPad + dy + Layout.monthH - 96)
        var h = size.height - y
        if tab == "proj" {
            let key = String(NativeDashPanel.todayIso().prefix(7))
            let feed = ProjIndex.shown(engine.projFeed(today: NativeDashPanel.todayIso()),
                                       rs: key + "-01", re: CalendarEngine.monthEndIso(key))
            // Per chart: section header (~30) + headroom + rows + two axis rows + stack spacing.
            let charts = feed.reduce(CGFloat(0)) { acc, proj in
                let rows = CGFloat(min(proj.tasks.count, ProjIndex.maxRows))
                let headroom: CGFloat = proj.deadlines.isEmpty && proj.events.isEmpty ? 24 : 36
                return acc + 30 + headroom + rows * NativeProjPanel.rowH + 36 + 22
            }
            let bodyTop = Layout.topPad + dy + Layout.monthH + 14
            h = min(h, bodyTop + charts + 10 - y)
        }
        writeCrop(x: x / size.width, y: y / size.height,
                  w: 1 - x / size.width, h: h / size.height) // script clamps to the window
    }

    /// seedDashboardTour's cast re-anchored on the REAL today (demo mode doesn't pin the date),
    /// so the captured stills read current whenever they're re-taken: bars land around the now
    /// line, one due is crossed (hatch), the rest lie ahead (ticks), and the month view is the
    /// month being captured.
    private func seedHelpShots() {
        guard let engine else { return }
        let today = NativeDashPanel.todayIso()
        func d(_ off: Int) -> String {
            TodoIndex.addDuration(today, off, "d")
        }
        /// (month index, day) of an ISO date, clamped into TODAY's month for the month-locked
        /// seeds (bands/events near a month edge just hug the boundary).
        func md(_ iso: String) -> (m: Int, day: Int) {
            let p = iso.split(separator: "-").compactMap { Int($0) }
            let t = today.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3, t.count == 3 else { return (6, 15) }
            if p[0] < t[0] || (p[0] == t[0] && p[1] < t[1]) {
                return (t[1] - 1, 1)
            }
            if p[0] > t[0] || (p[0] == t[0] && p[1] > t[1]) {
                let last = Int(CalendarEngine.monthEndIso(String(today.prefix(7))).suffix(2)) ?? 28
                return (t[1] - 1, last)
            }
            return (p[1] - 1, p[2])
        }
        engine.setDailyNote("month:" + today.prefix(7), """
        ## Apollo
        - [x] Draft the architecture @project:apollo created:\(d(-12)) done:\(d(-6))T14:00 due:\(d(-7))
        - [x] Build the data importer @project:apollo created:\(d(-9)) start:\(d(-5)) done:\(d(-1))T11:20
        - [ ] Ship the beta build @project:apollo created:\(d(-4)) due:\(d(9)) p:!!! #proj-pinned
        - [ ] Write onboarding docs @project:apollo created:\(d(-2)) due:\(d(14)) #pinned

        ## Paper
        - [x] Run the ablation sweep @project:neurips-paper created:\(d(-11)) done:\(d(-2))T16:00
        - [ ] Final experiments @project:neurips-paper created:\(d(-6)) due:\(d(5)) p:!!
        - [ ] Polish the figures @project:neurips-paper created:\(d(-3)) due:\(d(11)) #figures
        - [ ] Camera-ready pass @project:neurips-paper created:\(d(-1)) due:\(d(16))

        ## This month
        - [ ] Revise the intro section p:!!!! due:\(d(-1))
        - [ ] Book flights for the conference #travel due:\(d(8))
        - [ ] Circle back with the reviewers followup:\(d(4)) @chair
        - [x] Submit the expense report done:\(d(-3))T10:00
        """)
        engine.setDailyNote(today, """
        - [ ] Prepare the demo script due:\(d(1))
        - [ ] Send the agenda to Sam @sam due:\(today)
        """)
        let rev = md(d(2))
        let review = engine.demoAddTimed(month: rev.m, day: rev.day, startHour: 15, endHour: 16,
                                         title: "Grant review", color: "indigo")
        engine.setNotes(review, """
        - [ ] Score the proposals p:!! due:\(d(3))
        - [ ] Send summary to the committee @chair due:\(d(4))
        """)
        // The apollo chart's milestone rule + event box (bare @project: lines in their notes).
        let dl = md(d(9))
        let launch = engine.createDeadline(year: engine.year, month: dl.m, day: dl.day, hour: 17,
                                           title: "Beta launch", color: "red")
        engine.setNotes(launch, "@project:apollo")
        let (b0, b1) = (md(d(-3)), md(d(2)))
        // Track 2: free of seedYear's ambient bands in any nearby month (track 1 holds
        // August's "Summit", which would collide with a same-track sprint band).
        let sprint = engine.demoAddBand(month: b1.m, track: 2,
                                        startDay: b0.m == b1.m ? b0.day : 1, endDay: b1.day,
                                        title: "Apollo sprint", color: "purple")
        engine.setNotes(sprint, "@project:apollo")
        engine.demoSelect(nil)
        engine.todoFeedRefreshNow(today: today) // land the seeds NOW
    }

    /// Float the synthetic cursor in a borderless, click-through panel window pinned over the main
    /// window's content area — above EVERY window layer, including NSPopover callouts (which sit over the
    /// whole SwiftUI hierarchy and would otherwise cover an in-tree cursor overlay).
    func installCursorPanel() {
        guard cursorPanel == nil, let win = NSApp.mainWindow, let content = win.contentView else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.contentView = NSHostingView(rootView: DemoCursorOverlay(demo: self))
        panel.setFrame(win.convertToScreen(content.convert(content.bounds, to: nil)), display: true)
        win.addChildWindow(panel, ordered: .above)
        cursorPanel = panel
        cursorPanelUp = true
    }
}
