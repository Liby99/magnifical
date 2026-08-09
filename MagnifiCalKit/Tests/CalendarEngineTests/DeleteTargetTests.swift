@testable import CalendarEngine
import CalendarGeometry
import XCTest

/// The systematic delete classification (deleteTarget): provenance × recurrence-position ×
/// promoted-ghost, driving the delete dialog's action matrix.
@MainActor
final class DeleteTargetTests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("CC_DEMO_DATADIR", NSTemporaryDirectory() + "cc-deletetarget-" + UUID().uuidString, 1)
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    func testLocalRecurringBaseVsOccurrence() {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: 2026, month: 5, day: 10, startHour: 9, endHour: 10,
                                    title: "Standup", color: "blue")
        e.setRepeat(id, Repeat(kind: "weekly"))
        let base = e.deleteTarget(for: id)
        XCTAssertTrue(base.recurring)
        XCTAssertTrue(base.atBase, "the base box IS the series' first occurrence")
        XCTAssertFalse(base.viaGhost)
        let occ = e.deleteTarget(for: occKey(id, YMD(2026, 5, 17)))
        XCTAssertTrue(occ.recurring)
        XCTAssertFalse(occ.atBase, "a later occurrence is not the base")
    }

    func testPromotedGhostClassifies() {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: 2026, month: 5, day: 10, startHour: 9, endHour: 10,
                                    title: "Talk", color: "blue")
        e.setPromoteTrack(id, 1)
        guard let ghost = e.displayBands(for: 2026).first(where: { sourceId(of: $0.id) == id }) else {
            return XCTFail("promoted ghost band not found")
        }
        let t = e.deleteTarget(for: ghost.id)
        XCTAssertTrue(t.viaGhost)
        XCTAssertEqual(t.id, id)
        // …and Remove from Lane actually clears the promotion without touching the event.
        e.unpromote(ghost.id)
        XCTAssertNil(e.displayBands(for: 2026).first { sourceId(of: $0.id) == id })
        XCTAssertNotNil(e.displayEvents(for: 2026).first { $0.id == id })
    }

    func testChoicesMatrix() {
        // Pure PendingDelete matrix rows (UI module owns it, but the shape is locked here via
        // the DeleteTarget dimensions): base recurring drops This&Future.
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: 2026, month: 5, day: 10, startHour: 9, endHour: 10,
                                    title: "x", color: "blue")
        XCTAssertFalse(e.deleteTarget(for: id).recurring)
        e.setRepeat(id, Repeat(kind: "weekly"))
        XCTAssertTrue(e.deleteTarget(for: id).atBase)
    }
}
