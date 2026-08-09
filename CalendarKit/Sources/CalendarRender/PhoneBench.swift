// iPhone bench runtime: the phone-shaped counterpart of the Mac's DemoController+Bench.
// Scenes are NOT ports of the Mac scenes — they drive the exact engine mirror calls the
// phone's ScrollView drivers make (PhonePagers.swift), so a scripted run pays the same
// scene-rebuild costs a finger does. Lives in the SPM package (not the app target) so
// `swift build` + `swift test` on the macOS host compile and exercise it; the Mac app
// never instantiates it.
//
// Results go three ways at scene end: pretty JSON + a results.log-format line to the
// console (copy the line into bench/results-ios.log), and bench.json + results.log under
// <Documents>/bench/ (visible in the Files app — Info.plist enables file sharing).

import CalendarEngine
import CalendarGeometry
import Foundation
import SwiftUI

@MainActor
public final class PhoneBenchRunner {
    /// Live FPS HUD toggle: env var CC_FPS_HUD=1 (bench scheme) or the Developer toggle in the
    /// phone menu (same UserDefaults key as the Mac's Settings ▸ Developer switch).
    private static let envHUD = ProcessInfo.processInfo.environment["CC_FPS_HUD"] != nil
    public static var hudEnabled: Bool {
        envHUD || UserDefaults.standard.bool(forKey: "cc.fpsHUD")
    }

    /// One frame's budget in ms — the app sets 1000 / maximumFramesPerSecond at launch, so the
    /// HUD tints and the frames_over_budget stat are display-rate-aware (60 Hz non-Pro vs 120 Hz).
    public var budgetMs: Double = 1000.0 / 60.0

    weak var engine: CalendarEngine? // internal: set by startIfDemo (tests inject directly)
    var size: CGSize = .zero
    var benchActive = false
    var benchFrames: [Double] = []
    var benchMoves: [(Double, Double)] = []
    var hudRing: [Double] = []
    private var moveStart: Double = 0
    /// Where bench.json/results.log land; tests point this at a temp dir (default: app Documents).
    var outputDir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("bench", isDirectory: true)
    /// Test hooks: shrink step counts and skip real sleeps so a scene runs headless in ~ms.
    var stepsOverride: Int?
    var pauseScale: Double = 1

    public init() {}

    /// Per-frame hook from the render TimelineView (one evaluation = one rendered frame). A cheap
    /// no-op unless a scene is recording or the HUD is on; same-date re-evaluations dedupe.
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

    /// Sleep-aware stats over the last second (see BenchStats.hudStats) — feeds FPSHUDView.
    public func hudStats() -> (fps: Double, p95ms: Double, maxms: Double)? {
        BenchStats.hudStats(ring: hudRing) { [weak engine] a, b in engine?.sleepOverlap(a, b) ?? 0 }
    }

    /// Kick off the CC_DEMO scene, if any. Call from the calendar view's onAppear, after the
    /// viewport is set and the initial navigation has run. `bench-idle`/`idle` = manual mode
    /// (fixture + HUD, human drives).
    public func startIfDemo(engine: CalendarEngine, size: CGSize) {
        self.engine = engine
        self.size = size
        let scene = CalendarEngine.demoScene
        guard !scene.isEmpty, scene != "idle", scene != "bench-idle" else { return }
        Task { @MainActor in
            await self.run(scene)
        }
    }

    func run(_ scene: String) async {
        switch scene {
        case "bench-year-scroll": await sceneYearScroll()
        case "bench-quarter-scroll": await sceneQuarterScroll()
        case "bench-month-swipe": await sceneMonthSwipe()
        case "bench-month-hscroll": await sceneMonthHScroll()
        case "bench-week-swipe": await sceneWeekSwipe()
        case "bench-day-swipe": await sceneDaySwipe()
        case "bench-pinch-zoom": await scenePinchZoom()
        default: print("PhoneBench: unknown scene \(scene)")
        }
    }

    // ── Scenes ─────────────────────────────────────────────────────────────────────────────
    // Shared shape (mirrors the Mac scenes): settle → position → record → mirror-driven legs
    // with wake() + ~0.008s pacing (iPhone touch sampling is 120 Hz even on 60 Hz panels, so
    // two mirror updates per frame is representative) → write results. Gesture legs land in
    // benchMoves so the moving_* stats isolate what the eye sees.

    /// Vertical year fling: setYearScroll sweep 0→max→0 — same mirror PhoneYearDriver feeds.
    /// No begin/endYearScrollGesture: the phone drivers never arm them (year flips are off).
    func sceneYearScroll() async {
        guard let engine else { return }
        await settle(1.2)
        engine.demoGoToYear(centerMonth: 0)
        await settle(0.8)
        begin()
        let maxY = max(0, yearMaxScroll(engine.viewport))
        let steps = max(2, stepsOverride ?? envInt("CC_BENCH_FLING_STEPS") ?? 120)
        for (from, to) in [(CGFloat(0), maxY), (maxY, CGFloat(0))] {
            moveStart = Date().timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = CGFloat(i) / CGFloat(steps)
                engine.setYearScroll(from + (to - from) * t)
                engine.wake()
                await step()
            }
            benchMoves.append((moveStart, Date().timeIntervalSinceReferenceDate))
            await settle(0.25)
        }
        finish("bench-year-scroll")
    }

    /// Horizontal quarter-strip sweep — the phone's PRIMARY year interaction (no Mac
    /// equivalent). Leg 1: the focus quarter alone, 0→max→0 (a finger on one strip).
    /// Leg 2: all four quarters swept together (whole-grid invalidation, the worst case).
    func sceneQuarterScroll() async {
        guard let engine else { return }
        await settle(1.2)
        engine.demoGoToYear(centerMonth: 6) // July's quarter under the finger, like the Mac's dense-month anchor
        await settle(0.8)
        begin()
        let maxX = max(0, yearQuarterMaxX(engine.viewport))
        let steps = max(2, stepsOverride ?? envInt("CC_BENCH_FLING_STEPS") ?? 120)
        let q0 = engine.chrome.focus / 3
        for leg in 0 ..< 2 {
            for (from, to) in [(CGFloat(0), maxX), (maxX, CGFloat(0))] {
                moveStart = Date().timeIntervalSinceReferenceDate
                for i in 0 ... steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let x = from + (to - from) * t
                    if leg == 0 {
                        engine.setYearQuarterScroll(q0, x)
                    } else {
                        for q in 0 ..< 4 {
                            engine.setYearQuarterScroll(q, x)
                        }
                    }
                    engine.wake()
                    await step()
                }
                benchMoves.append((moveStart, Date().timeIntervalSinceReferenceDate))
                await settle(0.25)
            }
        }
        finish("bench-quarter-scroll")
    }

    /// Vertical month page turns through the real pager mirror — the Mac scene's Jun→Sep tour
    /// with revisits, honoring CC_BENCH_MONTHS/CC_BENCH_SWIPE_STEPS/CC_BENCH_SWIPE_GAP.
    func sceneMonthSwipe() async {
        guard let engine else { return }
        await settle(1.2)
        engine.setView(zoom: "month", focusedMonth: 5) // June
        await settle(0.8)
        begin()
        let pageH = size.height
        let steps = max(2, stepsOverride ?? envInt("CC_BENCH_SWIPE_STEPS") ?? 40)
        let gap = envDouble("CC_BENCH_SWIPE_GAP") ?? 0.15
        var pairs: [(Int, Int)] = [(5, 6), (6, 7), (7, 8), (8, 7), (7, 6), (6, 7), (7, 8), (8, 7), (7, 6)]
        if let spec = ProcessInfo.processInfo.environment["CC_BENCH_MONTHS"] {
            let mm = spec.split(separator: ",").compactMap { Int($0) }
            if mm.count >= 2 {
                let fwd = zip(mm, mm.dropFirst()).map { ($0, $1) }
                let leg = fwd + fwd.reversed().map { ($0.1, $0.0) }
                pairs = leg + leg + leg
            }
        }
        for (from, to) in pairs {
            engine.beginMonthGesture()
            moveStart = Date().timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = easeOutQuad(CGFloat(i) / CGFloat(steps))
                engine.setMonthProgress((CGFloat(from) + CGFloat(to - from) * t) * pageH, pageH: pageH)
                engine.wake()
                await step()
            }
            benchMoves.append((moveStart, Date().timeIntervalSinceReferenceDate))
            engine.endMonthGesture()
            await settle(gap)
        }
        finish("bench-month-swipe")
    }

    /// Horizontal day-column scroll inside the focused month (MonthHStrip's mirror; no Mac
    /// equivalent — desktop months always fit their width).
    func sceneMonthHScroll() async {
        guard let engine else { return }
        await settle(1.2)
        engine.setView(zoom: "month", focusedMonth: 5) // June
        await settle(0.8)
        begin()
        let maxX = max(0, yearQuarterMaxX(engine.viewport)) // 31·yearDayW − grid width, same overflow math
        let steps = max(2, stepsOverride ?? envInt("CC_BENCH_FLING_STEPS") ?? 120)
        for (from, to) in [(CGFloat(0), maxX), (maxX, CGFloat(0))] {
            moveStart = Date().timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = CGFloat(i) / CGFloat(steps)
                engine.setMonthHScroll(from + (to - from) * t)
                engine.wake()
                await step()
            }
            benchMoves.append((moveStart, Date().timeIntervalSinceReferenceDate))
            await settle(0.25)
        }
        finish("bench-month-hscroll")
    }

    /// Week-window turns + a vertical timeline leg — the phone week view's two axes.
    /// Same knobs/defaults as the Mac scene (CC_BENCH_WEEK_MONTH default 0, CC_BENCH_WEEKS "2,3").
    func sceneWeekSwipe() async {
        guard let engine else { return }
        await settle(1.2)
        let env = ProcessInfo.processInfo.environment
        let month = max(0, min(11, env["CC_BENCH_WEEK_MONTH"].flatMap { Int($0) } ?? 0))
        var weeks = env["CC_BENCH_WEEKS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [2, 3]
        if weeks.count < 2 {
            weeks = [2, 3]
        }
        engine.demoGoToWeek(month: month, week: CGFloat(weeks[0]))
        await settle(0.8)
        begin()
        // The phone driver's cell width: the grid split into Layout.weekDaysVisible columns
        // (3 on the phone); engine x-space is weekIndex · 7 · dayW (PhoneWeekDriver's mirror).
        let dayW = max(1, (engine.viewport.w - Layout.labelW) / Layout.weekDaysVisible)
        let steps = max(2, stepsOverride ?? envInt("CC_BENCH_SWIPE_STEPS") ?? 40)
        let gap = envDouble("CC_BENCH_SWIPE_GAP") ?? 0.15
        let fwd = zip(weeks, weeks.dropFirst()).map { ($0, $1) }
        let leg = fwd + fwd.reversed().map { ($0.1, $0.0) }
        for (from, to) in leg + leg + leg {
            engine.beginWeekGesture()
            moveStart = Date().timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = easeOutQuad(CGFloat(i) / CGFloat(steps))
                engine.setWeekProgress((CGFloat(from) + CGFloat(to - from) * t) * 7 * dayW, dayW: dayW)
                engine.wake()
                await step()
            }
            benchMoves.append((moveStart, Date().timeIntervalSinceReferenceDate))
            _ = engine.endWeekGesture()
            await settle(gap)
        }
        // Second leg: the hour timeline (the week view's other finger axis).
        let maxY = max(0, engine.timelineMaxScroll(atZ: 2))
        for (from, to) in [(CGFloat(0), maxY), (maxY, CGFloat(0))] {
            moveStart = Date().timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = CGFloat(i) / CGFloat(steps)
                engine.setTlScroll(from + (to - from) * t)
                engine.wake()
                await step()
            }
            benchMoves.append((moveStart, Date().timeIntervalSinceReferenceDate))
            await settle(0.25)
        }
        finish("bench-week-swipe")
    }

    /// Day page turns through PhoneDayDriver's mirror (x = (dom−1)·dayW, native paging feel).
    func sceneDaySwipe() async {
        guard let engine else { return }
        await settle(1.2)
        engine.jumpToDay(engine.year, 5, 15) // June 15
        await settle(0.8)
        begin()
        let dayW = max(1, engine.daily.frac * (engine.viewport.w - Layout.labelW))
        let steps = max(2, stepsOverride ?? envInt("CC_BENCH_SWIPE_STEPS") ?? 40)
        let gap = envDouble("CC_BENCH_SWIPE_GAP") ?? 0.15
        let tour = [(15, 16), (16, 17), (17, 16), (16, 15), (15, 16), (16, 17), (17, 16), (16, 15)]
        for (from, to) in tour {
            engine.beginDayGesture()
            moveStart = Date().timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = easeOutQuad(CGFloat(i) / CGFloat(steps))
                engine.setDayProgress((CGFloat(from - 1) + CGFloat(to - from) * t) * dayW)
                engine.wake()
                await step()
            }
            benchMoves.append((moveStart, Date().timeIntervalSinceReferenceDate))
            _ = engine.endDayGesture()
            await settle(gap)
        }
        finish("bench-day-swipe")
    }

    /// Continuous pinch year→day→year (z 0→3→0) ×3 through the real magnify path — crosses
    /// every zoom seam, including the sticker Canvas↔view handoffs. Mirrors the Mac scene.
    func scenePinchZoom() async {
        guard let engine else { return }
        await settle(1.2)
        engine.demoGoToYear(centerMonth: 6) // July centered — the dense month under the pinch anchor
        await settle(0.8)
        begin()
        let pt = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let steps = stepsOverride ?? 90
        for _ in 0 ..< 3 {
            for zoomIn in [true, false] {
                engine.demoMagnify(delta: 0, atView: pt, began: true, ended: false)
                moveStart = Date().timeIntervalSinceReferenceDate
                for _ in 1 ... steps {
                    let d: CGFloat = (zoomIn ? 1 : -1) * (0.7 * 3 / CGFloat(steps))
                    engine.demoMagnify(delta: d, atView: pt, began: false, ended: false)
                    engine.wake()
                    await step()
                }
                benchMoves.append((moveStart, Date().timeIntervalSinceReferenceDate))
                engine.demoMagnify(delta: 0, atView: pt, began: false, ended: true)
                await settle(0.35)
            }
        }
        finish("bench-pinch-zoom")
    }

    // ── Plumbing ───────────────────────────────────────────────────────────────────────────

    private func begin() {
        benchFrames.removeAll()
        benchMoves.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
    }

    private func finish(_ scene: String) {
        RenderProf.mark("benchEnd")
        benchActive = false
        writeResults(scene)
    }

    /// Stats + console + files. Returns the dict for tests. Adds two phone-only keys on top of
    /// the Mac-identical BenchStats payload: budget_ms and frames_over_budget (device-relative —
    /// hitches_over_33ms is kept as-is for cross-log comparability).
    @discardableResult
    func writeResults(_ scene: String) -> [String: Any]? {
        guard var out = BenchStats.results(frames: benchFrames, moves: benchMoves) else {
            print("PhoneBench: \(scene) produced too few frames for stats")
            return nil
        }
        let deltas = zip(benchFrames.dropFirst(), benchFrames).map { $0 - $1 }.filter { $0 > 0 }
        out["budget_ms"] = (budgetMs * 100).rounded() / 100
        out["frames_over_budget"] = deltas.filter { $0 > budgetMs / 1000 + 0.0005 }.count
        let layers = RenderProf.summary()
        if !layers.isEmpty {
            out["layers_ms"] = layers
        }
        let line = BenchStats.resultsLogLine(results: out, tag: logTag(scene))
        print("\n== bench ==\n\(line)")
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
            try? data.write(to: outputDir.appendingPathComponent("bench.json"))
        }
        let logURL = outputDir.appendingPathComponent("results.log")
        let entry = line + "\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: logURL)
        }
        return out
    }

    /// `[TAG|scene/config/payload/WxH@hz/device=…/os=…]` — the phone twin of bench-year.sh's
    /// branch tag. The device can't know git state, so CC_BENCH_TAG carries the branch name.
    private func logTag(_ scene: String) -> String {
        let env = ProcessInfo.processInfo.environment
        let tag = env["CC_BENCH_TAG"] ?? "ios"
        let payload = env["CC_BENCH_PAYLOAD"] ?? "display"
        #if DEBUG
            let config = "debug"
        #else
            let config = "release"
        #endif
        let hz = Int((1000.0 / max(1, budgetMs)).rounded())
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(tag)|\(scene)/\(config)/\(payload)/\(Int(size.width))x\(Int(size.height))@\(hz)"
            + "/device=\(machine)/os=\(v.majorVersion).\(v.minorVersion)"
    }

    private func settle(_ s: Double) async {
        try? await Task.sleep(for: .seconds(s * pauseScale))
    }

    private func step() async {
        if pauseScale > 0 {
            try? await Task.sleep(for: .seconds(0.008 * pauseScale))
        } else {
            await Task.yield() // headless tests: keep the loop cooperative without wall time
        }
    }

    private func envInt(_ key: String) -> Int? {
        ProcessInfo.processInfo.environment[key].flatMap { Int($0) }
    }

    private func envDouble(_ key: String) -> Double? {
        ProcessInfo.processInfo.environment[key].flatMap { Double($0) }
    }

    private func easeOutQuad(_ t: CGFloat) -> CGFloat {
        1 - (1 - t) * (1 - t)
    }
}
