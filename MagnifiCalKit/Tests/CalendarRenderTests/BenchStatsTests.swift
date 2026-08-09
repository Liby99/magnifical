import CalendarRender
import XCTest

/// Golden tests pinning BenchStats to the exact numbers the pre-extraction inline code in
/// DemoController+Bench.swift produced. If one of these fails after touching BenchStats, the
/// Mac's bench.json output (and results.log comparability) has drifted — that's a regression,
/// not a test to update.
final class BenchStatsTests: XCTestCase {
    // ── results(frames:moves:) ─────────────────────────────────────────────────────────────

    func testUniformFramesBasics() throws {
        // 6 frames at a perfect 10ms cadence: 5 deltas, 0.05s span, 100 fps.
        let frames = [0.0, 0.01, 0.02, 0.03, 0.04, 0.05]
        let r = try XCTUnwrap(BenchStats.results(frames: frames, moves: []))
        XCTAssertEqual(r["frames"] as? Int, 6)
        XCTAssertEqual(r["seconds"] as? Double, 0.05)
        XCTAssertEqual(r["avg_fps"] as? Double, 100.0)
        XCTAssertEqual(r["frame_ms_p50"] as? Double, 10.0)
        XCTAssertEqual(r["frame_ms_p95"] as? Double, 10.0)
        XCTAssertEqual(r["frame_ms_max"] as? Double, 10.0)
        XCTAssertEqual(r["hitches_over_33ms"] as? Int, 0)
        // Run is far shorter than the 0.5s window floor → hudMinFps falls back to avg.
        XCTAssertEqual(r["hud_min_fps"] as? Double, 100.0)
        // No gesture windows → no moving_* keys.
        XCTAssertNil(r["moving_avg_fps"])
        XCTAssertNil(r["hitch_offsets_s"])
    }

    func testHitchAndMovingWindowStats() throws {
        // Deltas .02 .02 .05 .02 .02 — one 50ms hitch at t2=0.09, all inside one gesture window.
        let frames = [0.0, 0.02, 0.04, 0.09, 0.11, 0.13]
        let r = try XCTUnwrap(BenchStats.results(frames: frames, moves: [(0.0, 0.13)]))
        XCTAssertEqual(r["hitches_over_33ms"] as? Int, 1)
        XCTAssertEqual(r["frame_ms_p50"] as? Double, 20.0)
        XCTAssertEqual(r["frame_ms_p95"] as? Double, 50.0)
        XCTAssertEqual(r["frame_ms_max"] as? Double, 50.0)
        XCTAssertEqual(r["avg_fps"] as? Double, 38.46) // 5 / 0.13
        XCTAssertEqual(r["moving_avg_fps"] as? Double, 38.46)
        XCTAssertEqual(r["moving_p95_ms"] as? Double, 50.0)
        XCTAssertEqual(r["moving_max_ms"] as? Double, 50.0)
        XCTAssertEqual(r["moving_hitches"] as? Int, 1)
        // The hitch frame lands 0.09s into its window, rounded to the ms.
        XCTAssertEqual(r["hitch_offsets_s"] as? [Double], [0.09])
    }

    func testHudMinFpsCatchesWorstSecond() throws {
        // 2.0s run at 100fps with a 10-frame 50ms-cadence cluster in the middle: the worst
        // trailing-1s window reads far below the average.
        var frames: [Double] = []
        var t = 0.0
        for _ in 0 ..< 100 {
            frames.append(t); t += 0.01
        }
        for _ in 0 ..< 10 {
            frames.append(t); t += 0.05
        }
        for _ in 0 ..< 100 {
            frames.append(t); t += 0.01
        }
        let r = try XCTUnwrap(BenchStats.results(frames: frames, moves: []))
        let avg = try XCTUnwrap(r["avg_fps"] as? Double)
        let worst = try XCTUnwrap(r["hud_min_fps"] as? Double)
        XCTAssertGreaterThan(avg, 80)
        XCTAssertLessThan(worst, avg - 10) // the cluster must show up
        XCTAssertEqual(r["hitches_over_33ms"] as? Int, 10)
    }

    func testTooFewFramesReturnsNil() {
        XCTAssertNil(BenchStats.results(frames: [], moves: []))
        XCTAssertNil(BenchStats.results(frames: [0.0, 0.01], moves: []))
        // Non-increasing timestamps → no positive deltas → nil.
        XCTAssertNil(BenchStats.results(frames: [1.0, 1.0, 1.0], moves: []))
    }

    // ── hudStats(ring:now:sleepOverlap:) ───────────────────────────────────────────────────

    func testHudStatsBasic() throws {
        // 10 frames over the last 0.9s at 0.1 spacing, no sleeps: 10 fps, all deltas 100ms.
        let ring = (0 ..< 10).map { 99.1 + Double($0) * 0.1 }
        let s = try XCTUnwrap(BenchStats.hudStats(ring: ring, now: 100.0) { _, _ in 0 })
        XCTAssertEqual(s.fps, 10.0, accuracy: 0.001)
        XCTAssertEqual(s.p95ms, 100.0, accuracy: 0.001)
        XCTAssertEqual(s.maxms, 100.0, accuracy: 0.001)
    }

    func testHudStatsSubtractsSleeps() throws {
        // Half of every interval was legitimate render-clock sleep → the ANIMATED rate doubles.
        let ring = (0 ..< 10).map { 99.1 + Double($0) * 0.1 }
        let s = try XCTUnwrap(BenchStats.hudStats(ring: ring, now: 100.0) { a, b in (b - a) * 0.5 })
        XCTAssertEqual(s.fps, 20.0, accuracy: 0.001)
        XCTAssertEqual(s.p95ms, 50.0, accuracy: 0.001)
    }

    func testHudStatsNilWhenIdle() {
        // Fewer than 5 frames in the last second → nil (matches the HUD's "idle" state).
        let ring = [99.2, 99.5, 99.8, 100.0]
        XCTAssertNil(BenchStats.hudStats(ring: ring, now: 100.0) { _, _ in 0 })
        // Frames exist but are all older than 1s → nil.
        let stale = (0 ..< 10).map { 90.0 + Double($0) * 0.01 }
        XCTAssertNil(BenchStats.hudStats(ring: stale, now: 100.0) { _, _ in 0 })
    }

    // ── resultsLogLine ─────────────────────────────────────────────────────────────────────

    func testResultsLogLineMatchesScriptFormat() {
        // Snapshot of bench-year.sh's Python f-string output for the same inputs.
        let r: [String: Any] = [
            "avg_fps": 83.0, "hud_min_fps": 41.2, "frame_ms_p50": 8.33, "frame_ms_p95": 41.67,
            "frame_ms_max": 66.7, "hitches_over_33ms": 18, "frames": 500, "seconds": 6.02,
            "moving_avg_fps": 80.1, "moving_p95_ms": 41.7, "moving_hitches": 18,
        ]
        let line = BenchStats.resultsLogLine(
            results: r, tag: "main|bench-month-swipe/release/dump", timestamp: "2026-08-03 12:00"
        )
        XCTAssertEqual(line, "2026-08-03 12:00 [main|bench-month-swipe/release/dump] "
            + "avg 83.0 fps | HUD-min 41.2 fps | p50 8.33 ms | p95 41.67 ms | max 66.7 ms | "
            + "hitches(>33ms) 18 | MOVING: 80.1 fps p95 41.7 ms hitches 18 | 500 frames / 6.02 s")
    }

    func testResultsLogLineWithoutMovingBlock() {
        let r: [String: Any] = [
            "avg_fps": 116.3, "hud_min_fps": 110.0, "frame_ms_p50": 8.33, "frame_ms_p95": 8.33,
            "frame_ms_max": 12.5, "hitches_over_33ms": 0, "frames": 700, "seconds": 6.0,
        ]
        let line = BenchStats.resultsLogLine(results: r, tag: "t", timestamp: "2026-08-03 12:00")
        XCTAssertEqual(line, "2026-08-03 12:00 [t] avg 116.3 fps | HUD-min 110.0 fps | "
            + "p50 8.33 ms | p95 8.33 ms | max 12.5 ms | hitches(>33ms) 0 | 700 frames / 6.00 s")
    }

    func testRoundTripThroughResults() throws {
        // results() output feeds resultsLogLine without any type coercion surprises
        // (Int vs Double keys) — the exact path the phone runner uses.
        let frames = [0.0, 0.02, 0.04, 0.09, 0.11, 0.13]
        let r = try XCTUnwrap(BenchStats.results(frames: frames, moves: [(0.0, 0.13)]))
        let line = BenchStats.resultsLogLine(results: r, tag: "x", timestamp: "t")
        XCTAssertTrue(line.contains("avg 38.5 fps"), line)
        XCTAssertTrue(line.contains("hitches(>33ms) 1"), line)
        XCTAssertTrue(line.contains("6 frames / 0.13 s"), line)
    }
}
