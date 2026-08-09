import CalendarGeometry
import XCTest

/// altClockText — the alt-timezone second line on the CURRENT TIME pill + cursor time tag,
/// including the "[±N day]" marker when the alt wall-clock crosses a calendar-day boundary.
final class AltClockTextTests: XCTestCase {
    func testSameDayNoMarker() {
        // 13:45 ET → 10:45 PST, same calendar day.
        XCTAssertEqual(altClockText(minutes: 13 * 60 + 45, deltaHours: -3, label: "PST"),
                       "10:45 (PST)")
    }

    func testNextDayMarker() {
        // 13:45 ET → 02:45 JST the NEXT day (+13h).
        XCTAssertEqual(altClockText(minutes: 13 * 60 + 45, deltaHours: 13, label: "JST"),
                       "02:45 (JST) [+1 day]")
    }

    func testPreviousDayMarker() {
        // 02:00 JST → 12:00 AOE the PREVIOUS day (-14h).
        XCTAssertEqual(altClockText(minutes: 2 * 60, deltaHours: -14, label: "AOE"),
                       "12:00 (AOE) [-1 day]")
    }

    func testNoLabel() {
        XCTAssertEqual(altClockText(minutes: 9 * 60 + 30, deltaHours: 5.5, label: nil), "15:00")
    }

    func testHalfHourZoneAcrossMidnight() {
        // 23:00 + 5.5h (India ahead) → 04:30 next day.
        XCTAssertEqual(altClockText(minutes: 23 * 60, deltaHours: 5.5, label: "IST"),
                       "04:30 (IST) [+1 day]")
    }
}
