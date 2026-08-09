@testable import CalendarEngine
import CalendarGeometry
import XCTest

/// Promoted ghost bands: ⌘↑/↓ (nudgeVertical) re-homes the promotion LANE on the source event —
/// never the source's time. (The pointer drag routes to the same setPromoteTrack.)
@MainActor
final class PromotedLaneTests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("CC_DEMO_DATADIR", NSTemporaryDirectory() + "cc-promoted-tests-" + UUID().uuidString, 1)
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    func testNudgeVerticalOnGhostMovesLaneNotTime() {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: e.year, month: 5, day: 10, startHour: 9, endHour: 10,
                                    title: "Talk", color: "blue")
        e.setPromoteTrack(id, 2)
        guard let ghost = e.displayBands(for: e.year).first(where: { sourceId(of: $0.id) == id }) else {
            return XCTFail("promoted ghost band not found")
        }
        XCTAssertTrue(ghost.id.hasSuffix(PROMOTED_SUFFIX))
        XCTAssertEqual(ghost.track, 2)

        e.selectedId = ghost.id // select the GHOST box (as a click on it would)
        e.nudgeVertical(-1) // ⌘↑
        XCTAssertEqual(e.richPromoteTrackForTest(id), 1, "lane moves up")
        let ev = e.displayEvents(for: e.year).first { $0.id == id }
        XCTAssertEqual(ev?.startHour, 9, "source event's TIME is untouched")

        e.nudgeVertical(-1); e.nudgeVertical(-1) // 1 → 0, then clamped
        XCTAssertEqual(e.richPromoteTrackForTest(id), 0, "clamped at lane 0")

        // The re-homed ghost renders on the new lane, same date.
        let moved = e.displayBands(for: e.year).first { sourceId(of: $0.id) == id }
        XCTAssertEqual(moved?.track, 0)
        XCTAssertEqual(moved?.startDay, 10)
    }

    /// The promoted ghost sits on the LOCAL (main-tz) day of the source's moment: 23:59 AOE (UTC−12)
    /// on Jun 20 is 07:59 ET on Jun 21 — the band must show on the 21st, not the anchor-zone day.
    func testPromotedDeadlineLandsOnLocalDay() throws {
        let e = CalendarEngine()
        e.mainTz = "America/New_York"
        let id = e.createDeadline(year: 2026, month: 5, day: 20, hour: 23.983, title: "CFP",
                                  color: "red", anchorTz: "AOE")
        e.setPromoteTrack(id, 1)
        let ghost = try XCTUnwrap(e.displayBands(for: 2026).first { sourceId(of: $0.id) == id })
        XCTAssertEqual(ghost.month, 5)
        XCTAssertEqual(ghost.startDay, 21, "23:59 AOE Jun 20 = 07:59 ET Jun 21 — the local day")
        XCTAssertEqual(ghost.endDay, 21)
        // The stored deadline keeps its anchor-zone identity (only the display day localizes).
        XCTAssertEqual(e.items.deadlines.first { $0.id == id }?.day, 20)
    }

    func testNudgeVerticalOnSourceEventStillMovesTime() {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: e.year, month: 5, day: 10, startHour: 9, endHour: 10,
                                    title: "Talk", color: "blue")
        e.setPromoteTrack(id, 2)
        e.selectedId = id // select the TIMED event itself, not the ghost
        e.nudgeVertical(1)
        XCTAssertEqual(e.displayEvents(for: e.year).first { $0.id == id }?.startHour, 9.25,
                       "selecting the source still nudges time as before")
        XCTAssertEqual(e.richPromoteTrackForTest(id), 2, "lane unchanged")
    }
}

private extension CalendarEngine {
    func richPromoteTrackForTest(_ id: String) -> Int? {
        items.richById[id]?.promoteTrack
    }
}
