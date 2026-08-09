// Benchmark scenes (CC_DEMO=bench-*) + the FPS-HUD tick/stats plumbing and bench.json output.
// Split from DemoController.swift (audit round, 2026-08-02).

import AppKit
import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

extension DemoController {
    /// ── Benchmarks (CC_DEMO=bench-*: measure, don't record) ───────────────────────────────────
    /// Live FPS HUD toggle (works in ANY run: Xcode-attached, standalone, the signed app). Enable with the
    /// env var CC_FPS_HUD=1 (add it to the Xcode scheme) or `defaults write … cc.fpsHUD -bool YES`.
    private static let envHUD = ProcessInfo.processInfo.environment["CC_FPS_HUD"] != nil
    public static var hudEnabled: Bool {
        envHUD || UserDefaults.standard.bool(forKey: "cc.fpsHUD")
    }

    /// Per-frame hook from the render TimelineView (one evaluation = one rendered frame). A cheap no-op
    /// unless a bench scene is recording or the HUD is on; same-date re-evaluations dedupe.
    public func benchTick(_ date: Date) {
        guard benchActive || Self.hudEnabled else { return }
        let t = date.timeIntervalSinceReferenceDate
        if benchActive, benchFrames.last != t {
            benchFrames.append(t)
        }
        if Self.hudEnabled, hudRing.last != t {
            hudRing.append(t)
            if hudRing.count > 480 {
                hudRing.removeFirst(hudRing.count - 480)
            }
        }
    }

    /// Stats over the last second of rendered frames (nil while idle/paused). The sleep-aware
    /// math lives in CalendarRender/BenchStats (shared with the iPhone bench runner).
    public func hudStats() -> (fps: Double, p95ms: Double, maxms: Double)? {
        BenchStats.hudStats(ring: hudRing) { a, b in engine?.sleepOverlap(a, b) ?? 0 }
    }

    /// YEAR-view scroll benchmark. The payload (bench/year-bands-2026.json — a real year of bands) is
    /// pre-copied into the throwaway store as data.json, so the engine loads it like user data. Glide
    /// Jan→Dec→Jan with the pace-locked keyboard-scroll tween while recording per-frame timestamps, then
    /// write fps/frame-time stats to $CC_DEMO_DATADIR/bench.json for the script to print.
    func sceneBenchYearScroll() async {
        guard let engine else { return }
        try? await pause(1.2) // launch settle: store load + first layout
        engine.demoGoToYear(centerMonth: 0) // January at the top
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        // CC_BENCH_HOVER=1 → wiggle a synthetic pointer over the content during the glide, exercising the
        // real per-move hover/hit-test path a trackpad scroll pays (mouseMoved → onHover → bandAt).
        let hover = ProcessInfo.processInfo.environment["CC_BENCH_HOVER"] != nil
        var hoverStep = 0
        for target in [11, 0] { // Jan → Dec, then back to Jan
            engine.demoScrollYearToMonth(target)
            while !engine.demoYearScrollSettled { // keep the render loop awake through the glide
                engine.wake()
                if hover {
                    hoverStep += 1 // drift horizontally over the band lanes
                    let x = size.width * (0.25 + 0.5 * abs(sin(Double(hoverStep) * 0.11)))
                    engine.demoHover(atView: CGPoint(x: x, y: size.height * 0.5))
                }
                try? await pause(Self.frameStep) // ~per-frame, like a trackpad's move events
            }
            try? await pause(0.25)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Fling-speed year scroll through the REAL scroll-mirror path (`setYearScroll`, the same
    /// call the NSScrollView driver makes per event) — much faster than the pace-locked glide:
    /// the full year sweeps in ~1s each way, with a per-frame hover like a real trackpad.
    func sceneBenchYearFling() async {
        guard let engine else { return }
        try? await pause(1.2)
        engine.demoGoToYear(centerMonth: 0)
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        let maxY = yearMaxScroll(engine.viewport)
        var hoverStep = 0
        // Sweep speed is tunable: CC_BENCH_FLING_STEPS=N sets the frames-per-sweep (default 120 ≈ a ~1s
        // heavy fling). FEWER steps ⇒ a bigger scroll jump per frame ⇒ a FASTER scroll (e.g. 30 sweeps the
        // whole year in ~0.25s — a violent flick that stresses per-frame scene rebuild the hardest). Passes
        // through the SAME setYearScroll mirror a real trackpad drives, so it stays representative.
        let steps = max(2, ProcessInfo.processInfo.environment["CC_BENCH_FLING_STEPS"].flatMap { Int($0) } ?? 120)
        for (from, to) in [(CGFloat(0), maxY), (maxY, CGFloat(0))] { // fast down, fast up
            engine.beginYearScrollGesture()
            for i in 0 ... steps {
                let t = CGFloat(i) / CGFloat(steps)
                engine.setYearScroll(from + (to - from) * t)
                hoverStep += 1
                let x = size.width * (0.25 + 0.5 * abs(sin(Double(hoverStep) * 0.11)))
                engine.demoHover(atView: CGPoint(x: x, y: size.height * 0.5))
                engine.wake()
                try? await pause(0.008)
            }
            engine.endYearScrollGesture()
            try? await pause(0.25)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Month-view page turns across the DENSE months (Jun→Sep and back): drives the pager mirror
    /// (`setMonthProgress`) through full page-turn ramps, so `monthAnim` is live — the path that
    /// renders BOTH months' grids + event overlays every frame. This is the "swipe between
    /// monthly views" cost the year-scroll scenes never measure.
    func sceneBenchMonthSwipe() async {
        guard let engine else { return }
        try? await pause(1.2)
        engine.setView(zoom: "month", focusedMonth: 5) // June
        try? await pause(0.8)
        await benchDashSetup() // CC_BENCH_DASH / CC_BENCH_DASH_TAB: swipe with the panel out
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        let pageH = size.height
        let dwell = ProcessInfo.processInfo.environment["CC_BENCH_DWELL"] != nil
        let env = ProcessInfo.processInfo.environment
        // Swipe SPEED: CC_BENCH_SWIPE_STEPS=N frames per page-turn (default 40 ≈ a relaxed swipe). FEWER
        // steps ⇒ a bigger progress jump per frame ⇒ a FASTER flick — set 8–12 for the "very very rapid"
        // back-and-forth a real trackpad does. CC_BENCH_SWIPE_GAP=secs is the settle between turns (default
        // 0.15; drop to ~0.02 so turns land in rapid succession and the 1-second HUD window stays inside the
        // churn — that's when the neighbor-month pre-mount hitches stack up and the visible fps sags).
        let steps = max(2, Int(env["CC_BENCH_SWIPE_STEPS"].flatMap { Int($0) } ?? 40))
        let gap = Double(env["CC_BENCH_SWIPE_GAP"].flatMap { Double($0) } ?? 0.15)
        // CC_BENCH_MONTHS="5,6,7" → walk Jun→Jul→Aug and back, adjacent turns only, ×3 (a two- or
        // N-month list both work). Default: the Jun→Sep tour with revisits.
        var pairs: [(Int, Int)] = [(5, 6), (6, 7), (7, 8), (8, 7), (7, 6), (6, 7), (7, 8), (8, 7), (7, 6)]
        if let spec = env["CC_BENCH_MONTHS"] {
            let mm = spec.split(separator: ",").compactMap { Int($0) }
            if mm.count >= 2 {
                // adjacent transitions forward then backward (5→6→7→6→5), repeated for a sustained run
                let fwd = zip(mm, mm.dropFirst()).map { ($0, $1) }
                let leg = fwd + fwd.reversed().map { ($0.1, $0.0) }
                pairs = leg + leg + leg
            }
        }
        for (from, to) in pairs {
            engine.beginMonthGesture()
            if dwell { // A/B: let the neighbor pre-mount land on STATIC frames before moving
                for _ in 0 ..< 30 {
                    engine.wake(); try? await pause(Self.frameStep)
                }
            }
            moveStart = Date.timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = easeOutQuad(CGFloat(i) / CGFloat(steps))
                let y = (CGFloat(from) + CGFloat(to - from) * t) * pageH
                engine.setMonthProgress(y, pageH: pageH)
                engine.wake()
                try? await pause(0.008)
            }
            benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
            engine.endMonthGesture()
            try? await pause(gap)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    private func easeOutQuad(_ t: CGFloat) -> CGFloat {
        1 - (1 - t) * (1 - t)
    }

    /// Week-view page turns inside ONE month: drives the week pager mirror (`setWeekProgress`, the
    /// same call the WeekPager's scroll observation makes) through full swipe ramps, so the 7-day
    /// window slides between adjacent weeks with events/deadline pills/dashboard live — the "swipe
    /// between weekly views" cost none of the month/year scenes measure. Speed reuses the month
    /// scene's knobs (CC_BENCH_SWIPE_STEPS frames per turn, CC_BENCH_SWIPE_GAP settle secs).
    /// CC_BENCH_WEEK_MONTH picks the month (0-based, default 0 = January — the reproduced real-world
    /// dip) and CC_BENCH_WEEKS the walked week indices (0-based within the month's weekly rows,
    /// default "2,3" — the breadcrumb's Week 3⇄Week 4), forward then back, ×3 for a sustained run.
    func sceneBenchWeekSwipe() async {
        guard let engine else { return }
        try? await pause(1.2)
        let env = ProcessInfo.processInfo.environment
        let month = max(0, min(11, env["CC_BENCH_WEEK_MONTH"].flatMap { Int($0) } ?? 0))
        var weeks = env["CC_BENCH_WEEKS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [2, 3]
        if weeks.count < 2 {
            weeks = [2, 3]
        }
        engine.demoGoToWeek(month: month, week: CGFloat(weeks[0]))
        try? await pause(0.8)
        // CC_BENCH_DASH=1 → run the same swipes with the ⌘B side panel PINNED OPEN (the reported
        // regression: week paging with the dashboard out). Pin before recording so the pin tween
        // itself doesn't pollute the swipe stats (bench-dash-toggle measures that separately).
        await benchDashSetup() // CC_BENCH_DASH / CC_BENCH_DASH_TAB
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        // The pager's cell width — mirrors WeekPager: the visible window inside the padding + gutter.
        let dayW = max(1, (size.width - Layout.padLeft - Layout.padRight - Layout.labelW) / Layout.weekDaysVisible)
        let steps = max(2, env["CC_BENCH_SWIPE_STEPS"].flatMap { Int($0) } ?? 40)
        let gap = env["CC_BENCH_SWIPE_GAP"].flatMap { Double($0) } ?? 0.15
        // Adjacent transitions forward then backward (2→3→2), repeated — same shape as the month tour.
        let fwd = zip(weeks, weeks.dropFirst()).map { ($0, $1) }
        let leg = fwd + fwd.reversed().map { ($0.1, $0.0) }
        for (from, to) in leg + leg + leg {
            engine.beginWeekGesture()
            moveStart = Date.timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = easeOutQuad(CGFloat(i) / CGFloat(steps))
                let x = (CGFloat(from) + CGFloat(to - from) * t) * 7 * dayW
                engine.setWeekProgress(x, dayW: dayW)
                engine.wake()
                try? await pause(0.008)
            }
            benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
            engine.endWeekGesture()
            try? await pause(gap)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// ⌘B dashboard-pin toggle benchmark: repeatedly open/retract the pinned side panel at MONTH or
    /// WEEK level (CC_BENCH_DASH_LEVEL=month|week, default month; CC_BENCH_WEEK_MONTH picks the month
    /// for both). Each toggle runs the 0.3s dashPinTween, during which dashPin re-derives the WHOLE
    /// month/week geometry every frame (day widths shrink/grow) AND the panel webview rides the mask
    /// edge — the reported "⌘B drops the framerate" cost. Toggle windows are recorded as moving
    /// phases so the stats isolate the tween frames from the settles between.
    func sceneBenchDashToggle() async {
        guard let engine else { return }
        try? await pause(1.2)
        let env = ProcessInfo.processInfo.environment
        let month = max(0, min(11, env["CC_BENCH_WEEK_MONTH"].flatMap { Int($0) } ?? 5))
        if env["CC_BENCH_DASH_LEVEL"] == "week" {
            engine.demoGoToWeek(month: month, week: 2)
        } else {
            engine.setView(zoom: "month", focusedMonth: month)
        }
        try? await pause(1.0)
        // Deterministic start: panel retracted (dashPinned persists in UserDefaults across runs).
        if engine.dashPinned {
            engine.toggleDashPin()
            for _ in 0 ..< 40 {
                engine.wake(); try? await pause(Self.frameStep)
            }
        }
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        // CC_BENCH_DASH_PERIOD=secs → RAPID toggling: fire ⌘B every `period` seconds (0.35 ≈ the
        // "hammering cmd+b 2-3×/sec" repro), so each toggle RETARGETS the still-running 0.3s pin
        // tween (and the gutter slide) mid-flight — the panel never rests. One continuous moving
        // window spans the whole burst. Without the env: 3 settled open/close cycles (the default).
        if let period = env["CC_BENCH_DASH_PERIOD"].flatMap({ Double($0) }) {
            let toggles = max(2, env["CC_BENCH_DASH_TOGGLES"].flatMap { Int($0) } ?? 12)
            moveStart = Date.timeIntervalSinceReferenceDate
            for _ in 0 ..< toggles {
                engine.toggleDashPin()
                let steps = max(1, Int(period / Self.frameStep))
                for _ in 0 ..< steps {
                    engine.wake(); try? await pause(Self.frameStep)
                }
            }
            // Ride out the last tween so its tail frames stay inside the moving window.
            for _ in 0 ..< 28 {
                engine.wake(); try? await pause(Self.frameStep)
            }
            benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
        } else {
            for _ in 0 ..< 6 { // 3 full open/close cycles
                engine.toggleDashPin()
                moveStart = Date.timeIntervalSinceReferenceDate
                // Keep the render loop awake through the 0.3s tween + a short settle (the wake loop
                // is what a real ⌘B gets from the tween's own animation pump). The MOVING window
                // records only the tween itself — deferred content that fills in on the settled
                // frames right after is by design (invisible), not jank.
                for _ in 0 ..< 28 {
                    engine.wake(); try? await pause(Self.frameStep)
                }
                benchMoves.append((moveStart, moveStart + 0.32))
                try? await pause(0.25)
            }
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Dashboard EDIT-ECHO benchmark: with the ⌘B panel pinned open (month or week level, same
    /// CC_BENCH_DASH_LEVEL knob), append characters to TODAY's daily note at typing cadence.
    /// Every edit bumps editGen → a fresh dashboardDataJSON → CK.setData in the page — the path a
    /// notepad keystroke's echo takes, which re-renders every mounted panel. With a note-heavy
    /// store this is where "typing in the notepad feels laggy" lives. Measures native frames +
    /// the page's rAF cadence + slow setData/tick applies (web_* / WEB-SLOWTICK fields).
    func sceneBenchDashEdit() async {
        guard let engine else { return }
        try? await pause(1.2)
        let env = ProcessInfo.processInfo.environment
        let month = max(0, min(11, env["CC_BENCH_WEEK_MONTH"].flatMap { Int($0) } ?? 6))
        if env["CC_BENCH_DASH_LEVEL"] == "week" {
            engine.demoGoToWeek(month: month, week: 2)
        } else {
            engine.setView(zoom: "month", focusedMonth: month)
        }
        try? await pause(1.0)
        if !engine.dashPinned {
            engine.toggleDashPin()
        }
        for _ in 0 ..< 60 {
            engine.wake(); try? await pause(Self.frameStep)
        } // panel out + first render settled
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        // Type a burst into today's note: 40 appends at ~70ms (a brisk ~14 cps typist). The note
        // already carries a todo line so every keystroke re-tokenizes real content.
        let iso = String(format: "%04d-%02d-15", engine.year, month + 1)
        let base = engine.dailyNote(iso)
        var text = base.isEmpty ? "- [ ] bench typing target" : base
        moveStart = Date.timeIntervalSinceReferenceDate
        for i in 0 ..< 40 {
            text += String(UnicodeScalar(97 + i % 26)!)
            engine.setDailyNote(iso, text)
            for _ in 0 ..< 4 {
                engine.wake(); try? await pause(0.0175)
            }
        }
        benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
        RenderProf.mark("benchEnd")
        benchActive = false
        engine.setDailyNote(iso, base) // leave the throwaway store's note as found
        writeBenchResults()
    }

    /// The user's "click into July" freeze repro: launch at YEAR view with the dashboard PINNED,
    /// then an ANIMATED zoom into the month — the panel presents mid-tween, paying the cold
    /// todo-feed parse + the panel's first mount inside the animation. Frames are recorded through
    /// the zoom; afterwards a forced cold rebuild of the feed is timed on its own (noteGen bump →
    /// todoFeed) and written alongside the frame stats.
    func sceneBenchDashZoomIn() async {
        guard let engine else { return }
        try? await pause(1.4)
        engine.demoGoToYear(centerMonth: 6)
        engine.pinDashboard() // persisted-pin case: the panel pops as the month opens
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        moveStart = Date.timeIntervalSinceReferenceDate
        engine.setView(zoom: "month", focusedMonth: 6) // the animated year→month zoom
        for _ in 0 ..< 70 {
            engine.wake(); try? await pause(Self.frameStep)
        }
        benchMoves.append((moveStart, moveStart + 0.7))
        RenderProf.mark("benchEnd")
        benchActive = false
        // Cold-feed rebuild cost, measured off the animation: bump noteGen, time todoFeed.
        engine.setDailyNote("2099-01-01", "- [ ] rebuild probe")
        let t0 = Date()
        _ = engine.todoFeed(today: NativeDashPanel.todayIso())
        let feedMs = Date().timeIntervalSince(t0) * 1000
        engine.setDailyNote("2099-01-01", "")
        if let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty {
            try? String(format: "%.1f\n", feedMs)
                .write(toFile: (dir as NSString).appendingPathComponent("todofeed-ms.txt"),
                       atomically: true, encoding: .utf8)
        }
        writeBenchResults()
    }

    /// CC_BENCH_DASH=1 → pin the ⌘B panel open (instant persisted pin — the pin TWEEN is
    /// bench-dash-toggle's own subject) before recording; CC_BENCH_DASH_TAB=proj|note
    /// additionally flips the panel to that tab through the same notifications the ⌘J/⌘E menu
    /// items post, so the swipe/zoom scenes can exercise every panel body, not just TODO.
    private func benchDashSetup() async {
        guard let engine else { return }
        let env = ProcessInfo.processInfo.environment
        if env["CC_BENCH_DASH"] != nil, !engine.dashPinned {
            engine.pinDashboard()
            for _ in 0 ..< 40 {
                engine.wake(); try? await pause(Self.frameStep)
            }
        }
        switch env["CC_BENCH_DASH_TAB"] {
        case "proj": NotificationCenter.default.post(name: .focusDashProj, object: nil)
        case "note": NotificationCenter.default.post(name: .focusDashNote, object: nil)
        default: return
        }
        for _ in 0 ..< 40 {
            engine.wake(); try? await pause(Self.frameStep)
        } // tab carousel + mount
    }

    /// DAY-view horizontal paging: adjacent day↔day swipes through the REAL gesture path
    /// (beginDayGesture / setDayProgress / endDayGesture — the same projection the pager's
    /// scroll feed drives), forward then back, ×2 tours. The native day panels carousel with
    /// each swipe; the reported "swipe stops midway" stutter runs exactly this code.
    func sceneBenchDaySwipe() async {
        guard let engine else { return }
        try? await pause(1.2)
        let env = ProcessInfo.processInfo.environment
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(1.2) // ride out the fly-to + first panel mount
        await benchDashSetup() // CC_BENCH_DASH_TAB: swipe on the PROJ/NOTE tab too
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        let steps = max(2, env["CC_BENCH_SWIPE_STEPS"].flatMap { Int($0) } ?? 40)
        let gap = env["CC_BENCH_SWIPE_GAP"].flatMap { Double($0) } ?? 0.15
        let legs = [(15, 16), (16, 17), (17, 16), (16, 15)]
        for (from, to) in legs + legs {
            let dayW = max(1, engine.daily.frac * (size.width - Layout.labelW))
            engine.beginDayGesture()
            moveStart = Date.timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = easeOutQuad(CGFloat(i) / CGFloat(steps))
                let x = (CGFloat(from) - 1 + CGFloat(to - from) * t) * dayW
                engine.setDayProgress(x)
                engine.wake()
                try? await pause(0.008)
            }
            benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
            _ = engine.endDayGesture()
            try? await pause(gap)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// ⌘E / ⌘J spam through the REAL hotkey path (the focusDash* notifications →
    /// ViewPrefObservers.dashHotkey → pin toggle + tab flip + focus) — the reported "spamming
    /// cmd+j is really bad" case. CC_BENCH_HOTKEY=note|proj|todo picks the key (default proj);
    /// CC_BENCH_DASH_PERIOD paces it (0.35 ≈ hammering); CC_BENCH_DASH_LEVEL month|week.
    func sceneBenchHotkeySpam() async {
        guard let engine else { return }
        try? await pause(1.2)
        let env = ProcessInfo.processInfo.environment
        let month = max(0, min(11, env["CC_BENCH_WEEK_MONTH"].flatMap { Int($0) } ?? 6))
        if env["CC_BENCH_DASH_LEVEL"] == "week" {
            engine.demoGoToWeek(month: month, week: 2)
        } else {
            engine.setView(zoom: "month", focusedMonth: month)
        }
        try? await pause(1.0)
        if engine.dashPinned { // deterministic start: retracted
            engine.toggleDashPin()
            for _ in 0 ..< 40 {
                engine.wake(); try? await pause(Self.frameStep)
            }
        }
        let name: Notification.Name = switch env["CC_BENCH_HOTKEY"] {
        case "note": .focusDashNote
        case "todo": .focusDashTodo
        default: .focusDashProj
        }
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        let period = env["CC_BENCH_DASH_PERIOD"].flatMap { Double($0) } ?? 0.35
        let toggles = max(2, env["CC_BENCH_DASH_TOGGLES"].flatMap { Int($0) } ?? 12)
        moveStart = Date.timeIntervalSinceReferenceDate
        for _ in 0 ..< toggles {
            NotificationCenter.default.post(name: name, object: nil)
            let steps = max(1, Int(period / Self.frameStep))
            for _ in 0 ..< steps {
                engine.wake(); try? await pause(Self.frameStep)
            }
        }
        for _ in 0 ..< 28 {
            engine.wake(); try? await pause(Self.frameStep)
        }
        benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Week↔day zoom (the reported subtle stutter): rest at a July week with the panel pinned,
    /// zoom into a mid-week day, rest, zoom back out — ×3 round trips, each leg a moving phase.
    func sceneBenchWeekDayZoom() async {
        guard let engine else { return }
        try? await pause(1.2)
        engine.demoGoToWeek(month: 6, week: 2)
        if !engine.dashPinned {
            engine.pinDashboard()
        }
        try? await pause(1.0)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        for _ in 0 ..< 3 {
            moveStart = Date.timeIntervalSinceReferenceDate
            engine.jumpToDay(engine.year, 6, 15) // week → day
            for _ in 0 ..< 55 {
                engine.wake(); try? await pause(Self.frameStep)
            }
            benchMoves.append((moveStart, moveStart + 0.8))
            moveStart = Date.timeIntervalSinceReferenceDate
            engine.setView(zoom: "week") // day → week
            for _ in 0 ..< 55 {
                engine.wake(); try? await pause(Self.frameStep)
            }
            benchMoves.append((moveStart, moveStart + 0.8))
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// STUCK-SWIPE diagnostic: land on Aug 1, swipe LEFT across the July boundary (arming the
    /// month flip), pump frames, then attempt a normal right swipe — dumping engine state at
    /// every step to /tmp/cc-day-boundary.txt. If the flip wedges (isDayFlipping stuck, or the
    /// post-flip swipe doesn't move dom), this reproduces the reported freeze engine-side.
    func sceneDayBoundaryCheck() async {
        guard let engine else { return }
        try? await pause(1.4)
        engine.jumpToDay(engine.year, 7, 1) // Aug 1
        try? await pause(1.4)
        var log: [String] = []
        func snap(_ tag: String) {
            log.append("\(tag): dom=\(engine.daily.dom) focus=\(engine.focus) "
                + "animDir=\(engine.daily.anim?.dir ?? 0) animP=\(engine.daily.anim?.p ?? -1) "
                + "flip=\(engine.isDayFlipping) armed=\(engine.dayFlipArmed) level=\(engine.chrome.level)")
        }
        benchFrames.removeAll(); benchActive = true // keep the script's bench.json contract
        snap("landed")
        let dayW = max(1, engine.daily.frac * (size.width - Layout.labelW))
        // Swipe LEFT past the month edge: negative offset beyond the 40px arm threshold.
        engine.beginDayGesture()
        for i in 0 ... 20 {
            engine.setDayProgress(-CGFloat(i) / 20 * 120)
            engine.wake()
            try? await pause(0.008)
        }
        snap("pulled")
        let flipped = engine.endDayGesture()
        snap("gesture-ended flipStarted=\(flipped)")
        for _ in 0 ..< 80 {
            engine.wake(); try? await pause(Self.frameStep)
        } // ride the 0.42s flip
        snap("after-1.3s")
        // A normal right swipe back toward Aug: does the engine still respond?
        let domBefore = engine.daily.dom
        engine.beginDayGesture()
        for i in 0 ... 12 {
            engine.setDayProgress((CGFloat(engine.daily.dom) - 1 + CGFloat(i) / 12) * dayW)
            engine.wake()
            try? await pause(0.008)
        }
        _ = engine.endDayGesture()
        for _ in 0 ..< 40 {
            engine.wake(); try? await pause(Self.frameStep)
        }
        snap("after-right-swipe domBefore=\(domBefore)")
        benchActive = false
        try? log.joined(separator: "\n").appending("\n")
            .write(toFile: "/tmp/cc-day-boundary.txt", atomically: true, encoding: .utf8)
        writeBenchResults()
    }

    /// The user's full round trip: year → day (Aug 1) descent, day-swipe right to Aug 15
    /// through the REAL gesture path, then day → year zoom-out — dashboard pinned throughout.
    func sceneBenchDayRoundtrip() async {
        guard let engine else { return }
        try? await pause(1.4)
        engine.demoGoToYear(centerMonth: 7) // August centered
        if !engine.dashPinned {
            engine.pinDashboard()
        }
        try? await pause(0.9)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        // Descent: year → Aug 1.
        moveStart = Date.timeIntervalSinceReferenceDate
        engine.jumpToDay(engine.year, 7, 1)
        for _ in 0 ..< 100 {
            engine.wake(); try? await pause(Self.frameStep)
        }
        benchMoves.append((moveStart, moveStart + 1.5))
        // Day swipes: Aug 1 → Aug 15, adjacent gestures.
        for d in 1 ..< 15 {
            let dayW = max(1, engine.daily.frac * (size.width - Layout.labelW))
            engine.beginDayGesture()
            moveStart = Date.timeIntervalSinceReferenceDate
            for i in 0 ... 12 {
                let t = easeOutQuad(CGFloat(i) / 12)
                engine.setDayProgress((CGFloat(d) - 1 + t) * dayW)
                engine.wake()
                try? await pause(0.008)
            }
            benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
            _ = engine.endDayGesture()
            try? await pause(0.06)
        }
        // Zoom out: day → year.
        moveStart = Date.timeIntervalSinceReferenceDate
        engine.setView(zoom: "year")
        for _ in 0 ..< 90 {
            engine.wake(); try? await pause(Self.frameStep)
        }
        benchMoves.append((moveStart, moveStart + 1.4))
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// The FULL year→today descent ("zoom all the way down to today's daily view"): from the
    /// year grid, one jumpToDay to today's date — the multi-level fly-to the double-click path
    /// drives — with the dashboard panels mounting mid-flight. CC_BENCH_DASH=1 pins first.
    func sceneBenchDayZoomIn() async {
        guard let engine else { return }
        try? await pause(1.4)
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        let month = (c.month ?? 7) - 1
        engine.demoGoToYear(centerMonth: month)
        if ProcessInfo.processInfo.environment["CC_BENCH_DASH"] != nil, !engine.dashPinned {
            engine.pinDashboard()
        }
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        moveStart = Date.timeIntervalSinceReferenceDate
        engine.jumpToDay(engine.year, month, c.day ?? 15)
        for _ in 0 ..< 110 {
            engine.wake(); try? await pause(Self.frameStep)
        } // the whole descent
        benchMoves.append((moveStart, moveStart + 1.6))
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Continuous pinch-zoom benchmark: year → day → year (z 0→3→0) driven through the REAL magnify
    /// path (`demoMagnify` → onMagnify), ×3 cycles. Crosses every zoom seam — including z=1.5, where
    /// the sticker Canvas fast path hands plain stickers back to SwiftUI views (month→week) — so a
    /// promotion hitch there shows up as a mid-gesture stall. Pinch is anchored mid-window over July.
    func sceneBenchPinchZoom() async {
        guard let engine else { return }
        try? await pause(1.2)
        engine.demoGoToYear(centerMonth: 6) // July centered — the dense month under the pinch anchor
        try? await pause(0.8)
        await benchDashSetup() // CC_BENCH_DASH: cross every zoom seam with the panel out
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        let pt = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        // A full single-level pinch accumulates ≈0.7 of magnification (see demoMagnify); three levels
        // over `steps` frames ≈ a brisk ~1s continuous gesture at 120Hz.
        let steps = 90
        for _ in 0 ..< 3 {
            for zoomIn in [true, false] {
                engine.demoMagnify(delta: 0, atView: pt, began: true, ended: false)
                moveStart = Date.timeIntervalSinceReferenceDate
                for _ in 1 ... steps {
                    let d: CGFloat = (zoomIn ? 1 : -1) * (0.7 * 3 / CGFloat(steps))
                    engine.demoMagnify(delta: d, atView: pt, began: false, ended: false)
                    engine.wake()
                    try? await pause(0.008)
                }
                benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
                engine.demoMagnify(delta: 0, atView: pt, began: false, ended: true)
                try? await pause(0.35) // let the level-snap settle before reversing
            }
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Times the pure notification-planning pass over the loaded store (the main-thread stall a
    /// post-edit resync costs) → $CC_DEMO_DATADIR/notify-bench.json.
    func sceneBenchNotifyPlan() async {
        guard let engine else { return }
        try? await pause(1.5) // store load settle
        let ms = engine.benchNotifyPlan(reps: 20)
        let sorted = ms.sorted()
        let out: [String: Any] = [
            "reps": ms.count,
            "plan_ms_min": (sorted.first! * 100).rounded() / 100,
            "plan_ms_p50": (sorted[sorted.count / 2] * 100).rounded() / 100,
            "plan_ms_max": (sorted.last! * 100).rounded() / 100,
        ]
        if let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("notify-bench.json"))
        }
    }

    /// Frame-time stats over the recorded ticks → $CC_DEMO_DATADIR/bench.json. The stats math
    /// lives in CalendarRender/BenchStats (shared with the iPhone bench runner; golden-tested).
    private func writeBenchResults() {
        CCTrace.dumpNow("bench-scene-end")
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty,
              var out = BenchStats.results(frames: benchFrames, moves: benchMoves) else { return }
        // Per-layer CPU attribution (CC_PROF=1): each draw layer's [samples, avg-ms, total-ms, peak-ms].
        // NB: main-thread CPU only — glass GPU compositing is invisible here (see RenderProfiler).
        let layers = RenderProf.summary()
        if !layers.isEmpty {
            out["layers_ms"] = layers
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("bench.json"))
        }
    }
}
