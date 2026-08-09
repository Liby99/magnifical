@testable import CalendarGeometry
import CoreGraphics
import XCTest

final class SegmentTests: XCTestCase {
    private func ev(_ start: CGFloat, _ end: CGFloat) -> TimedEvent {
        TimedEvent(
            id: "e",
            year: 2026,
            month: 6,
            day: 22,
            startHour: start,
            endHour: end,
            title: "Flight",
            color: "blue",
            anchorTz: "America/New_York"
        )
    }

    /// A same-day event is one segment, unclipped.
    func testSameDaySingleSegment() {
        let s = timedSegments(ev(9, 11))
        XCTAssertEqual(s.count, 1)
        XCTAssertFalse(s[0].clipTop); XCTAssertFalse(s[0].clipBottom)
        XCTAssertEqual(s[0].event.day, 22)
    }

    /// A red-eye (endHour > 24) splits into a clipped-bottom head + clipped-top tail on the next day.
    func testCrossMidnightSplit() {
        let s = timedSegments(ev(23, 30)) // 23:00 → 06:00 next day
        XCTAssertEqual(s.count, 2)
        // Head: day 22, 23–24, continues below.
        XCTAssertEqual(s[0].event.day, 22)
        XCTAssertEqual(Double(s[0].event.startHour), 23, accuracy: 0.001)
        XCTAssertEqual(Double(s[0].event.endHour), 24, accuracy: 0.001)
        XCTAssertFalse(s[0].clipTop); XCTAssertTrue(s[0].clipBottom)
        // Tail: day 23, 00–06, continues from above.
        XCTAssertEqual(s[1].event.day, 23)
        XCTAssertEqual(Double(s[1].event.startHour), 0, accuracy: 0.001)
        XCTAssertEqual(Double(s[1].event.endHour), 6, accuracy: 0.001)
        XCTAssertTrue(s[1].clipTop); XCTAssertFalse(s[1].clipBottom)
        // Every segment carries the whole event's range for its label.
        XCTAssertEqual(Double(s[1].fullStart), 23, accuracy: 0.001)
        XCTAssertEqual(Double(s[1].fullEnd), 30, accuracy: 0.001)
    }

    /// A > 2 day span yields a fully-clipped middle segment.
    func testMultiDaySpan() {
        let s = timedSegments(ev(23, 53)) // 23:00 → 05:00 two days later
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.map(\.event.day), [22, 23, 24])
        XCTAssertTrue(s[1].clipTop && s[1].clipBottom) // middle day is continued on both edges
        XCTAssertEqual(Double(s[2].event.endHour), 5, accuracy: 0.001)
    }

    /// Month rollover: a span crossing the last day of the month lands on day 1 of the next month.
    func testMonthRollover() {
        let e = TimedEvent(
            id: "e",
            year: 2026,
            month: 5,
            day: 30,
            startHour: 23,
            endHour: 26,
            title: "x",
            color: "blue"
        ) // June has 30 days
        let s = timedSegments(e)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[1].event.month, 6) // July (0-based)
        XCTAssertEqual(s[1].event.day, 1)
    }
}
