// ProjIndex — the projects/gantt model port. Semantics under test: row membership (top-level
// @project todos only), the bar origin chain (start: shadows created: shadows the source day),
// explicit-due-only hatching input, band event bars (series + per-occurrence), deadline
// milestones, and the active-in-range filter.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

final class ProjIndexTests: XCTestCase {
    private let today = "2026-07-30"

    func testBuildRowsBarsAndMilestones() {
        let sources = [
            TodoSource(id: "ev1", kind: "timed", title: "Sync", color: "blue", tags: [],
                       start: "2026-07-10T10:00:00", end: "2026-07-10T11:00:00",
                       notes: """
                       - [ ] row from source day @project:alpha
                       - [ ] shadowed start:2026-07-20 created:2026-07-12 @project:alpha
                       - [x] finished due:2026-07-14 done:2026-07-18T12:00 @project:alpha
                         - [ ] sub-item never a row @project:alpha
                       - [ ] no explicit due @project:alpha
                       """),
            TodoSource(id: "band1", kind: "band", title: "Retreat", color: "green", tags: [],
                       start: "2026-08-01", end: "2026-08-03",
                       notes: "@project:alpha",
                       occurrenceNotes: ["band1@2026-8-10": "@project:alpha"]),
            TodoSource(id: "dl1", kind: "deadline", title: "CFP", color: "red", tags: [],
                       start: "2026-08-20T23:59:00", end: "2026-08-20T23:59:00",
                       notes: "@project:alpha\n- [ ] prep the abstract @project:alpha"),
        ]
        let deadlines = [Deadline(id: "dl1", year: 2026, month: 7, day: 20, hour: 23.98,
                                  title: "CFP", color: "red")]
        let todos = TodoIndex.indexTodos(sources, today: today)
        let projects = ProjIndex.build(todos: todos, sources: sources, deadlines: deadlines,
                                       today: today)
        XCTAssertEqual(projects.count, 1)
        let p = projects[0]
        XCTAssertEqual(p.key, "alpha")
        // Rows: 4 top-level event-note todos + 1 from the deadline's note; the sub-item is not a row.
        XCTAssertEqual(p.tasks.count, 5)
        let byText = Dictionary(uniqueKeysWithValues: p.tasks.map { ($0.todo.text, $0) })
        XCTAssertEqual(byText["row from source day"]?.start, "2026-07-10")
        XCTAssertEqual(byText["shadowed"]?.start, "2026-07-20") // start: beats created: and the day
        XCTAssertEqual(byText["finished"]?.end, "2026-07-18")
        XCTAssertEqual(byText["finished"]?.due, "2026-07-14") // explicit due survives
        XCTAssertNil(byText["no explicit due"]?.due) // inherited due must NOT hatch
        // Event bars: the series note + the tagged occurrence (0-based month key → Sep 10, +2d span).
        XCTAssertEqual(p.events.count, 2)
        XCTAssertEqual(p.events.map(\.start).sorted(), ["2026-08-01", "2026-09-10"])
        XCTAssertEqual(p.events.map(\.end).sorted(), ["2026-08-03", "2026-09-12"])
        XCTAssertEqual(p.deadlines.map(\.id), ["dl1"])
    }

    func testProjHideExcludesTaskFromFeed() {
        let src = [TodoSource(id: "e1", kind: "timed", title: "T", color: "blue", tags: [],
                              start: "2026-07-10T09:00:00", end: "2026-07-10T10:00:00",
                              notes: """
                              - [ ] visible @project:alpha
                              - [ ] hidden #proj-hide @project:alpha
                              - [ ] only-hidden #proj-hide @project:beta
                              """)]
        let todos = TodoIndex.indexTodos(src, today: today)
        XCTAssertEqual(todos.count, 3) // the TODO tab still carries all three rows
        let projects = ProjIndex.build(todos: todos, sources: src, deadlines: [], today: today)
        // The hidden row is excluded from rows/counts; a project with ONLY hidden rows vanishes.
        XCTAssertEqual(projects.map(\.key), ["alpha"])
        XCTAssertEqual(projects[0].tasks.map(\.todo.text), ["visible"])
    }

    func testShownFiltersByRangeActivity() {
        let src = [TodoSource(id: "e", kind: "timed", title: "T", color: "red", tags: [],
                              start: "2026-07-01T09:00:00", end: "2026-07-01T10:00:00",
                              notes: "- [x] old done:2026-06-10T09:00 created:2026-06-01 @project:stale")]
        let todos = TodoIndex.indexTodos(src, today: today)
        let projects = ProjIndex.build(todos: todos, sources: src, deadlines: [], today: today)
        // Active in June, not in late July.
        XCTAssertEqual(ProjIndex.shown(projects, rs: "2026-06-01", re: "2026-06-30").count, 1)
        XCTAssertEqual(ProjIndex.shown(projects, rs: "2026-07-20", re: "2026-07-27").count, 0)
    }

    func testChartRowsPinnedFloatAboveByCreatedDesc() {
        let src = [TodoSource(id: "e", kind: "timed", title: "T", color: "red", tags: [],
                              start: "2026-07-01T09:00:00", end: "2026-07-01T10:00:00",
                              notes: """
                              - [ ] old created:2026-07-02 @project:p
                              - [ ] older-pin #proj-pinned created:2026-07-05 @project:p
                              - [ ] newer-pin #proj-pinned created:2026-07-20 @project:p
                              - [ ] stampless-pin #proj-pinned @project:p
                              - [ ] recent created:2026-07-10 @project:p
                              """)]
        let todos = TodoIndex.indexTodos(src, today: today)
        let p = ProjIndex.build(todos: todos, sources: src, deadlines: [], today: today)[0]
        // Pinned first (newest created: on top, stampless last among them), then the
        // unpinned rows in their unchanged chronological start order.
        XCTAssertEqual(ProjIndex.chartRows(p.tasks).map(\.todo.text),
                       ["newer-pin", "older-pin", "stampless-pin", "old", "recent"])
    }

    /// Golden: the pure-integer daysBetween must agree with Foundation's Calendar everywhere —
    /// leap years, century rules, month/year boundaries, negatives, and THH:MM suffixes.
    func testDaysBetweenMatchesCalendar() {
        func calendarDays(_ a: String, _ b: String) -> Int {
            func date(_ s: String) -> Date {
                let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
                return utcCalendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
            }
            return utcCalendar.dateComponents([.day], from: date(a), to: date(b)).day!
        }
        let anchors = ["2024-02-28", "2024-02-29", "2024-03-01", "2025-12-31", "2026-01-01",
                       "2026-07-31", "2026-08-02", "2000-02-29", "2100-02-28", "1999-12-31"]
        for a in anchors {
            for off in [-800, -365, -31, -1, 0, 1, 28, 29, 30, 31, 365, 366, 1000] {
                let b = TodoIndex.addDuration(a, off, "d")
                XCTAssertEqual(ProjIndex.daysBetween(a, b), calendarDays(a, b), "\(a) → \(b)")
                XCTAssertEqual(ProjIndex.daysBetween(b, a), calendarDays(b, a), "\(b) → \(a)")
            }
        }
        XCTAssertEqual(ProjIndex.daysBetween("2026-08-01T09:30", "2026-08-02T23:00"), 1)
        XCTAssertEqual(ProjIndex.daysBetween("garbage", "2026-08-02"), 0)
    }

    /// Golden: the pure JDN day/week adds must match Calendar's day arithmetic exactly.
    func testAddDurationDayWeekMatchesCalendar() {
        func calendarAdd(_ iso: String, _ days: Int) -> String {
            let p = iso.split(separator: "-").compactMap { Int($0) }
            let d = utcCalendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
            let m = utcCalendar.date(byAdding: .day, value: days, to: d)!
            let o = utcCalendar.dateComponents([.year, .month, .day], from: m)
            return String(format: "%04d-%02d-%02d", o.year!, o.month!, o.day!)
        }
        let anchors = ["2024-02-28", "2024-02-29", "2025-12-31", "2026-01-01", "2026-08-02",
                       "2000-02-29", "2100-02-28", "1999-12-31"]
        for a in anchors {
            for n in [-731, -366, -30, -1, 0, 1, 27, 30, 365, 1000] {
                XCTAssertEqual(TodoIndex.addDuration(a, n, "d"), calendarAdd(a, n), "\(a) + \(n)d")
                XCTAssertEqual(TodoIndex.addDuration(a, n, "w"), calendarAdd(a, n * 7), "\(a) + \(n)w")
            }
        }
        XCTAssertEqual(TodoIndex.addDuration("garbage", 3, "d"), "garbage")
    }
}
