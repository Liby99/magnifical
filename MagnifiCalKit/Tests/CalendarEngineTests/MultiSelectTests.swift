@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class MultiSelectTests: XCTestCase {
    override func setUp() {
        super.setUp(); redirectStoreToTemp()
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR"); super.tearDown()
    }

    private func timed(_ e: CalendarEngine, _ day: Int, _ start: CGFloat = 9) -> String {
        e.createTimedEvent(
            year: e.year,
            month: 6,
            day: day,
            startHour: start,
            endHour: start + 1,
            title: "x",
            color: "blue"
        )
    }

    /// Shift-click toggles into the set; single-select mirrors into it; deselect clears both.
    func testToggleSyncDeselect() {
        let e = CalendarEngine()
        let a = timed(e, 10)
        XCTAssertEqual(e.selectedIds, [a]) // create → single-select mirrored into the set
        let b = timed(e, 11)
        e.toggleInSelection(a) // now {a, b}
        XCTAssertEqual(e.selectedIds, [a, b]); XCTAssertTrue(e.multiSelectActive)
        e.toggleInSelection(a) // → {b}
        XCTAssertEqual(e.selectedIds, [b]); XCTAssertFalse(e.multiSelectActive)
        e.deselectAll()
        XCTAssertTrue(e.selectedIds.isEmpty); XCTAssertNil(e.selectedId)
    }

    /// Batch band day-move is all-or-nothing: if one band is at the month edge, nothing moves.
    func testBatchBandMoveAllOrNothing() {
        let e = CalendarEngine()
        let last = daysInMonth(e.year, 6)
        let a = e.createBand(year: e.year, month: 6, track: 0, startDay: 5, endDay: 6, title: "a", color: "blue")
        let b = e.createBand(
            year: e.year,
            month: 6,
            track: 1,
            startDay: last - 1,
            endDay: last,
            title: "b",
            color: "blue"
        )
        e.setSelection([a, b], primary: a)
        e.batchMove(dx: 1, dy: 0) // b can't move right → whole batch is a no-op
        XCTAssertEqual(e.band(a)?.startDay, 5)
        e.batchMove(dx: -1, dy: 0) // both can move left
        XCTAssertEqual(e.band(a)?.startDay, 4); XCTAssertEqual(e.band(b)?.startDay, last - 2)
    }

    /// Batch timed day-move must not cross the month boundary (all-or-nothing).
    func testBatchTimedNoMonthCross() {
        let e = CalendarEngine()
        let a = timed(e, 1), b = timed(e, 15)
        e.setSelection([a, b], primary: a)
        e.batchMove(dx: -1, dy: 0) // a at day 1 → would cross to prev month → no-op
        XCTAssertEqual(e.event(a)?.day, 1); XCTAssertEqual(e.event(b)?.day, 15)
    }

    /// Batch ⌘↑/↓ on timed events rolls across the day boundary (preserving duration).
    func testBatchTimedVertRollover() {
        let e = CalendarEngine()
        let t = e.createTimedEvent(
            year: e.year,
            month: 6,
            day: 20,
            startHour: 0,
            endHour: 0.75,
            title: "x",
            color: "blue"
        )
        e.setSelection([t], primary: t)
        e.batchMove(dx: 0, dy: -1) // -15min → rolls to the previous day at 23:45
        XCTAssertEqual(e.event(t)?.day, 19)
        XCTAssertEqual(Double(e.event(t)?.startHour ?? -1), 23.75, accuracy: 0.001)
    }

    /// Mixed-kind selection (a band + a timed) is a no-op for move.
    func testMixedSelectionMoveNoOp() {
        let e = CalendarEngine()
        let band = e.createBand(year: e.year, month: 6, track: 0, startDay: 5, endDay: 6, title: "a", color: "blue")
        let ev = timed(e, 10)
        e.setSelection([band, ev], primary: band)
        e.batchMove(dx: 1, dy: 0)
        XCTAssertEqual(e.band(band)?.startDay, 5); XCTAssertEqual(e.event(ev)?.day, 10)
    }

    /// Batch rename sets every selected title.
    func testBatchRename() {
        let e = CalendarEngine()
        let a = timed(e, 10), b = timed(e, 11)
        e.setSelection([a, b], primary: a)
        e.batchSetTitle("Standup")
        XCTAssertEqual(e.event(a)?.title, "Standup"); XCTAssertEqual(e.event(b)?.title, "Standup")
    }

    /// Batch delete summarizes mixed content and removes editable items in one undo step.
    func testBatchDeleteSummaryAndPerform() {
        let e = CalendarEngine()
        let a = timed(e, 10)
        let b = e.createBand(year: e.year, month: 6, track: 0, startDay: 5, endDay: 6, title: "b", color: "blue")
        e.setRepeat(a, Repeat(kind: "weekly"))
        e.setSelection([a, b], primary: a)
        let s = e.batchDeleteSummary()
        XCTAssertEqual(s.toDelete, 2); XCTAssertEqual(s.recurring, 1); XCTAssertEqual(s.toHide, 0)
        e.performBatchDelete()
        XCTAssertNil(e.event(a)); XCTAssertNil(e.band(b)); XCTAssertTrue(e.selectedIds.isEmpty)
        e.undo() // one undo step restores both
        XCTAssertNotNil(e.event(a)); XCTAssertNotNil(e.band(b))
    }
}
