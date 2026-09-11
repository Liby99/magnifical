// Day-view pinch deferral gate: pinchDirectionDecides is true exactly where a shallow-angle
// pinch should wait for its DIRECTION (day view, over the timeline) — pinch-out then scales
// the timeline (no deeper view exists) while pinch-in still zooms out. Week/month keep the
// pure angle rule, and the day dashboard region never defers.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class PinchDirectionTests: XCTestCase {
    override func setUp() { super.setUp(); redirectStoreToTemp() }
    override func tearDown() { unsetenv("CC_DEMO_DATADIR"); super.tearDown() }

    func testGateOnlyInDayViewOverTimeline() throws {
        let e = CalendarEngine()
        e.viewport = Viewport(w: 1200, h: 800)
        e.focus = 6
        e.z = 3 // day view — no deeper view to zoom into
        let tl = timelineInfo(e.snapshotInput())
        let onTimeline = CGPoint(x: Layout.labelW + 60, y: (tl.tlTop + tl.tlBottom) / 2)
        XCTAssertTrue(e.pinchDirectionDecides(at: onTimeline),
                      "day view over the timeline → direction picks the pinch target")
        XCTAssertFalse(e.pinchDirectionDecides(at: CGPoint(x: onTimeline.x, y: tl.tlTop - 40)),
                       "above the timeline (band lanes) → normal view zoom")
        XCTAssertFalse(e.pinchDirectionDecides(at: CGPoint(x: e.viewport.w - 60, y: onTimeline.y)),
                       "over the day dashboard → normal view zoom")

        e.z = 2 // week view: zooming IN still has a deeper view — angle rule only
        XCTAssertFalse(e.pinchDirectionDecides(at: onTimeline),
                       "week view keeps the pure angle rule")
    }
}
