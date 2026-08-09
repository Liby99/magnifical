@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class ICSExportTests: XCTestCase {
    override func setUp() {
        super.setUp(); redirectStoreToTemp()
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR"); super.tearDown()
    }

    /// Timed event → TZID wall-clock DTSTART/DTEND, escaped SUMMARY, DESCRIPTION from notes.
    func testTimedEventICS() throws {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: 2026, month: 6, day: 20, startHour: 9.5, endHour: 11,
                                    title: "Sync; a,b", color: "blue", notes: "line1\nline2")
        let ics = try XCTUnwrap(e.icsText(for: id))
        XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
        XCTAssertTrue(ics.contains("SUMMARY:Sync\\; a\\,b"), "reserved chars escaped")
        XCTAssertTrue(ics.contains(":20260720T093000"), "0-based month +1, fractional hour → 09:30")
        XCTAssertTrue(ics.contains(":20260720T110000"))
        XCTAssertTrue(ics.contains("DESCRIPTION:line1\\nline2"))
    }

    /// Band → all-day DATE span with EXCLUSIVE DTEND (day after the last day).
    func testBandICSExclusiveEnd() throws {
        let e = CalendarEngine()
        let id = e.createBand(year: 2026, month: 6, track: 0, startDay: 10, endDay: 12,
                              title: "Trip", color: "green")
        let ics = try XCTUnwrap(e.icsText(for: id))
        XCTAssertTrue(ics.contains("DTSTART;VALUE=DATE:20260710"))
        XCTAssertTrue(ics.contains("DTEND;VALUE=DATE:20260713"), "endDay 12 → exclusive end 13")
    }

    /// Weekly repeat with until + exdate → RRULE + EXDATE lines.
    func testRecurrenceRRule() throws {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: 2026, month: 6, day: 20, startHour: 9, endHour: 10,
                                    title: "Standup", color: "blue")
        e.setRepeat(id, Repeat(kind: "weekly", until: "2026-08-01", exdates: ["2026-07-27"]))
        let ics = try XCTUnwrap(e.icsText(for: id))
        XCTAssertTrue(ics.contains("RRULE:FREQ=WEEKLY;UNTIL=20260801"))
        XCTAssertTrue(ics.contains("EXDATE;VALUE=DATE:20260727"))
    }

    /// neighborOccurrence walks the ghost chain both ways and stops at the series edge.
    func testNeighborOccurrence() throws {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: 2026, month: 6, day: 20, startHour: 9, endHour: 10,
                                    title: "Standup", color: "blue")
        // month 6 is 0-based = July → occurrences Jul 20, Jul 27, Aug 3 (until is REAL-month ISO).
        e.setRepeat(id, Repeat(kind: "weekly", until: "2026-08-04"))
        XCTAssertNil(e.neighborOccurrence(of: id, dir: -1), "base is the first occurrence")
        let second = e.neighborOccurrence(of: id, dir: 1)
        XCTAssertEqual(second, "\(id)@2026-6-27")
        let third = try e.neighborOccurrence(of: XCTUnwrap(second), dir: 1)
        XCTAssertEqual(third, "\(id)@2026-7-3")
        XCTAssertNil(try e.neighborOccurrence(of: XCTUnwrap(third), dir: 1), "past the until date")
        XCTAssertEqual(try e.neighborOccurrence(of: XCTUnwrap(third), dir: -1), second, "walks back too")
    }
}
