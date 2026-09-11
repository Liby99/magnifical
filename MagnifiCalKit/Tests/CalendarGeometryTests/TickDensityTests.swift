// Timeline time-tick density follows the hour height (the pinch / scale-bar knob):
// resting scale → a label every 2 hours; past the MIDPOINT of [MIN_HOUR_H, MAX_HOUR_H] →
// every hour; past 90% of the range → half-hour ticks + labels too.

@testable import CalendarGeometry
import CoreGraphics
import XCTest

final class TickDensityTests: XCTestCase {
    private func input(hourH: CGFloat) -> SceneInput {
        SceneInput(z: 2, focus: 6, week: 0, vp: Viewport(w: 1280, h: 840), scrollY: 0,
                   tlScroll: 300, now: Date(timeIntervalSince1970: 0), year: 2026,
                   weekHourH: hourH)
    }

    private func labelKeys(_ g: SceneInput) -> Set<String> {
        Set(buildScene(g).items.filter { $0.kind == .dayLabel && $0.opacity > 0 }.map(\.key))
    }

    func testRestingScaleLabelsEveryTwoHours() {
        let keys = labelKeys(input(hourH: 50)) // below the midpoint (62.5)
        XCTAssertTrue(keys.contains("ht-8"))
        XCTAssertFalse(keys.contains("ht-9"), "odd hours unlabeled at resting scale")
        XCTAssertFalse(keys.contains { $0.hasSuffix("h") }, "no half-hour labels")
    }

    func testPastMidpointLabelsEveryHour() {
        let keys = labelKeys(input(hourH: 70)) // past the midpoint, below 90% (84.5)
        XCTAssertTrue(keys.contains("ht-8"))
        XCTAssertTrue(keys.contains("ht-9"), "every hour labeled past the midpoint")
        XCTAssertFalse(keys.contains { $0.hasSuffix("h") }, "still no half-hour labels")
    }

    func testPastNinetyPercentAddsHalfHours() {
        let g = input(hourH: 88) // past 90% of the range
        let keys = labelKeys(g)
        XCTAssertTrue(keys.contains("ht-8"))
        XCTAssertTrue(keys.contains("ht-8h"), "half-hour labels at the dense scale")
        let half = buildScene(g).items.first { $0.key == "ht-8h" }
        XCTAssertEqual(half?.text, "08:30")
        XCTAssertTrue(buildScene(g).items.contains { $0.key == "hl-8h" && $0.opacity > 0 },
                      "…with a matching half-hour gridline")
    }
}
