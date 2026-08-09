// TodoFeed sectioning — the Swift port of dashboard.ts sectionsForDay / rangeTodoSections.
// Semantics under test: day buckets (due-day / overdue / followup / high-soon / due-soon /
// recent-done window), the range sections' root PROMOTION rule (a qualifying open sub-item
// surfaces its root), the completed-minus-open exclusion, and layering-prefs filtering.

@testable import CalendarEngine
import XCTest

final class TodoFeedTests: XCTestCase {
    private let today = "2026-07-30"

    private func daily(_ text: String, date: String = "2026-07-30") -> [ParsedTodo] {
        TodoIndex.parseDailyNoteTodos(date: date, notes: text, today: today)
    }

    func testDaySections() {
        let todos = daily("""
        - [ ] due today due:today
        - [ ] overdue one due:2026-07-20
        - [ ] follow me followup:2026-08-02
        - [ ] high soon due:2026-08-03 p:!!!
        - [ ] low soon due:2026-08-03
        - [ ] far future due:2026-12-01
        - [ ] deferred start:2026-08-10 due:today
        - [x] finished done:2026-07-28T10:00
        - [x] finished long ago done:2026-06-01T10:00
        """)
        let secs = TodoFeed.sectionsForDay(todos, viewIso: today, today: today)
        let byKey = Dictionary(uniqueKeysWithValues: secs.map { ($0.key, $0) })
        XCTAssertEqual(byKey["dueDay"]?.title, "Today's Items")
        XCTAssertEqual(byKey["dueDay"]?.items.map(\.text), ["due today"])
        XCTAssertEqual(byKey["overdue"]?.items.map(\.text), ["overdue one"])
        XCTAssertEqual(byKey["followup"]?.items.map(\.text), ["follow me"])
        XCTAssertEqual(byKey["highSoon"]?.items.map(\.text), ["high soon"])
        XCTAssertEqual(byKey["dueSoon"]?.items.map(\.text), ["low soon"])
        // Recent-done window keeps the fresh completion, drops the June one; deferred and
        // far-future items appear nowhere.
        XCTAssertEqual(byKey["done"]?.items.map(\.text), ["finished"])
        let all = secs.flatMap { $0.items.map(\.text) }
        XCTAssertFalse(all.contains("deferred"))
        XCTAssertFalse(all.contains("far future"))
    }

    func testRangePromotionAndCompletedExclusion() {
        let todos = daily("""
        - [x] parent shown open done:2026-07-29T09:00
          - [ ] child in range due:2026-07-29
        - [x] plainly finished done:2026-07-28T12:00
        - [ ] out of range due:2026-09-09
        """, date: "2026-07-27")
        let secs = TodoFeed.rangeSections(todos, start: "2026-07-26", end: "2026-08-01",
                                          word: "this week", prefs: .week)
        let byKey = Dictionary(uniqueKeysWithValues: secs.map { ($0.key, $0) })
        // The open in-range CHILD promotes its (done) root into the open section…
        XCTAssertEqual(byKey["open"]?.items.map(\.text), ["parent shown open"])
        // …which then must NOT repeat under Completed, though its stamp is in range.
        XCTAssertEqual(byKey["done"]?.items.map(\.text), ["plainly finished"])
    }

    func testLayerPrefsFilter() {
        var todos = daily("- [ ] from the day note due:2026-07-30")
        todos.append(contentsOf: daily("- [ ] weekly item due:2026-07-30", date: "2026-07-26").map {
            var t = $0; t.dailyDate = "week:2026-07-26"; return t
        })
        let noWeekly = TodoFeedPrefs(sections: ["open", "done"], sources: ["event", "daily"])
        let secs = TodoFeed.rangeSections(todos, start: "2026-07-26", end: "2026-08-01",
                                          word: "this week", prefs: noWeekly)
        XCTAssertEqual(secs.first { $0.key == "open" }?.items.map(\.text), ["from the day note"])
    }

    func testSubtreeAndChildrenIndex() throws {
        let todos = daily("""
        - [ ] root a
          - [ ] child a1
            - [x] grandchild done:2026-07-30T08:00
        - [ ] root b
        """)
        let kids = TodoFeed.childrenIndex(todos)
        let rootA = try XCTUnwrap(todos.first { $0.text == "root a" })
        XCTAssertEqual(TodoFeed.subtree(rootA, kids).map(\.text),
                       ["root a", "child a1", "grandchild"])
    }

    func testPinnedSectionOnTopNewestCreatedFirst() {
        let todos = daily("""
        - [ ] alpha due:today #pinned created:2026-07-01T10:00
        - [ ] beta due:today #Pinned created:2026-07-20T10:00
        - [ ] gamma due:today #pinned
        - [ ] plain due:today
        """)
        let secs = TodoFeed.sectionsForDay(todos, viewIso: today, today: today)
        // The Pinned section leads the list: newest created: first, missing created: last
        // (ProjIndex.chartRows' pinned ordering); the tag match is case-insensitive.
        XCTAssertEqual(secs.first?.key, "pinned")
        XCTAssertEqual(secs.first?.title, "Pinned")
        XCTAssertEqual(secs.first?.items.map(\.text), ["beta", "alpha", "gamma"])
    }

    func testPinnedFloatIsAStablePartition() {
        let todos = daily("""
        - [ ] a1 due:2026-07-27
        - [ ] p1 due:2026-07-28 #pinned
        - [ ] a2 due:2026-07-29
        - [ ] p2 due:2026-07-30 #pinned
        """, date: "2026-07-27")
        let secs = TodoFeed.rangeSections(todos, start: "2026-07-26", end: "2026-08-01",
                                          word: "this week", prefs: .week)
        let open = secs.first { $0.key == "open" }
        // Pinned first, keeping their existing relative (due-date) order; the rest unchanged.
        XCTAssertEqual(open?.items.map(\.text), ["p1", "p2", "a1", "a2"])
    }

    func testPinnedItemsStayInTheirOtherSections() {
        let todos = daily("""
        - [ ] pinned overdue due:2026-07-20 #pinned
        - [ ] plain overdue due:2026-07-21
        """)
        let secs = TodoFeed.sectionsForDay(todos, viewIso: today, today: today)
        let byKey = Dictionary(uniqueKeysWithValues: secs.map { ($0.key, $0) })
        // Overlap is intended: the pinned item appears BOTH in Pinned and (floated to the
        // top of) its normal section.
        XCTAssertEqual(byKey["pinned"]?.items.map(\.text), ["pinned overdue"])
        XCTAssertEqual(byKey["overdue"]?.items.map(\.text), ["pinned overdue", "plain overdue"])
    }

    @MainActor func testEngineFeedCachesPerGen() {
        // A THROWAWAY store: without this the engine loads (and, past the 0.5s persist debounce,
        // could WRITE) the developer's real calendar. calendarKitBaseDir reads the env per call,
        // so setting it before the engine exists is sufficient; restored on exit.
        let tmp = NSTemporaryDirectory() + "todo-feed-test-\(UUID().uuidString)"
        setenv("CC_DEMO_DATADIR", tmp, 1)
        defer { unsetenv("CC_DEMO_DATADIR"); try? FileManager.default.removeItem(atPath: tmp) }
        let engine = CalendarEngine()
        engine.setDailyNote("2026-07-30", "- [ ] cached item due:today")
        let first = engine.todoFeed(today: today)
        XCTAssertEqual(first.map(\.text), ["cached item"])
        XCTAssertEqual(engine.todoFeed(today: today).map(\.text), first.map(\.text)) // cache hit
        engine.setDailyNote("2026-07-30", "- [ ] cached item due:today\n- [ ] second")
        // Serve-stale contract: a gen-only-stale read returns the OLD feed (the rebuild is
        // coalesced off the frame path); an explicit self-edit refresh lands the new parse.
        XCTAssertEqual(engine.todoFeed(today: today).count, 1)
        engine.todoFeedRefreshNow(today: today)
        XCTAssertEqual(engine.todoFeed(today: today).count, 2)
    }
}
