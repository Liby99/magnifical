// Deadline edge indicators (out-of-viewport deadlines → edge line + empty mini pill):
// deadlineEdgePos must be non-nil EXACTLY when the deadline's column is visible but its hour
// is scrolled out of the timeline — mutually exclusive with deadlinePos — with the correct
// top/bottom flag and the line clamped just inside the edge.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class DeadlineEdgeTests: XCTestCase {
    override func setUp() { super.setUp(); redirectStoreToTemp() }
    override func tearDown() { unsetenv("CC_DEMO_DATADIR"); super.tearDown() }

    private func makeEngine() -> (CalendarEngine, String) {
        let e = CalendarEngine()
        let id = e.createDeadline(year: e.year, month: 6, day: 2, hour: 4, title: "Ship", color: "red")
        e.viewport = Viewport(w: 1200, h: 800)
        e.z = 2; e.focus = 6 // settled week view
        return (e, id)
    }

    func testVisibleDeadlineHasNoEdgeIndicator() throws {
        let (e, id) = makeEngine()
        let g = e.snapshotInput()
        let d = try XCTUnwrap(e.viewDeadlines().first { $0.id == id })
        XCTAssertNotNil(deadlinePos(d, g), "hour 4 is on-screen at the settled scroll")
        XCTAssertNil(deadlineEdgePos(d, g), "on-screen ⇒ no edge indicator")
    }

    func testScrolledAboveClampsToTopEdge() throws {
        let (e, id) = makeEngine()
        e.demoScrollTimelineToHour(14) // late window → hour 4 exits through the TOP
        let g = e.snapshotInput()
        let tl = timelineInfo(g)
        let d = try XCTUnwrap(e.viewDeadlines().first { $0.id == id })
        XCTAssertNil(deadlinePos(d, g), "hour 4 is scrolled out")
        let ep = try XCTUnwrap(deadlineEdgePos(d, g), "scrolled out ⇒ edge indicator")
        XCTAssertTrue(ep.top, "left through the top edge")
        XCTAssertEqual(ep.y, tl.tlTop + 1, accuracy: 0.01, "line hugs just inside the top edge")
    }

    func testBelowFoldClampsToBottomEdge() throws {
        let (e, _) = makeEngine()
        let late = e.createDeadline(year: e.year, month: 6, day: 2, hour: 23, title: "Late", color: "blue")
        e.demoScrollTimelineToHour(2) // early window → hour 23 sits below the fold
        let g = e.snapshotInput()
        let tl = timelineInfo(g)
        let d = try XCTUnwrap(e.viewDeadlines().first { $0.id == late })
        XCTAssertNil(deadlinePos(d, g))
        let ep = try XCTUnwrap(deadlineEdgePos(d, g))
        XCTAssertFalse(ep.top, "left through the bottom edge")
        XCTAssertEqual(ep.y, tl.tlBottom - 1, accuracy: 0.01, "line hugs just inside the bottom edge")
        // The edge line spans the same day column the on-screen line would.
        XCTAssertGreaterThan(ep.w, 0)
    }

    func testHoverAndClickOnEdgePillCentersDeadline() throws {
        // The edge mini pill is a CLICK TARGET: hover → hand cursor + mild pill styling,
        // click → the timeline glides so the deadline's hour lands mid-viewport.
        let (e, id) = makeEngine()
        e.demoScrollTimelineToHour(14) // hour-4 deadline exits through the TOP
        let g = e.snapshotInput()
        let d = try XCTUnwrap(e.viewDeadlines().first { $0.id == id })
        let lab = try XCTUnwrap(deadlineEdgeLabel(d, g), "the edge pill is up")
        let p = CGPoint(x: lab.rect.midX, y: lab.rect.midY)

        e.onHover(at: p)
        XCTAssertEqual(e.hoveredEventId, id, "hover lights the pill (mild styling)")
        XCTAssertTrue(e.hover.overDeadline)
        XCTAssertEqual(e.cursorHint(at: p), .pointer, "click target → hand cursor")

        e.onPointerDown(at: p)
        e.onPointerUp(at: p)
        let tween = try XCTUnwrap(e.anim.tlScrollTween, "the click starts a scroll glide")
        let tl = timelineInfo(g)
        let halfSpan = (tl.tlBottom - tl.tlTop) / tl.hourH / 2
        let expected = max(0, min(tl.maxScroll, (d.hour - halfSpan) * tl.hourH))
        XCTAssertEqual(tween.to, expected, accuracy: 0.5, "the deadline lands mid-viewport")
    }

    func testEdgePillBeatsOverlappingEventEdgeStack() throws {
        // Day 2's pill sits LEFT of its column — over day 1. Give day 1 an early timed event
        // that's also scrolled out the top: its edge card's click band covers that column at
        // tlTop, exactly under the pill. The pill must win (center the DEADLINE), not the stack.
        let (e, id) = makeEngine()
        _ = e.createTimedEvent(year: e.year, month: 6, day: 1, startHour: 3, endHour: 5,
                               title: "Early", color: "blue")
        e.demoScrollTimelineToHour(14)
        let g = e.snapshotInput()
        let d = try XCTUnwrap(e.viewDeadlines().first { $0.id == id })
        let lab = try XCTUnwrap(deadlineEdgeLabel(d, g))
        let p = CGPoint(x: lab.rect.midX, y: lab.rect.midY)
        XCTAssertNotNil(e.edgeIndicatorTarget(at: p, g),
                        "precondition: the pill genuinely overlaps the neighbor's edge stack")
        e.onPointerDown(at: p)
        e.onPointerUp(at: p)
        let tween = try XCTUnwrap(e.anim.tlScrollTween)
        let tl = timelineInfo(g)
        let halfSpan = (tl.tlBottom - tl.tlTop) / tl.hourH / 2
        let expected = max(0, min(tl.maxScroll, (d.hour - halfSpan) * tl.hourH))
        XCTAssertEqual(tween.to, expected, accuracy: 0.5,
                       "the click centers the DEADLINE, not the overlapped event")
    }

    func testCulledColumnHasNoIndicatorEither() throws {
        // Day 15 is off the settled week window entirely (column culled) — neither the line
        // nor an edge indicator should render for it.
        let (e, _) = makeEngine()
        let far = e.createDeadline(year: e.year, month: 6, day: 28, hour: 4, title: "Far", color: "red")
        let g = e.snapshotInput()
        let d = try XCTUnwrap(e.viewDeadlines().first { $0.id == far })
        XCTAssertNil(deadlinePos(d, g))
        XCTAssertNil(deadlineEdgePos(d, g), "an off-window COLUMN is culled, not edge-clamped")
    }
}
