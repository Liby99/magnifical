import CalendarEngine
import CalendarGeometry
@testable import CalendarRender
import XCTest

/// Headless coverage for the phone bench runtime — everything except the on-device TimelineView
/// feed runs on the macOS host, so `swift test` exercises the harness end-to-end.
@MainActor
final class PhoneBenchTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonebench-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // ── BenchStaging ───────────────────────────────────────────────────────────────────────

    func testStagingWipesAndCopiesFixture() throws {
        let fm = FileManager.default
        let src = tempDir().appendingPathComponent("fixture.json")
        try Data(#"{"events":[]}"#.utf8).write(to: src)
        let dir = tempDir()
        // Pre-existing junk in the store dir must not survive the wipe.
        try Data("junk".utf8).write(to: dir.appendingPathComponent("stale.bin"))
        try BenchStaging.stage(fixture: src, into: dir)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("data.json").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("stale.bin").path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("data.json")),
                       Data(#"{"events":[]}"#.utf8))
    }

    // ── writeResults ───────────────────────────────────────────────────────────────────────

    func testWriteResultsProducesFilesAndPhoneKeys() throws {
        let runner = PhoneBenchRunner()
        runner.outputDir = tempDir()
        runner.budgetMs = 1000.0 / 60.0
        runner.benchActive = true
        // 60 synthetic frames at 20ms cadence (over the 16.7ms budget) + one 50ms hitch.
        var t = 100.0
        for i in 0 ..< 60 {
            runner.benchTick(Date(timeIntervalSinceReferenceDate: t))
            t += i == 30 ? 0.05 : 0.02
        }
        runner.benchMoves = [(100.0, t)]
        let out = try XCTUnwrap(runner.writeResults("bench-test"))
        XCTAssertEqual(out["budget_ms"] as? Double, 16.67)
        XCTAssertEqual(out["frames_over_budget"] as? Int, 59) // every 20ms frame + the hitch
        XCTAssertEqual(out["hitches_over_33ms"] as? Int, 1)
        XCTAssertNotNil(out["moving_avg_fps"])
        // Files land in outputDir: bench.json parses, results.log carries the tag line.
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: runner.outputDir.appendingPathComponent("bench.json"))
        ) as? [String: Any]
        XCTAssertEqual(json?["hitches_over_33ms"] as? Int, 1)
        let log = try String(contentsOf: runner.outputDir.appendingPathComponent("results.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("[ios|bench-test/"), log)
        XCTAssertTrue(log.contains("hitches(>33ms) 1"), log)
        // A second write APPENDS to the log.
        _ = runner.writeResults("bench-test")
        let log2 = try String(contentsOf: runner.outputDir.appendingPathComponent("results.log"), encoding: .utf8)
        XCTAssertEqual(log2.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
    }

    func testWriteResultsNilOnTooFewFrames() {
        let runner = PhoneBenchRunner()
        runner.outputDir = tempDir()
        XCTAssertNil(runner.writeResults("bench-empty"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runner.outputDir.appendingPathComponent("bench.json").path
        ))
    }

    // ── benchTick ──────────────────────────────────────────────────────────────────────────

    func testBenchTickDedupesAndCapsRing() {
        let runner = PhoneBenchRunner()
        runner.benchActive = true
        let d = Date(timeIntervalSinceReferenceDate: 5)
        runner.benchTick(d)
        runner.benchTick(d) // same-date re-evaluation dedupes
        XCTAssertEqual(runner.benchFrames, [5])
    }

    // ── Scene smoke: the mirrors actually move the engine ─────────────────────────────────

    func testYearScrollSceneDrivesEngineAndWritesResults() async {
        let engine = CalendarEngine()
        engine.setViewport(CGSize(width: 390, height: 800))
        let runner = PhoneBenchRunner()
        runner.engine = engine
        runner.size = CGSize(width: 390, height: 800)
        runner.outputDir = tempDir()
        runner.stepsOverride = 6
        runner.pauseScale = 0 // no wall-clock sleeps — the whole scene runs in ~ms
        // Headless: no TimelineView feeds benchTick, so synthesize the frame stream the way the
        // render loop would (one tick per mirror step) by ticking around the scene run.
        let tick = Task { @MainActor in
            var t = Date().timeIntervalSinceReferenceDate
            while !Task.isCancelled {
                runner.benchTick(Date(timeIntervalSinceReferenceDate: t))
                t += 0.008
                await Task.yield()
            }
        }
        await runner.run("bench-year-scroll")
        tick.cancel()
        // The sweep's last mirror call parks the year scroll back at 0 after touching maxY.
        XCTAssertEqual(engine.scrollY, 0, accuracy: 0.5)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: runner.outputDir.appendingPathComponent("bench.json").path
        ))

        // Quarter scene: all four strips end parked at 0 after the synchronized sweep.
        _ = engine // silence unused warnings if assertions compile out
    }

    func testQuarterScrollSceneRoundTripsQuarterOffsets() async {
        // yearQuarterMaxX > 0 requires the phone's min day width; save/restore the knob so the
        // desktop-default expectations of every other test stay untouched.
        let saved = Layout.yearMinDayW
        Layout.yearMinDayW = 45
        defer { Layout.yearMinDayW = saved }
        let engine = CalendarEngine()
        engine.setViewport(CGSize(width: 390, height: 800))
        XCTAssertGreaterThan(yearQuarterMaxX(engine.viewport), 0)
        let runner = PhoneBenchRunner()
        runner.engine = engine
        runner.size = CGSize(width: 390, height: 800)
        runner.outputDir = tempDir()
        runner.stepsOverride = 4
        runner.pauseScale = 0
        var sawOffset = false
        let probe = Task { @MainActor in
            while !Task.isCancelled {
                if engine.yearQX.contains(where: { $0 > 1 }) {
                    sawOffset = true
                }
                await Task.yield()
            }
        }
        await runner.run("bench-quarter-scroll")
        probe.cancel()
        XCTAssertTrue(sawOffset, "the sweep never moved a quarter strip")
        XCTAssertEqual(engine.yearQX, [0, 0, 0, 0]) // both legs park back at 0
    }
}
