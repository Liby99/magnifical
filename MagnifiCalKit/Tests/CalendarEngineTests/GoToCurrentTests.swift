@testable import CalendarEngine
import CalendarGeometry
import XCTest

/// View ▸ Go to Current … — each lands on TODAY's period at the named zoom level.
@MainActor
final class GoToCurrentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("CC_DEMO_DATADIR", NSTemporaryDirectory() + "cc-gotocurrent-tests-" + UUID().uuidString, 1)
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    private var today: (m: Int, d: Int) {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return ((c.month ?? 1) - 1, c.day ?? 1)
    }

    func testGoToCurrentMonthFocusesToday() {
        let e = CalendarEngine()
        e.demoGoToYear(centerMonth: (today.m + 6) % 12) // start on some other month, year level
        e.goToCurrent("month")
        XCTAssertEqual(e.focus, today.m)
        XCTAssertEqual(e.chrome.level, 1)
    }

    func testGoToCurrentWeekLandsOnTodaysWeek() {
        let e = CalendarEngine()
        e.demoGoToYear(centerMonth: (today.m + 6) % 12)
        e.goToCurrent("week")
        XCTAssertEqual(e.focus, today.m)
        XCTAssertEqual(Int(e.week), weekOfDate(e.year, today.m, today.d))
        XCTAssertEqual(e.chrome.level, 2)
    }

    func testGoToCurrentYearFocusesCurrentMonth() {
        let e = CalendarEngine()
        e.goToCurrent("week") // wander in…
        e.goToCurrent("year") // …and back out
        XCTAssertEqual(e.focus, today.m)
        XCTAssertEqual(e.chrome.level, 0)
    }
}
