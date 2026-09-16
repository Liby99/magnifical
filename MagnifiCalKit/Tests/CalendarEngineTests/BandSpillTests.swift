// Cross-month (SPILLING) bands: endDay may exceed daysInMonth — one entity crossing the
// boundary, anchored at its start month, year-bounded. Covers the day-of-year math, the
// spill-aware accessors/enumeration, keyboard crossing, and the per-month-row render segments.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class BandSpillTests: XCTestCase {
    private func spilled(_ e: CalendarEngine) -> BandEvent {
        // Jan 30 … Feb 2 (endDay 33 relative to January)
        BandEvent(id: "sp", year: e.year, month: 0, track: 0,
                  startDay: 30, endDay: 33, title: "Trip", color: "blue")
    }

    func testYearDayRoundtrip() {
        XCTAssertEqual(CalendarEngine.yearDay(2026, 0, 1), 1)
        XCTAssertEqual(CalendarEngine.yearDay(2026, 1, 1), 32) // Feb 1
        XCTAssertEqual(CalendarEngine.yearDay(2026, 0, 33), 33) // spilled day-of-month input
        XCTAssertEqual(CalendarEngine.daysInYear(2026), 365)
        XCTAssertEqual(CalendarEngine.daysInYear(2028), 366)
        let (m, d) = CalendarEngine.monthDay(ofYearDay: 33, 2026)
        XCTAssertEqual(m, 1); XCTAssertEqual(d, 2) // Feb 2
        let (m2, d2) = CalendarEngine.monthDay(ofYearDay: 365, 2026)
        XCTAssertEqual(m2, 11); XCTAssertEqual(d2, 31)
    }

    func testBandEndYMDAndCovers() {
        let e = CalendarEngine()
        let b = spilled(e)
        let end = e.bandEndYMD(b)
        XCTAssertEqual(end.month, 1); XCTAssertEqual(end.day, 2); XCTAssertEqual(end.year, e.year)
        XCTAssertTrue(e.bandCovers(b, month: 0, day: 30))
        XCTAssertTrue(e.bandCovers(b, month: 1, day: 1))
        XCTAssertTrue(e.bandCovers(b, month: 1, day: 2))
        XCTAssertFalse(e.bandCovers(b, month: 1, day: 3))
        XCTAssertFalse(e.bandCovers(b, month: 0, day: 29))
    }

    func testBandsTouchingMonthSeesSpill() {
        let e = CalendarEngine()
        e.applyRemote(bands: [spilled(e)])
        XCTAssertTrue(e.bandsTouchingMonth(e.year, 0).contains { $0.id == "sp" })
        XCTAssertTrue(e.bandsTouchingMonth(e.year, 1).contains { $0.id == "sp" },
                      "the February row must see the January band's continuation")
        XCTAssertFalse(e.bandsTouchingMonth(e.year, 2).contains { $0.id == "sp" })
    }

    func testKeyboardNudgeCrossesBoundaryAndReanchors() throws {
        let e = CalendarEngine()
        e.applyRemote(bands: [BandEvent(id: "nb", year: e.year, month: 0, track: 0,
                                        startDay: 30, endDay: 31, title: "N", color: "red")])
        e.select("nb")
        e.nudgeHorizontal(1) // Jan 31 … spills one day into Feb
        var b = try XCTUnwrap(e.band("nb"))
        XCTAssertEqual(b.month, 0); XCTAssertEqual(b.startDay, 31); XCTAssertEqual(b.endDay, 32)
        e.nudgeHorizontal(1) // start crosses → re-anchors to February
        b = try XCTUnwrap(e.band("nb"))
        XCTAssertEqual(b.month, 1); XCTAssertEqual(b.startDay, 1); XCTAssertEqual(b.endDay, 2)
        e.nudgeHorizontal(-1) // and back across
        b = try XCTUnwrap(e.band("nb"))
        XCTAssertEqual(b.month, 0); XCTAssertEqual(b.startDay, 31); XCTAssertEqual(b.endDay, 32)
    }

    func testKeyboardResizeSpillsPastMonthEnd() throws {
        let e = CalendarEngine()
        e.applyRemote(bands: [BandEvent(id: "rb", year: e.year, month: 0, track: 0,
                                        startDay: 30, endDay: 31, title: "R", color: "red")])
        e.select("rb")
        e.resizeSelected(1, 0)
        XCTAssertEqual(try XCTUnwrap(e.band("rb")?.endDay), 32, "⇧→ extends past Jan 31 into Feb")
        XCTAssertEqual(try e.bandEndYMD(XCTUnwrap(e.band("rb"))).month, 1)
    }

    /// Mirrors EventDrawer.bandDayBinding's set() composition exactly: picking an END date in
    /// the next month spills the band; picking a START in an earlier month re-anchors it while
    /// the absolute end date stays fixed.
    func testDrawerStyleDateEditsCrossMonths() throws {
        let e = CalendarEngine()
        e.applyRemote(bands: [BandEvent(id: "db", year: e.year, month: 6, track: 0,
                                        startDay: 15, endDay: 20, title: "D", color: "blue")])
        e.updateBand("db") { b in // end picker → Aug 4
            let picked = CalendarEngine.yearDay(b.year, 7, 4)
            let s = CalendarEngine.yearDay(b.year, b.month, b.startDay)
            b.endDay = b.startDay + (max(picked, s) - s)
        }
        var b = try XCTUnwrap(e.band("db"))
        XCTAssertEqual(b.month, 6); XCTAssertEqual(b.startDay, 15)
        var end = e.bandEndYMD(b)
        XCTAssertEqual(end.month, 7); XCTAssertEqual(end.day, 4)
        e.updateBand("db") { b in // start picker → Jun 28: re-anchor, absolute end fixed
            let picked = CalendarEngine.yearDay(b.year, 5, 28)
            let s = CalendarEngine.yearDay(b.year, b.month, b.startDay)
            let eYD = s + (b.endDay - b.startDay)
            let ns = min(picked, eYD)
            let (m, day) = CalendarEngine.monthDay(ofYearDay: ns, b.year)
            b.month = m; b.startDay = day; b.endDay = day + (eYD - ns)
        }
        b = try XCTUnwrap(e.band("db"))
        XCTAssertEqual(b.month, 5); XCTAssertEqual(b.startDay, 28)
        end = e.bandEndYMD(b)
        XCTAssertEqual(end.month, 7); XCTAssertEqual(end.day, 4, "end date unchanged by the start edit")
    }

    func testSpilledBandRendersOneSegmentPerMonthRow() throws {
        let e = CalendarEngine()
        e.setViewport(CGSize(width: 1200, height: 800))
        // Anchor on the FOCUS month (the year view opens scrolled there — January's row could
        // be culled off-screen): last two days of focus + two days of the next month.
        let m = min(e.focus, 10)
        let dim = daysInMonth(e.year, m)
        e.applyRemote(bands: [BandEvent(id: "sp2", year: e.year, month: m, track: 0,
                                        startDay: dim - 1, endDay: dim + 2,
                                        title: "Trip", color: "blue")])
        let segs = try bandEventRects(XCTUnwrap(e.band("sp2")), e.snapshotInput())
        try XCTSkipIf(segs.isEmpty, "focus rows unexpectedly off-screen in this viewport")
        XCTAssertEqual(segs.count, 2, "anchor bar on its row + continuation on the next month's")
        XCTAssertEqual(segs[0].rowMonth, m)
        XCTAssertEqual(segs[1].rowMonth, m + 1)
        XCTAssertTrue(segs[0].clipEnd, "the seam is square — the bar continues")
        XCTAssertFalse(segs[0].clipStart)
        XCTAssertTrue(segs[1].clipStart, "the continuation opens square, no accent bar")
        XCTAssertGreaterThan(segs[1].y, segs[0].y, "rows stack vertically in year view")
    }
}
