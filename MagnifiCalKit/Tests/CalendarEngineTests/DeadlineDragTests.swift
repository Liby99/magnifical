// Regression: dragging a deadline by its LABEL PILL (the "tag") must move the data AND the
// line geometry the renderer strokes (2026-09 bug: the pill followed the drag while the Canvas
// moment line stayed frozen — see MidDeadlinesCanvasTests for the render-invalidation half).
// This half exercises the real pointer path end to end: hit-test at the pill rect →
// onPointerDown → onPointerDrag → applyDdlMove → deadlinePos.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class DeadlineDragTests: XCTestCase {
    override func setUp() { super.setUp(); redirectStoreToTemp() }
    override func tearDown() { unsetenv("CC_DEMO_DATADIR"); super.tearDown() }

    func testLabelDragMovesDataAndLineGeometry() throws {
        let e = CalendarEngine()
        // Early morning + early in the week: the deadline must land inside the headless
        // viewport's visible timeline (week view culls off-screen columns/hours to nil pos).
        let id = e.createDeadline(year: e.year, month: 6, day: 2, hour: 4, title: "Ship", color: "red")
        e.viewport = Viewport(w: 1200, h: 800)
        e.z = 2; e.focus = 6 // settled week view
        let g0 = e.snapshotInput()
        let tl = timelineInfo(g0)
        let d0 = try XCTUnwrap(e.viewDeadlines().first { $0.id == id })
        let pos0 = try XCTUnwrap(deadlinePos(d0, g0), "deadline must be visible before the drag")

        // Pointer-down on the LABEL PILL (not the line) — exactly how the user drags the tag.
        let sides = e.deadlineSides()
        let info = deadlineLabelInfo(d0, lineX: pos0.x, lineY: pos0.y, colW: pos0.w, g0)
        let pill = info.rect(onLeft: sides[d0.id] ?? info.defaultOnLeft)
        let p0 = CGPoint(x: pill.midX, y: pill.midY)
        XCTAssertEqual(e.deadlineAt(p0, g0), id, "the pill rect must hit-test to the deadline")
        e.onPointerDown(at: p0, shift: false, command: false)
        e.onPointerDrag(at: CGPoint(x: p0.x, y: p0.y + 2 * tl.hourH)) // drag down 2 hours

        let d1 = try XCTUnwrap(e.viewDeadlines().first { $0.id == id })
        let pos1 = try XCTUnwrap(deadlinePos(d1, e.snapshotInput()))
        XCTAssertEqual(d1.hour, d0.hour + 2, accuracy: 0.01, "data follows the drag")
        XCTAssertEqual(pos1.y, pos0.y + 2 * tl.hourH, accuracy: 0.5, "line geometry follows the data")
    }
}
