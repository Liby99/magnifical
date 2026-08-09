@testable import CalendarGeometry
import CoreGraphics
import XCTest

final class GeometryTests: XCTestCase {
    let vp = Viewport(w: 1280, h: 840)

    func input(z: CGFloat, focus: Int = 0, week: CGFloat = 0) -> SceneInput {
        SceneInput(
            z: z,
            focus: focus,
            week: week,
            vp: vp,
            scrollY: 0,
            tlScroll: 0,
            now: Date(timeIntervalSince1970: 0),
            year: 2026
        )
    }

    func testYearFrameLayout() {
        // Jan sits at the top of Q1. The YEAR view uses its own small top inset (Layout.yearTop —
        // no date row up there); topPad is the MONTH-level inset the zoom-in accordion lands on.
        let f = frameFor(0, input(z: 0))
        XCTAssertEqual(f.x0, Layout.labelW, accuracy: 0.001)
        XCTAssertEqual(f.dayW, (vp.w - Layout.labelW) / 31, accuracy: 0.001)
        XCTAssertEqual(f.bandY, Layout.yearTop + Layout.qHeaderH, accuracy: 0.001)
    }

    func testWeekFrameWidensDays() {
        // At week level the focused month's day width is content/7, far wider than year.
        let f = frameFor(0, input(z: 2, focus: 0, week: 0))
        XCTAssertEqual(f.dayW, (vp.w - Layout.labelW) / 7, accuracy: 0.001)
    }

    func testDatesFixedTableAndDOW() {
        XCTAssertEqual(daysInMonth(2026, 1), 28) // Feb always 28 (no leap handling)
        // 2026-01-01 is a Thursday → dayOfWeek == 4.
        XCTAssertEqual(dayOfWeek(2026, 0, 1), 4)
        XCTAssertEqual(firstDOW(2026, 0), 4)
    }

    func testResolveSpillover() {
        // Day 0 of March resolves to the last day of February.
        let r = resolveDate(2026, 2, 0)
        XCTAssertEqual(r?.month, 1)
        XCTAssertEqual(r?.day, 28)
    }

    func testBuildSceneProducesItems() {
        XCTAssertFalse(buildScene(input(z: 0)).items.isEmpty)
        XCTAssertFalse(buildScene(input(z: 2)).items.isEmpty)
    }
}

// Appended: pinned-dashboard reveal regression (week tabs un-clickable bug).
extension GeometryTests {
    /// A fully-pinned panel must read presence 1 at EVERY zoom level. Regression: the presence
    /// denominator used the MONTH panel's resting width (with its dashMonthMinW floor), so in a
    /// narrow window the week panel — narrower than that floor — never reached reveal 1, leaving
    /// the week tab row dimmed and permanently un-clickable (its hit gate needs reveal ≈ 1).
    func testPinnedRevealIsFullAtEveryScopeInNarrowWindow() {
        for z: CGFloat in [1, 1.5, 2] {
            var g = input(z: z)
            g.vp = Viewport(w: 760, h: 700) // narrow: weekFrac·content < dashMonthMinW territory
            g.dashPin = 1
            g.dashWeekFrac = 0.35
            g.dashMonthFrac = 0.25
            XCTAssertEqual(dashRevealTotal(g), 1, accuracy: 0.001,
                           "fully pinned at z=\(z) must be fully revealed")
        }
    }
}
