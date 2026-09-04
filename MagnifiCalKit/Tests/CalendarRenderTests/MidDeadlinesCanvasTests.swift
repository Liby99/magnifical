// Regression: the deadline moment-line Canvas must RE-RECORD when a deadline moves.
//
// The 2026-09 bug: the line was drawn by an inline `Canvas {}` that read the deadlines inside
// its closure, so SwiftUI saw no changed inputs during a label drag (static scene ⇒ identical
// SceneInput every frame) and never re-recorded — the pill followed the drag while the line
// froze. The fix is MidDeadlinesCanvas: an Equatable wrapper whose == keys on everything the
// draw reads. These tests pin that contract — == must break exactly when a draw input changes,
// and must hold when nothing the draw reads changed (so the drag fix can't regress into
// re-recording every frame either).

@testable import CalendarEngine
import CalendarGeometry
@testable import CalendarRender
import SwiftUI
import XCTest

@MainActor
final class MidDeadlinesCanvasTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "cktest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("CC_DEMO_DATADIR", dir, 1) // never touch the real store
    }

    override func tearDown() { unsetenv("CC_DEMO_DATADIR"); super.tearDown() }

    private func makeCanvas() -> MidDeadlinesCanvas {
        let e = CalendarEngine()
        _ = e.createDeadline(year: e.year, month: 6, day: 2, hour: 4, title: "Ship", color: "red")
        e.viewport = Viewport(w: 1200, h: 800)
        return MidDeadlinesCanvas(input: e.snapshotInput(), deadlines: e.viewDeadlines(),
                                  selected: nil, drawerOpen: false, hovered: nil,
                                  sceneDX: 0, theme: Theme(dark: false))
    }

    private func with(_ c: MidDeadlinesCanvas, deadlines: [Deadline]? = nil, selected: String?? = nil,
                      hovered: String?? = nil) -> MidDeadlinesCanvas {
        MidDeadlinesCanvas(input: c.input, deadlines: deadlines ?? c.deadlines,
                           selected: selected ?? c.selected, drawerOpen: c.drawerOpen,
                           hovered: hovered ?? c.hovered, only: c.only, hide: c.hide,
                           sceneDX: c.sceneDX, theme: c.theme)
    }

    func testUnchangedInputsCompareEqual() {
        let a = makeCanvas()
        XCTAssertEqual(a, with(a), "identical inputs must NOT re-record (perf contract)")
    }

    func testMovedDeadlineBreaksEquality() {
        let a = makeCanvas()
        var moved = a.deadlines
        moved[0].hour += 2 // the label drag: same id, new time
        XCTAssertNotEqual(a, with(a, deadlines: moved),
                          "a moved deadline MUST re-record the canvas — this froze the line in 2026-09")
    }

    func testActivationChangesBreakEquality() {
        let a = makeCanvas()
        let id = a.deadlines[0].id
        XCTAssertNotEqual(a, with(a, selected: id), "selection styling is drawn by the canvas")
        XCTAssertNotEqual(a, with(a, hovered: id), "hover styling is drawn by the canvas")
    }
}
