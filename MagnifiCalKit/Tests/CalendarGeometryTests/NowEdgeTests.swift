// Now-line edge indicator: when "now" is scrolled out of the week/day timeline, buildToday
// must emit the .nowEdge line hugging the edge + the .nowLabelEdge mini "now" tag — and keep
// both at opacity 0 while the now-line is on-screen (mutually exclusive with now-w/nl-w).

@testable import CalendarGeometry
import CoreGraphics
import XCTest

final class NowEdgeTests: XCTestCase {
    let vp = Viewport(w: 1280, h: 840)

    /// Week view over the month containing `now` (local calendar), with a given timeline scroll.
    private func input(now: Date, tlScroll: CGFloat) -> SceneInput {
        let c = Calendar.current.dateComponents([.year, .month], from: now)
        return SceneInput(z: 2, focus: (c.month ?? 1) - 1, week: 0, vp: vp, scrollY: 0,
                          tlScroll: tlScroll, now: now, year: c.year ?? 2026)
    }

    /// A `now` on a day early in its month (so week 0 shows it), at 04:00 local.
    private func earlyMorningNow() -> Date {
        var c = Calendar.current.dateComponents([.year, .month], from: Date())
        c.day = 2; c.hour = 4; c.minute = 0
        return Calendar.current.date(from: c)!
    }

    private func item(_ g: SceneInput, _ key: String) -> Item? {
        buildScene(g).items.first { $0.key == key }
    }

    func testVisibleNowHasNoEdgeIndicator() throws {
        let g = input(now: earlyMorningNow(), tlScroll: 0) // hours ~0–10 in view → 04:00 visible
        let line = try XCTUnwrap(item(g, "now-w"))
        XCTAssertGreaterThan(line.opacity, 0.5, "the on-screen now-line renders")
        XCTAssertEqual(item(g, "now-w-edge")?.opacity ?? 0, 0, "no edge line while on-screen")
        XCTAssertEqual(item(g, "now-w-edgetag")?.opacity ?? 0, 0, "no edge tag while on-screen")
    }

    func testScrolledOutNowClampsToTopEdge() throws {
        let g = input(now: earlyMorningNow(), tlScroll: 700) // late window → 04:00 exits the TOP
        XCTAssertEqual(item(g, "now-w")?.opacity ?? 0, 0, "the real now-line is off-screen")
        let edge = try XCTUnwrap(item(g, "now-w-edge"))
        XCTAssertGreaterThan(edge.opacity, 0.5, "edge line shows when now is scrolled out")
        let f = frameFor(g.focus, g)
        let tlTop = f.bandY + 4 * f.trackH + 18
        XCTAssertEqual(edge.y, tlTop + 1, accuracy: 0.01, "line hugs just inside the top edge")
        let tag = try XCTUnwrap(item(g, "now-w-edgetag"))
        XCTAssertGreaterThan(tag.opacity, 0.5)
        XCTAssertEqual(tag.text, "now", "the mini tag says just \"now\"")
        XCTAssertEqual(tag.h, 17, accuracy: 0.01, "fixed mini size, not the CURRENT TIME pill")
    }
}
