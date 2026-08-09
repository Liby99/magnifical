@testable import CalendarGeometry
import CoreGraphics
import XCTest

/// The DST-aware wall-clock converter that underlies both display (anchor→view) and write-back (view→anchor).
final class ConversionTests: XCTestCase {
    /// convertWall picks the offset at the event's own instant: NY→UTC is +4 (EDT) in July, +5 (EST) in January.
    func testDSTAware() {
        let jul = DeadlineTZ.convertWall(2026, 6, 20, 12, from: "America/New_York", to: "UTC")
        XCTAssertEqual(Double(jul.hour), 16, accuracy: 0.001) // 12:00 EDT = 16:00 UTC
        let jan = DeadlineTZ.convertWall(2026, 0, 20, 12, from: "America/New_York", to: "UTC")
        XCTAssertEqual(Double(jan.hour), 17, accuracy: 0.001) // 12:00 EST = 17:00 UTC
    }

    /// Round-trip through a far zone returns the original wall-clock AND date (the write-back guarantee).
    func testRoundTrip() {
        let there = DeadlineTZ.convertWall(2026, 6, 20, 14, from: "America/New_York", to: "Asia/Tokyo")
        let back = DeadlineTZ.convertWall(
            there.year,
            there.month,
            there.day,
            there.hour,
            from: "Asia/Tokyo",
            to: "America/New_York"
        )
        XCTAssertEqual(back.year, 2026); XCTAssertEqual(back.month, 6); XCTAssertEqual(back.day, 20)
        XCTAssertEqual(Double(back.hour), 14, accuracy: 0.001)
    }

    /// A half-hour zone (India, +5:30) and the AOE pseudo-zone (UTC−12, day-crossing) resolve correctly.
    func testFractionalAndAOE() {
        let ist = DeadlineTZ.convertWall(2026, 6, 20, 0, from: "UTC", to: "Asia/Kolkata")
        XCTAssertEqual(Double(ist.hour), 5.5, accuracy: 0.001) // 00:00 UTC = 05:30 IST
        // 23:59 AOE (UTC−12) on Jul 20 = 11:59 UTC on Jul 21.
        let aoe = DeadlineTZ.convertWall(2026, 6, 20, 23 + 59.0 / 60, from: "AOE", to: "UTC")
        XCTAssertEqual(aoe.day, 21)
        XCTAssertEqual(Double(aoe.hour), 11 + 59.0 / 60, accuracy: 0.01)
    }

    /// Same offset (or same zone) is the identity — no shift, no date change.
    func testIdentityWhenSameOffset() {
        let same = DeadlineTZ.convertWall(2026, 6, 20, 9.5, from: "America/New_York", to: "America/New_York")
        XCTAssertEqual(same.day, 20); XCTAssertEqual(Double(same.hour), 9.5, accuracy: 0.001)
        XCTAssertTrue(DeadlineTZ.sameOffset("auto", TimeZone.current.identifier, at: Date()))
    }
}
