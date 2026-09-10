// The edge "now" tag is a CLICK TARGET: hovering it reports hover.overNowTag (mild tag
// styling) + the pointing-hand cursor, and clicking glides the timeline so the current time
// lands CENTERED. Real pointer path: nowEdgeTagRects → onHover/cursorHint/onPointerDown.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class NowEdgeClickTests: XCTestCase {
    override func setUp() { super.setUp(); redirectStoreToTemp() }
    override func tearDown() { unsetenv("CC_DEMO_DATADIR"); super.tearDown() }

    func testHoverAndClickOnNowTag() throws {
        let e = CalendarEngine()
        e.viewport = Viewport(w: 1200, h: 800)
        // Week view over TODAY (the now-line needs today in the visible window).
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        e.z = 2
        e.focus = (c.month ?? 1) - 1
        e.week = CGFloat((firstDOW(e.year, e.focus) + (c.day ?? 1) - 1) / 7)
        // Scroll the window AWAY from the current hour so the now-line leaves the viewport.
        let nowFrac = CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60
        e.demoScrollTimelineToHour(nowFrac < 12 ? 16 : 0)
        let g = e.snapshotInput()
        let rect = try XCTUnwrap(nowEdgeTagRects(g).first, "the edge 'now' tag is up")
        let p = CGPoint(x: rect.midX, y: rect.midY)

        // Hover: the tag reports its mild-hover flag and asks for the pointing hand.
        e.onHover(at: p)
        XCTAssertTrue(e.hover.overNowTag, "hover over the tag sets the styling flag")
        XCTAssertEqual(e.cursorHint(at: p), .pointer, "the tag is a click target → hand cursor")

        // Click: the timeline glides so 'now' sits centered in the viewport.
        e.onPointerDown(at: p)
        e.onPointerUp(at: p)
        let tween = try XCTUnwrap(e.anim.tlScrollTween, "the click starts a scroll glide")
        let tl = timelineInfo(g)
        let halfSpan = (tl.tlBottom - tl.tlTop) / tl.hourH / 2
        let expected = max(0, min(tl.maxScroll, (nowFrac - halfSpan) * tl.hourH))
        XCTAssertEqual(tween.to, expected, accuracy: tl.hourH / 20, "now lands mid-viewport")
    }

    func testTagRectsEmptyWhileNowVisible() throws {
        let e = CalendarEngine()
        e.viewport = Viewport(w: 1200, h: 800)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        e.z = 2
        e.focus = (c.month ?? 1) - 1
        e.week = CGFloat((firstDOW(e.year, e.focus) + (c.day ?? 1) - 1) / 7)
        e.demoScrollTimelineToHour(max(0, CGFloat(c.hour ?? 0) - 2)) // now in view
        XCTAssertTrue(nowEdgeTagRects(e.snapshotInput()).isEmpty,
                      "no tag (and so no click target) while the now-line is on-screen")
    }
}
