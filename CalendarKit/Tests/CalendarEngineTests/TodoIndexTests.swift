// TodoIndex (the Swift todo tokenizer/index) vs the golden vectors generated from the legacy web
// tokenizer (todos.ts) — scripts/gen-todo-vectors.sh wrote Fixtures/todo-vectors.json once; the
// Swift port must parse the same corpus to identical structures. Plus behavior tests for the
// soft-link write primitives (toggle / created-stamp scan) and the feed ordering.

@testable import CalendarEngine
import XCTest

final class TodoIndexTests: XCTestCase {
    // ── Golden vectors ─────────────────────────────────────────────────────────────────────────

    private struct Fixture: Decodable {
        struct Event: Decodable {
            var id: String, kind: String, title: String, color: String
            var tags: [String], start: String, end: String
            var originTz: String?
            var notes: String?
            var occurrenceNotes: [String: String]?
        }

        var today: String
        var events: [Event]
        var dailyNotes: [String: String]
    }

    private func loadFixture() throws -> (Fixture, [String: Any]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/todo-vectors",
                                                  withExtension: "json"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = try XCTUnwrap(root["expected"] as? [String: Any])
        return (fixture, expected)
    }

    private func sources(_ f: Fixture) -> [TodoSource] {
        f.events.map { e in
            TodoSource(id: e.id, kind: e.kind, title: e.title, color: e.color, tags: e.tags,
                       start: e.start, end: e.end, originTz: e.originTz,
                       notes: e.notes, occurrenceNotes: e.occurrenceNotes)
        }
    }

    /// Canonical identity for order-insensitive comparison (the JS sort tiebreaks with
    /// localeCompare, which the port intentionally does not reproduce).
    private func key(_ d: [String: Any]) -> String {
        let ev = d["eventId"] as? String ?? ""
        let occ = d["occurrenceKey"] as? String ?? ""
        let daily = d["dailyDate"] as? String ?? ""
        let line = d["line"] as? Int ?? 0
        return "\(ev)|\(occ)|\(daily)|\(String(format: "%04d", line))"
    }

    /// JS JSON carries explicit nulls for optional fields; Swift's Codable omits nil keys. Strip
    /// nulls so both sides compare on present values only.
    private func stripNulls(_ d: [String: Any]) -> [String: Any] {
        d.filter { !($0.value is NSNull) }
    }

    private func encode(_ todos: [ParsedTodo]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(todos)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func compare(_ actual: [ParsedTodo], _ expectedAny: Any?,
                         _ label: String) throws {
        let expected = try XCTUnwrap(expectedAny as? [[String: Any]], "\(label): expected array")
        let a = try encode(actual).sorted { key($0) < key($1) }
        let e = expected.map(stripNulls).sorted { key($0) < key($1) }
        XCTAssertEqual(a.count, e.count, "\(label): count")
        for (av, ev) in zip(a, e) {
            XCTAssertEqual(av as NSDictionary, ev as NSDictionary,
                           "\(label): mismatch at \(key(av)) — raw: \(av["raw"] ?? "?")")
        }
    }

    func testGoldenVectorsIndex() throws {
        let (fixture, expected) = try loadFixture()
        let actual = TodoIndex.indexTodos(sources(fixture), today: fixture.today)
        try compare(actual, expected["index"], "index")
    }

    func testGoldenVectorsDailyNotes() throws {
        let (fixture, expected) = try loadFixture()
        let daily = try XCTUnwrap(expected["daily"] as? [String: Any])
        for (date, notes) in fixture.dailyNotes {
            let actual = TodoIndex.parseDailyNoteTodos(date: date, notes: notes,
                                                       today: fixture.today)
            try compare(actual, daily[date], "daily[\(date)]")
        }
    }

    // ── Soft-link write primitives ─────────────────────────────────────────────────────────────

    func testToggleOnAppendsStampAndOffStripsIt() throws {
        let note = "- [ ] write tests due:2026-08-01\n- [x] old done:2026-07-01"
        let on = TodoIndex.toggleTodoLine(note, line: 1, stamp: "2026-07-30T10:00")
        XCTAssertEqual(on, "- [x] write tests due:2026-08-01 done:2026-07-30T10:00\n- [x] old done:2026-07-01")
        let off = try TodoIndex.toggleTodoLine(XCTUnwrap(on), line: 1)
        XCTAssertEqual(off, "- [ ] write tests due:2026-08-01\n- [x] old done:2026-07-01")
        // Unchecking line 2 strips its stale stamp too.
        XCTAssertEqual(TodoIndex.toggleTodoLine(note, line: 2), "- [ ] write tests due:2026-08-01\n- [ ] old")
    }

    func testToggleStaleAnchorAndNoOp() {
        let note = "- [ ] a\nprose line"
        XCTAssertNil(TodoIndex.toggleTodoLine(note, line: 2)) // not a task line
        XCTAssertNil(TodoIndex.toggleTodoLine(note, line: 9)) // line gone
        // Explicit set to the current state with no stamp change → the SAME text (no-op contract).
        XCTAssertEqual(TodoIndex.toggleTodoLine(note, line: 1, checked: false), note)
    }

    func testLinesNeedingCreated() {
        let note = """
        - [ ] no stamp
          - [ ] child never stamped
        - [ ] has one created:2026-07-01
        - [x] done no stamp
        """
        XCTAssertEqual(TodoIndex.linesNeedingCreated(note), [1, 4])
    }

    // ── PROJ quick-add (appendProjectTodo) ─────────────────────────────────────────────────────

    private let quickAddLine =
        "- [ ] new item @project:alpha created:2026-07-30T09:15 #proj-pinned"

    private func quickAdd(_ note: String, project: String = "alpha") -> String {
        TodoIndex.appendProjectTodo(note: note, project: project, todo: "new item",
                                    stamp: "2026-07-30T09:15")
    }

    func testAppendProjectTodoSectionWithList() {
        let note = """
        # alpha
        intro prose
        - [ ] one
        - [x] two done:2026-07-01
        tail prose
        """
        XCTAssertEqual(quickAdd(note), """
        # alpha
        intro prose
        - [ ] one
        - [x] two done:2026-07-01
        \(quickAddLine)
        tail prose
        """)
    }

    func testAppendProjectTodoSectionWithoutList() {
        let note = """
        # alpha
        just prose here

        # beta
        - [ ] beta item
        """
        XCTAssertEqual(quickAdd(note), """
        # alpha
        just prose here
        \(quickAddLine)

        # beta
        - [ ] beta item
        """)
    }

    func testAppendProjectTodoMissingSection() {
        XCTAssertEqual(quickAdd("# beta\n- [ ] b\n"),
                       "# beta\n- [ ] b\n\n# alpha\n\(quickAddLine)")
        XCTAssertEqual(quickAdd(""), "# alpha\n\(quickAddLine)") // empty note: no leading blank
        // `## alpha` is NOT a top-level section; case-insensitive fallback DOES match.
        XCTAssertEqual(quickAdd("## alpha\n- [ ] deep\n"),
                       "## alpha\n- [ ] deep\n\n# alpha\n\(quickAddLine)")
        XCTAssertEqual(quickAdd("# ALPHA\n- [ ] a"), "# ALPHA\n- [ ] a\n\(quickAddLine)")
        // Whitespace-only input is a no-op.
        XCTAssertEqual(TodoIndex.appendProjectTodo(note: "# alpha", project: "alpha",
                                                   todo: "   ", stamp: "s"), "# alpha")
    }

    func testAppendProjectTodoPicksLastList() {
        let note = """
        # alpha
        - [ ] first run

        notes between

        - [ ] second run
          - [x] nested done:2026-07-02
        trailing prose
        """
        XCTAssertEqual(quickAdd(note), """
        # alpha
        - [ ] first run

        notes between

        - [ ] second run
          - [x] nested done:2026-07-02
        \(quickAddLine)
        trailing prose
        """)
    }

    func testAppendProjectTodoSectionNotLast() {
        let note = """
        # alpha
        - [ ] a1

        # beta
        - [ ] b1
        """
        XCTAssertEqual(quickAdd(note), """
        # alpha
        - [ ] a1
        \(quickAddLine)

        # beta
        - [ ] b1
        """)
    }

    // ── Ordering ───────────────────────────────────────────────────────────────────────────────

    // ── One-line token rewrites (the PROJ row menu's pure parts) ───────────────────────────────

    func testSetColorTokenReplacesAndAppends() throws {
        let note = "- [ ] paint color:blue due:2026-08-01\n- [ ] plain"
        let replaced = try XCTUnwrap(TodoIndex.setColorToken(note, line: 1, color: "red"))
        XCTAssertEqual(replaced, "- [ ] paint color:red due:2026-08-01\n- [ ] plain")
        let appended = try XCTUnwrap(TodoIndex.setColorToken(note, line: 2, color: "green"))
        XCTAssertEqual(appended, "- [ ] paint color:blue due:2026-08-01\n- [ ] plain color:green")
        XCTAssertNil(TodoIndex.setColorToken("plain text", line: 1, color: "red")) // stale anchor
        // Same color again → the SAME note back (a no-op, not a new write).
        XCTAssertEqual(TodoIndex.setColorToken(note, line: 1, color: "blue"), note)
    }

    func testSetPriorityReplacesAndAppends() throws {
        let note = "- [ ] urgent p:!! #x\n- [ ] calm"
        let replaced = try XCTUnwrap(TodoIndex.setPriority(note, line: 1, level: 4))
        XCTAssertEqual(replaced, "- [ ] urgent p:!!!! #x\n- [ ] calm")
        let appended = try XCTUnwrap(TodoIndex.setPriority(note, line: 2, level: 1))
        XCTAssertEqual(appended, "- [ ] urgent p:!! #x\n- [ ] calm p:!")
        // Clamped to maxPriority, and a stale anchor is nil.
        XCTAssertEqual(TodoIndex.setPriority(note, line: 2, level: 9),
                       "- [ ] urgent p:!! #x\n- [ ] calm p:!!!!!")
        XCTAssertNil(TodoIndex.setPriority(note, line: 3, level: 1))
    }

    func testAddTagAppendsAndDedupes() throws {
        let note = "- [ ] item #proj-pinned\n- [ ] other"
        // Dedupe: already tagged → the SAME note back (case-insensitive), not a double tag.
        XCTAssertEqual(TodoIndex.addTag(note, line: 1, tag: "proj-pinned"), note)
        XCTAssertEqual(TodoIndex.addTag(note, line: 1, tag: "PROJ-PINNED"), note)
        let tagged = try XCTUnwrap(TodoIndex.addTag(note, line: 2, tag: "proj-hide"))
        XCTAssertEqual(tagged, "- [ ] item #proj-pinned\n- [ ] other #proj-hide")
        XCTAssertNil(TodoIndex.addTag(note, line: 5, tag: "proj-hide")) // stale anchor
    }

    func testRemovePriorityClearsToken() {
        XCTAssertEqual(TodoIndex.removePriority("- [ ] a p:!!! due:2026-08-09", line: 1),
                       "- [ ] a due:2026-08-09")
        XCTAssertEqual(TodoIndex.removePriority("- [ ] tail p:!", line: 1), "- [ ] tail")
        // No priority → the rewrite returns the note unchanged.
        XCTAssertEqual(TodoIndex.removePriority("- [ ] plain", line: 1), "- [ ] plain")
    }

    func testRemoveTagRemovesAndNoOps() {
        let note = "- [ ] ship it #proj-pinned due:2026-08-09\n- [ ] other"
        // Removes the tag (mid-line: the doubled space collapses with it).
        XCTAssertEqual(TodoIndex.removeTag(note, line: 1, tag: "proj-pinned"),
                       "- [ ] ship it due:2026-08-09\n- [ ] other")
        // Case-insensitive.
        XCTAssertEqual(TodoIndex.removeTag("- [ ] x #Proj-Pinned", line: 1, tag: "proj-pinned"),
                       "- [ ] x")
        // Absent tag → unchanged note (rewrite contract: same text returns the note as-is).
        XCTAssertEqual(TodoIndex.removeTag(note, line: 2, tag: "proj-pinned"), note)
        // Prefix tags survive (#proj-pinned-extra is a DIFFERENT tag; \\b guards the boundary).
        XCTAssertEqual(TodoIndex.removeTag("- [ ] x #proj-pinned-extra", line: 1, tag: "proj-pinned"),
                       "- [ ] x #proj-pinned-extra")
    }

    func testRemoveTodoLineKeepsChildren() throws {
        let note = "# proj\n- [ ] parent @project:p\n  - [ ] child stays\n- [ ] last"
        let removed = try XCTUnwrap(TodoIndex.removeTodoLine(note, line: 2))
        XCTAssertEqual(removed, "# proj\n  - [ ] child stays\n- [ ] last")
        XCTAssertNil(TodoIndex.removeTodoLine(note, line: 1)) // not a task line
        XCTAssertNil(TodoIndex.removeTodoLine(note, line: 9)) // line gone
    }

    func testFeedOrdering() {
        func todo(_ text: String, due: String? = nil, pri: Int? = nil,
                  done: Bool = false, active: Bool = true) -> ParsedTodo {
            ParsedTodo(raw: text, text: text, done: done, doneDate: nil, created: nil,
                       source: "daily", eventId: "", eventTitle: "", eventKind: "daily",
                       occurrenceKey: nil, dailyDate: "2026-07-30", line: 1, indent: 0,
                       parentLine: nil, priority: pri, due: due, dueTz: nil,
                       dueSource: "event", followup: nil, start: nil, active: active,
                       tags: [], people: [], projects: [], funding: [], entities: [:],
                       links: [], color: nil, colorSource: "event")
        }
        let sorted = [
            todo("undated"),
            todo("done", done: true, active: false),
            todo("later", due: "2026-08-02"),
            todo("soon-low", due: "2026-08-01", pri: 1),
            todo("soon-high", due: "2026-08-01", pri: 3),
        ].sorted(by: TodoIndex.orderedBefore)
        XCTAssertEqual(sorted.map(\.text),
                       ["soon-high", "soon-low", "later", "undated", "done"])
    }

    // ── Tokenizer spot checks (grammar corners the vectors also cover, kept close for triage) ──

    func testEmailNeverTokenizes() {
        let t = TodoIndex.tokenizeLine("email tommy@cs.jhu.edu stays text")
        XCTAssertEqual(t.text, "email tommy@cs.jhu.edu stays text")
        XCTAssertTrue(t.entities.isEmpty)
    }

    func testLinkContentsAreMasked() {
        let t = TodoIndex.tokenizeLine("read [the paper](https://example.com/p#frag) #real")
        XCTAssertEqual(t.tags, ["real"])
        XCTAssertEqual(t.links, [TodoLink(label: "the paper", url: "https://example.com/p#frag")])
    }
}
