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

    func testTaskLinePartsAndReplaceRest() throws {
        // taskLineParts: head keeps indent + marker + state; rest drops the one separating space.
        let parts = try XCTUnwrap(TodoIndex.taskLineParts("  - [x] ship it #tag done:2026-09-01"))
        XCTAssertEqual(parts.head, "  - [x] ")
        XCTAssertEqual(parts.rest, "ship it #tag done:2026-09-01")
        XCTAssertNil(TodoIndex.taskLineParts("prose line"))

        // replaceTodoRest: rest swapped, indent + checked state preserved; other lines untouched.
        let note = "- [ ] a\n  - [x] old text done:2026-07-01\nprose"
        XCTAssertEqual(TodoIndex.replaceTodoRest(note, line: 2, rest: "new text p:!!"),
                       "- [ ] a\n  - [x] new text p:!!\nprose")
        // Whitespace-only rest is a no-op (the editor treats it as cancel), same-note contract.
        XCTAssertEqual(TodoIndex.replaceTodoRest(note, line: 2, rest: "   "), note)
        // Stale anchors: not a task line / line gone.
        XCTAssertNil(TodoIndex.replaceTodoRest(note, line: 3, rest: "x"))
        XCTAssertNil(TodoIndex.replaceTodoRest(note, line: 9, rest: "x"))
    }

    func testInsertSubTodo() {
        // New child directly under the parent, ABOVE existing sub-items, one indent step deeper.
        let note = "- [ ] parent\n  - [ ] old child\nprose"
        XCTAssertEqual(TodoIndex.insertSubTodo(note, line: 1, text: "work on..."),
                       "- [ ] parent\n  - [ ] work on...\n  - [ ] old child\nprose")
        // Under an already-nested parent: its indent + 2.
        XCTAssertEqual(TodoIndex.insertSubTodo(note, line: 2, text: "x"),
                       "- [ ] parent\n  - [ ] old child\n    - [ ] x\nprose")
        // Stale anchors: not a task line / line gone.
        XCTAssertNil(TodoIndex.insertSubTodo(note, line: 3, text: "x"))
        XCTAssertNil(TodoIndex.insertSubTodo(note, line: 9, text: "x"))
    }

    func testInsertSiblingTodo() {
        let note = "- [ ] a\n  - [ ] child\n    - [ ] grandchild\nprose"
        // Top-level sibling lands BELOW the whole subtree (children stay attached to `a`),
        // same (empty) indent, created: stamp appended.
        XCTAssertEqual(TodoIndex.insertSiblingTodo(note, line: 1, text: "work on...", stamp: "2026-09-12T10:00"),
                       "- [ ] a\n  - [ ] child\n    - [ ] grandchild\n"
                           + "- [ ] work on... created:2026-09-12T10:00\nprose")
        // Nested sibling: below the child's own subtree, its indent, NO stamp (children stay bare).
        XCTAssertEqual(TodoIndex.insertSiblingTodo(note, line: 2, text: "x", stamp: "2026-09-12T10:00"),
                       "- [ ] a\n  - [ ] child\n    - [ ] grandchild\n  - [ ] x\nprose")
        XCTAssertNil(TodoIndex.insertSiblingTodo(note, line: 4, text: "x"))
    }

    func testSubtreeEnd() {
        let note = "- [ ] a\n  - [ ] child\n    - [ ] grandchild\n- [ ] b"
        XCTAssertEqual(TodoIndex.subtreeEnd(note, line: 1), 3) // a's subtree runs through grandchild
        XCTAssertEqual(TodoIndex.subtreeEnd(note, line: 2), 3) // child's subtree = the grandchild
        XCTAssertEqual(TodoIndex.subtreeEnd(note, line: 4), 4) // b is a leaf
    }

    func testSubtreeEndIncludesNonTaskContent() {
        // Deeper-indented PLAIN bullets/notes belong to the subtree too — a sibling insert
        // must never split an item from its attached prose (the PLDI reimbursement bug).
        let note = """
        - [ ] Reimburse PLDI #reimbursement created:2026-08-08T20:42
          - [ ] Do it now!!!!!!
          - [ ] Understand JHU reimbursement process p:!!! due:2026-07-24 #reimbursement
            - System: **SAP Concur** — log in via [the portal](https://portal.example.edu)
            - Submit within **90 days of June 20** → deadline ~Sept 18
            - No receipt needed for expenses under $75
        - [ ] next top-level
        """
        XCTAssertEqual(TodoIndex.subtreeEnd(note, line: 1), 6) // through the prose bullets
        XCTAssertEqual(TodoIndex.subtreeEnd(note, line: 3), 6) // the child owns its notes
        let out = TodoIndex.insertSiblingTodo(note, line: 1, text: "work on...")
        XCTAssertEqual(out?.components(separatedBy: "\n")[6], "- [ ] work on...")
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

    func testStampCreatedStampsOnlyUnstampedTopLevelTasks() throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: 14, minute: 30
        )))
        let note = """
        # Plan
        - [ ] new todo
        - [x] already stamped created:2026-09-01T10:00
          - [ ] sub-task stays untouched
        plain prose line
        - [ ] trailing spaces trimmed\u{20}\u{20}
        """
        let out = TodoIndex.stampCreated(note, now: now)
        let rows = out.components(separatedBy: "\n")
        XCTAssertEqual(rows[1], "- [ ] new todo created:2026-09-07T14:30")
        XCTAssertEqual(rows[2], "- [x] already stamped created:2026-09-01T10:00")
        XCTAssertEqual(rows[3], "  - [ ] sub-task stays untouched")
        XCTAssertEqual(rows[4], "plain prose line")
        XCTAssertEqual(rows[5], "- [ ] trailing spaces trimmed created:2026-09-07T14:30")
        // Idempotent: a second pass changes nothing.
        XCTAssertEqual(TodoIndex.stampCreated(out, now: now), out)
        // No tasks → the text comes back byte-identical.
        XCTAssertEqual(TodoIndex.stampCreated("just prose\n", now: now), "just prose\n")
    }
}
