@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class BandRecurrenceTests: XCTestCase {
    /// A recurring band whose shifted occurrence runs past a month end must render as TWO bars — one per
    /// month — not a single bar clamped at the boundary.
    func testRecurringBandSplitsAcrossMonthBoundary() {
        let e = CalendarEngine()
        let yr = e.year
        // Jan 3–6 (month 0), weekly → occurrences land Jan 10/17/24/31/… ; the Jan-31 one spans Jan 31–Feb 3.
        e.applyRemote(bands: [BandEvent(id: "seg-b", year: yr, month: 0, track: 1,
                                        startDay: 3, endDay: 6, title: "Trip", color: "blue")])
        e.setRepeat("seg-b", Repeat(kind: "weekly"))

        let bands = e.displayBands(for: yr).filter { sourceId(of: $0.id) == "seg-b" }
        let head = bands.first { $0.month == 0 && $0.startDay == 31 }
        let tail = bands.first { $0.month == 1 && $0.startDay == 1 }

        XCTAssertNotNil(head, "expected a January-31 head segment")
        XCTAssertNotNil(tail, "expected a February head-of-month tail segment")
        XCTAssertEqual(head?.endDay, 31)
        XCTAssertEqual(tail?.endDay, 3, "Jan31 + 4-day span → Feb 1–3")
        // Distinct box ids, but the same occurrence (so notes/delete resolve to one occurrence).
        if let h = head, let t = tail {
            XCTAssertNotEqual(h.id, t.id)
            XCTAssertEqual(occurrenceKey(of: h.id), occurrenceKey(of: t.id))
        }
    }

    /// An occurrence that stays inside its month is a single bar (no spurious segment).
    func testRecurringBandWithinMonthIsOneBar() {
        let e = CalendarEngine()
        let yr = e.year
        e.applyRemote(bands: [BandEvent(id: "one-b", year: yr, month: 0, track: 0,
                                        startDay: 3, endDay: 5, title: "X", color: "red")])
        e.setRepeat("one-b", Repeat(kind: "weekly"))
        // The Jan-10 occurrence (Jan 10–12) is wholly within January → exactly one bar, no "#seg".
        let jan10 = e.displayBands(for: yr)
            .filter { sourceId(of: $0.id) == "one-b" && $0.month == 0 && $0.startDay == 10 }
        XCTAssertEqual(jan10.count, 1)
        XCTAssertEqual(jan10.first?.endDay, 12)
        XCTAssertFalse(jan10.first?.id.contains(SEGMENT_MARKER) ?? true)
    }
}
