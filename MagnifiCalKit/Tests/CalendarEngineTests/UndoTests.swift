@testable import CalendarEngine
import XCTest

@MainActor
final class UndoTests: XCTestCase {
    /// Hermetic store: redirect ItemStore to a throwaway dir (the CC_DEMO_DATADIR hook), so the
    /// engine seeds its demo events deterministically instead of loading the REAL user calendar —
    /// these tests need items.events and must not depend on (or touch) live data.
    override func setUp() {
        super.setUp()
        setenv("CC_DEMO_DATADIR", NSTemporaryDirectory() + "cc-undo-tests-" + UUID().uuidString, 1)
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    /// A fresh install starts EMPTY by design (no placeholder seeds), so each test creates the
    /// event it edits through the engine's own CRUD.
    private func makeEngineWithEvent() -> (CalendarEngine, String) {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: e.year, month: e.focus, day: 10, startHour: 9, endHour: 10,
                                    title: "Original", color: "blue")
        return (e, id)
    }

    /// Does an engine-level title edit land on the undo stack and revert on undo()?
    func testTitleEditIsUndoable() {
        let (e, id) = makeEngineWithEvent()

        e.update(id) { $0.title = "ZZZ Renamed" }
        XCTAssertEqual(e.event(id)?.title, "ZZZ Renamed", "edit applied")

        e.undo()
        XCTAssertEqual(e.event(id)?.title, "Original", "undo should restore the pre-edit title")

        e.redo()
        XCTAssertEqual(e.event(id)?.title, "ZZZ Renamed", "redo should re-apply the edit")
    }

    /// Live-typed edits (one engine.update per keystroke, coalesced) should undo as ONE step.
    func testTypingBurstCoalescesToOneUndo() {
        let (e, id) = makeEngineWithEvent()

        for s in ["N", "Ne", "New", "New ", "New T"] {
            e.update(id) { $0.title = s }
        }
        XCTAssertEqual(e.event(id)?.title, "New T")

        e.undo()
        XCTAssertEqual(e.event(id)?.title, "Original", "one undo should revert the whole typing burst")
    }
}
