// PROJ-panel performance investigation bench (not a correctness test): times each stage of the
// native PROJ pipeline over a synthetic dataset sized like a heavy real database, printing a
// stage-by-stage breakdown. Run with `swift test -c release --filter ProjPerfBench` for numbers
// comparable to a shipping build; debug numbers are several× worse but rank the same.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class ProjPerfBench: XCTestCase {
    private func ms(_ t0: Date) -> String {
        String(format: "%7.2fms", -t0.timeIntervalSinceNow * 1000)
    }

    func testStageBreakdown() {
        // ── Synthetic dataset: ~1 busy year ─────────────────────────────────────────────
        let today = "2026-08-02"
        var sources: [TodoSource] = []
        for i in 0 ..< 150 { // timed events, notes with todos (some project-tagged)
            let d = TodoIndex.addDuration("2026-01-05", i * 2, "d")
            sources.append(TodoSource(
                id: "ev\(i)", kind: "timed", title: "Meeting \(i)", color: "blue",
                tags: i % 3 == 0 ? ["work"] : [],
                start: "\(d)T10:00:00", end: "\(d)T11:00:00",
                notes: """
                - [ ] prep the agenda for #standup due:\(d) p:!!
                - [x] send notes to @alice done:\(d)T12:00 created:\(d)T08:00
                - [ ] follow up with @bob about the [doc](https://example.com/d/\(i)) @project:proj\(i % 12)
                - [ ] book the room start:\(d)
                """
            ))
        }
        for i in 0 ..< 30 { // bands, some with bare @project lines + occurrence notes
            let s = TodoIndex.addDuration("2026-02-01", i * 9, "d")
            sources.append(TodoSource(
                id: "band\(i)", kind: "band", title: "Trip \(i)", color: "green", tags: [],
                start: s, end: TodoIndex.addDuration(s, 3, "d"),
                notes: i % 2 == 0 ? "@project:proj\(i % 12)\n- [ ] pack" : "- [ ] pack",
                occurrenceNotes: i % 5 == 0 ? ["band\(i)@2026-3-\(i % 27 + 1)": "@project:proj\(i % 12)"] : nil
            ))
        }
        for i in 0 ..< 25 { // deadlines with project milestone lines
            let d = TodoIndex.addDuration("2026-03-01", i * 11, "d")
            sources.append(TodoSource(
                id: "dl\(i)", kind: "deadline", title: "Deadline \(i)", color: "red", tags: [],
                start: "\(d)T23:59:00", end: "\(d)T23:59:00",
                notes: "@project:proj\(i % 12)\n- [ ] final check due:\(d)"
            ))
        }
        var notes: [String: String] = [:] // 300 daily + 52 weekly + 12 monthly notes
        for i in 0 ..< 300 {
            let d = TodoIndex.addDuration("2025-10-01", i, "d")
            notes[d] = """
            Some prose about the day. Not a task.
            - [ ] daily thing #chore created:\(d)T09:00
            - [ ] tagged work item @project:proj\(i % 12) due:\(TodoIndex.addDuration(d, 7, "d"))
                - [ ] a nested subtask
            - [x] finished item done:\(d)T18:00
            More prose. [A link](https://example.com/\(i)).
            """
        }
        for i in 0 ..< 52 {
            notes["week:\(TodoIndex.addDuration("2025-10-05", i * 7, "d"))"] =
                "- [ ] weekly review @project:proj\(i % 12)\n- [ ] plan the week p:!"
        }
        for m in 1 ... 12 {
            notes[String(format: "month:2026-%02d", m)] = "- [ ] monthly goals @project:proj\(m % 12)"
        }

        // ── Stage 1: tokenize event sources (TodoIndex.indexTodos) ──────────────────────
        var t0 = Date()
        var todos = TodoIndex.indexTodos(sources, today: today)
        print("BENCH indexTodos(\(sources.count) sources) → \(todos.count) todos: \(ms(t0))")

        // ── Stage 2: + all daily/weekly/monthly notes (the rest of buildTodoFeed) ───────
        t0 = Date()
        for (key, text) in notes.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("week:") || key.hasPrefix("month:") {
                todos.append(contentsOf: TodoIndex.parseDailyNoteTodos(date: today, notes: text, today: today))
            } else {
                todos.append(contentsOf: TodoIndex.parseDailyNoteTodos(date: key, notes: text, today: today))
            }
        }
        print("BENCH parse \(notes.count) notes → \(todos.count) total todos: \(ms(t0))")

        // ── Stage 3: ProjIndex.build ────────────────────────────────────────────────────
        t0 = Date()
        let projects = ProjIndex.build(todos: todos, sources: sources, deadlines: [], today: today)
        print("BENCH ProjIndex.build → \(projects.count) projects, " +
            "\(projects.map(\.tasks.count).reduce(0, +)) tasks: \(ms(t0))")

        // ── Stage 4: the frozenOrder sort (taskScore per comparison, like the panel) ────
        t0 = Date()
        var rankedCount = 0
        for p in projects {
            let ranked = p.tasks.sorted {
                ProjIndex.taskScore($0, today: today) > ProjIndex.taskScore($1, today: today)
            }
            rankedCount += ranked.count
        }
        print("BENCH frozenOrder sort (score per comparison, \(rankedCount) tasks): \(ms(t0))")

        // Same sort with scores precomputed once — the candidate fix.
        t0 = Date()
        for p in projects {
            let scored = p.tasks.map { (ProjIndex.taskScore($0, today: today), $0) }
            _ = scored.sorted { $0.0 > $1.0 }
        }
        print("BENCH frozenOrder sort (score precomputed): \(ms(t0))")

        // ── Stage 5: daysBetween unit cost (ChartScale.x calls this per bar/tick/frame) ─
        let dates = (0 ..< 200).map { TodoIndex.addDuration("2026-06-01", $0, "d") }
        t0 = Date()
        var acc = 0
        for i in 0 ..< 10000 {
            acc += ProjIndex.daysBetween("2026-01-01", dates[i % 200])
        }
        print("BENCH daysBetween ×10k (acc \(acc)): \(ms(t0))")

        // ── Stage 6: a render's worth of x() math — ~120 date projections per project,
        // half through an addDuration (end-day-inclusive spans, axis tick generation).
        t0 = Date()
        for _ in 0 ..< 10 { // 10 projects on screen
            for i in 0 ..< 120 {
                let iso = i % 2 == 0 ? dates[i % 200] : TodoIndex.addDuration(dates[i % 200], 1, "d")
                _ = ProjIndex.daysBetween("2026-01-01", iso)
            }
        }
        print("BENCH one PROJ render's projection math (10 proj × 120 x()): \(ms(t0))")
    }
}
