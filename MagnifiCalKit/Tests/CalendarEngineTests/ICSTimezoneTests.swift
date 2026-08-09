// TZID resolution on .ics import — the Outlook/Exchange cases. Windows zone names ("Eastern
// Standard Time") aren't IANA identifiers; before the resolver chain (IANA → Windows map →
// VTIMEZONE → embedded offset → floating) they silently fell back to UTC, shifting every
// imported event by the device's whole UTC offset ("the -4h import bug").
//
// Expectations are computed with Foundation from the SAME source zone the fixture declares, so
// the assertions hold in any device timezone the tests run in.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class ICSTimezoneTests: XCTestCase {
    /// Wrap a VEVENT body (plus optional preamble like VTIMEZONE) into a VCALENDAR.
    private func ics(_ body: String, preamble: String = "") -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n\(preamble)BEGIN:VEVENT\r\nUID:x1\r\nSUMMARY:Mtg\r\n\(body)END:VEVENT\r\nEND:VCALENDAR\r\n"
    }

    /// Device-local wall clock for a source-zone wall time — the importer's documented target.
    private func localWC(zone: TimeZone, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int)
        -> (day: Int, hour: CGFloat) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        let instant = cal.date(from: c)!
        let lc = Calendar.current.dateComponents([.day, .hour, .minute], from: instant)
        return (lc.day!, CGFloat(lc.hour!) + CGFloat(lc.minute!) / 60)
    }

    /// Windows zone name (Outlook) → the mapped IANA zone's conversion, not UTC.
    func testWindowsTZIDResolves() throws {
        let text = ics("""
        DTSTART;TZID=Eastern Standard Time:20260810T100000\r
        DTEND;TZID=Eastern Standard Time:20260810T110000\r

        """)
        let r = ICSImport.items(from: text, provenance: "t.ics")
        let ev = try XCTUnwrap(r.events.first)
        let want = try localWC(zone: XCTUnwrap(TimeZone(identifier: "America/New_York")), 2026, 8, 10, 10, 0)
        XCTAssertEqual(ev.day, want.day)
        XCTAssertEqual(ev.startHour, want.hour, accuracy: 0.001, "10:00 EDT, not 10:00-as-UTC")
        XCTAssertEqual(ev.endHour - ev.startHour, 1, accuracy: 0.001)
    }

    /// A TZID defined only by the file's VTIMEZONE (custom name): seasonal offsets apply —
    /// -0400 during daylight (2nd Sun of Mar → 1st Sun of Nov), -0500 outside it.
    func testVTimezoneSeasonalRules() throws {
        let vtz = """
        BEGIN:VTIMEZONE\r
        TZID:Weird Corp Zone\r
        BEGIN:STANDARD\r
        DTSTART:16011104T020000\r
        RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11\r
        TZOFFSETFROM:-0400\r
        TZOFFSETTO:-0500\r
        END:STANDARD\r
        BEGIN:DAYLIGHT\r
        DTSTART:16010311T020000\r
        RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3\r
        TZOFFSETFROM:-0500\r
        TZOFFSETTO:-0400\r
        END:DAYLIGHT\r
        END:VTIMEZONE\r

        """
        // August (daylight, -0400)
        let summer = ICSImport.items(from: ics("""
        DTSTART;TZID=Weird Corp Zone:20260810T100000\r
        DTEND;TZID=Weird Corp Zone:20260810T110000\r

        """, preamble: vtz), provenance: "t.ics")
        let sWant = localWC(zone: TimeZone(secondsFromGMT: -4 * 3600)!, 2026, 8, 10, 10, 0)
        let sEv = try XCTUnwrap(summer.events.first)
        XCTAssertEqual(sEv.startHour, sWant.hour, accuracy: 0.001, "August → daylight offset -0400")
        // January (standard, -0500)
        let winter = ICSImport.items(from: ics("""
        DTSTART;TZID=Weird Corp Zone:20260112T100000\r
        DTEND;TZID=Weird Corp Zone:20260112T110000\r

        """, preamble: vtz), provenance: "t.ics")
        let wWant = localWC(zone: TimeZone(secondsFromGMT: -5 * 3600)!, 2026, 1, 12, 10, 0)
        let wEv = try XCTUnwrap(winter.events.first)
        XCTAssertEqual(wEv.startHour, wWant.hour, accuracy: 0.001, "January → standard offset -0500")
    }

    /// Unknown TZID, no VTIMEZONE, no embedded offset → FLOATING (the sender's numbers), never UTC.
    func testUnknownTZIDFallsBackToFloating() throws {
        let text = ics("""
        DTSTART;TZID=Totally Made Up Zone:20260810T100000\r
        DTEND;TZID=Totally Made Up Zone:20260810T110000\r

        """)
        let ev = try XCTUnwrap(ICSImport.items(from: text, provenance: "t.ics").events.first)
        XCTAssertEqual(ev.day, 10)
        XCTAssertEqual(ev.startHour, 10, accuracy: 0.001, "unresolvable zone keeps the wall clock as written")
    }

    /// Display-name TZID (quoted — it contains ':' and ',') with an embedded offset → that offset.
    func testEmbeddedOffsetTZID() throws {
        let text = ics("""
        DTSTART;TZID="(UTC+05:30) Chennai, Kolkata, Mumbai, New Delhi":20260810T100000\r

        """)
        let ev = try XCTUnwrap(ICSImport.items(from: text, provenance: "t.ics").events.first)
        let want = localWC(zone: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!, 2026, 8, 10, 10, 0)
        XCTAssertEqual(ev.startHour, want.hour, accuracy: 0.001, "embedded +05:30 honored")
    }

    /// Mozilla-style path TZID ("/mozilla.org/20070129_1/America/New_York") → trailing IANA pair.
    func testMozillaPathTZID() throws {
        let text = ics("""
        DTSTART;TZID=/mozilla.org/20070129_1/America/New_York:20260810T100000\r

        """)
        let ev = try XCTUnwrap(ICSImport.items(from: text, provenance: "t.ics").events.first)
        let want = try localWC(zone: XCTUnwrap(TimeZone(identifier: "America/New_York")), 2026, 8, 10, 10, 0)
        XCTAssertEqual(ev.startHour, want.hour, accuracy: 0.001)
    }

    /// "…Z" UTC stamps keep the existing instant conversion.
    func testUTCStampStillConverts() throws {
        let text = ics("DTSTART:20260810T140000Z\r\n")
        let ev = try XCTUnwrap(ICSImport.items(from: text, provenance: "t.ics").events.first)
        let want = try localWC(zone: XCTUnwrap(TimeZone(identifier: "UTC")), 2026, 8, 10, 14, 0)
        XCTAssertEqual(ev.day, want.day)
        XCTAssertEqual(ev.startHour, want.hour, accuracy: 0.001)
    }

    /// DURATION instead of DTEND (Outlook sends this) → a real span, not a point event.
    func testDurationProperty() throws {
        let text = ics("""
        DTSTART;TZID=Eastern Standard Time:20260810T100000\r
        DURATION:PT1H30M\r

        """)
        let ev = try XCTUnwrap(ICSImport.items(from: text, provenance: "t.ics").events.first)
        XCTAssertEqual(ev.endHour - ev.startHour, 1.5, accuracy: 0.001)
    }

    /// STATUS:CANCELLED (METHOD:CANCEL mails) imports nothing.
    func testCancelledEventSkipped() {
        let text = ics("""
        DTSTART;TZID=Eastern Standard Time:20260810T100000\r
        STATUS:CANCELLED\r

        """)
        let r = ICSImport.items(from: text, provenance: "t.ics")
        XCTAssertTrue(r.events.isEmpty && r.bands.isEmpty)
    }

    /// The Windows table's IANA values must all resolve in Foundation (typo guard).
    func testWindowsMapTargetsResolve() {
        for (win, iana) in ICSImport.windowsTZ {
            XCTAssertNotNil(TimeZone(identifier: iana), "\(win) → \(iana) not a valid IANA zone")
        }
    }
}
