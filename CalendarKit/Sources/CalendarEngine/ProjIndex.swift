// The PROJECTS index — the Swift port of dashboard.ts ensureProjects/projScore (webview
// retirement phase 2). A project is everything tagged @project:<key>: top-level todos become
// chart ROWS, band events with a bare `@project:<key>` note line become EVENT BARS (per tagged
// occurrence for recurring bands), deadlines with one become MILESTONE rules. Pure functions;
// the engine caches the built list per (editGen, noteGen, today).

import CalendarGeometry // Deadline, utcCalendar
import Foundation

public struct ProjTask: Sendable {
    public var todo: ParsedTodo
    public var start: String // bar origin: start: ?? created: ?? the source item's day
    public var end: String? // done day; nil = open (extends to now)
    public var due: String? // an EXPLICIT line due: only (inherited dates would false-hatch)
    public var color: String
}

public struct ProjEventBar: Sendable {
    public var id: String
    public var title: String
    public var color: String
    public var start: String
    public var end: String
}

public struct Project: Sendable {
    public var key: String
    public var tasks: [ProjTask]
    public var events: [ProjEventBar]
    public var deadlines: [Deadline]
    public var lastActivity: String // max(done ?? start) — feeds the relevance score
}

public enum ProjIndex {
    public static let maxRows = 8

    /// Days from a to b (wall-clock; negative when b < a). Pure integer civil-date arithmetic
    /// (Julian Day Number, proleptic Gregorian): the Calendar-based version cost ~6.6µs/call
    /// through DateComponents+Date and dominated every chart render and relevance-score sort
    /// (this sits under ChartScale.x for every bar/tick and under task/project scoring).
    public static func daysBetween(_ a: String, _ b: String) -> Int {
        guard let da = dayNumber(a), let db = dayNumber(b) else { return 0 }
        return db - da
    }

    /// "YYYY-MM-DD[…]"→ its Julian Day Number; nil on malformed input.
    static func dayNumber(_ s: String) -> Int? {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        let a = (14 - p[1]) / 12
        let y = p[0] + 4800 - a
        let m = p[1] + 12 * a - 3
        return p[2] + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    /// Julian Day Number → "YYYY-MM-DD" (the exact inverse of dayNumber).
    static func isoFromDayNumber(_ jdn: Int) -> String {
        let a = jdn + 32044
        let b = (4 * a + 3) / 146_097
        let c = a - 146_097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        let day = e - (153 * m + 2) / 5 + 1
        let month = m + 3 - 12 * (m / 10)
        let year = 100 * b + d - 4800 + m / 10
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Bare `@project:<key>` LINES in a note (the whole trimmed line, nothing else on it).
    static func noteProjectKeys(_ text: String?) -> [String] {
        guard let text, text.contains("@project:") else { return [] }
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("@project:") else { continue }
            let k = String(l.dropFirst("@project:".count)).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, !out.contains(k) {
                out.append(k)
            }
        }
        return out
    }

    /// Build the sorted project list from the parsed feed + the raw sources + deadlines.
    public static func build(todos: [ParsedTodo], sources: [TodoSource],
                             deadlines: [Deadline], today: String) -> [Project] {
        var map: [String: Project] = [:]
        var order: [String] = []
        func with(_ k: String, _ mutate: (inout Project) -> Void) {
            if map[k] == nil {
                map[k] = Project(key: k, tasks: [], events: [], deadlines: [], lastActivity: "")
                order.append(k)
            }
            mutate(&map[k]!)
        }
        // Rows: every TOP-LEVEL todo tagged @project:<key>, from any note source. created: absent
        // → the source item's own day; `start:` SHADOWS created: as the bar origin. #proj-hide
        // rows (the row menu's "Hide from Project Panel") are excluded HERE, before scoring, so
        // they never count toward scores/counts/rows — they remain in the TODO tab untouched.
        let srcById = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in todos where t.indent == 0 && !t.projects.isEmpty && !t.tags.contains("proj-hide") {
            var fallback = today, color = "blue"
            if t.source == "event" {
                if let ev = srcById[t.eventId] {
                    fallback = String(ev.start.prefix(10)); color = ev.color.isEmpty ? "blue" : ev.color
                }
            } else if let d = t.dailyDate {
                fallback = d.hasPrefix("week:") ? String(d.dropFirst(5))
                    : d.hasPrefix("month:") ? "\(d.dropFirst(6))-01" : d
            }
            let startTok = t.start.map { String($0.prefix(10)) } ?? ""
            let createdTok = t.created.map { String($0.prefix(10)) } ?? ""
            let start = !startTok.isEmpty ? startTok : (!createdTok.isEmpty ? createdTok : fallback)
            let doneDay = t.doneDate.map { String($0.prefix(10)) } ?? ""
            let task = ProjTask(
                todo: t, start: start,
                end: t.done ? (doneDay.isEmpty ? start : doneDay) : nil,
                due: t
                    .dueSource == "line" ? (t.due.map { String($0.prefix(10)) }.flatMap { $0.isEmpty ? nil : $0 }) :
                    nil,
                // An explicit line `color:` token (the row menu's palette) beats the
                // source-inherited color, so a pick recolors the bar immediately.
                color: (t.colorSource == "line" ? t.color : nil) ?? color
            )
            for k in t.projects {
                with(k) { $0.tasks.append(task) }
            }
        }
        // Event bars: BAND events with a bare @project line — the series note, or per tagged
        // occurrence ("<id>@Y-M-D", 0-based month) at its own dates spanning the band's length.
        for ev in sources where ev.kind == "band" {
            let s0 = String(ev.start.prefix(10)), e0 = String(ev.end.prefix(10))
            let spanDays = max(0, daysBetween(s0, e0))
            for k in noteProjectKeys(ev.notes) {
                with(k) { $0.events.append(ProjEventBar(
                    id: ev.id, title: ev.title, color: ev.color.isEmpty ? "blue" : ev.color,
                    start: s0, end: e0
                )) }
            }
            for (okey, note) in (ev.occurrenceNotes ?? [:]).sorted(by: { $0.key < $1.key }) {
                let keys = noteProjectKeys(note)
                guard !keys.isEmpty else { continue }
                var os = s0
                if let at = okey.firstIndex(of: "@") {
                    let p = okey[okey.index(after: at)...].split(separator: "-").compactMap { Int($0) }
                    if p.count == 3 {
                        os = String(format: "%04d-%02d-%02d", p[0], p[1] + 1, p[2])
                    }
                }
                let oe = TodoIndex.addDuration(os, spanDays, "d")
                for k in keys {
                    with(k) { $0.events.append(ProjEventBar(
                        id: ev.id, title: ev.title, color: ev.color.isEmpty ? "blue" : ev.color,
                        start: os, end: oe
                    )) }
                }
            }
        }
        // Milestones: a DEADLINE whose note carries a bare @project line.
        let dlById = Dictionary(deadlines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for ev in sources where ev.kind == "deadline" {
            let keys = noteProjectKeys(ev.notes)
            guard !keys.isEmpty, let dl = dlById[ev.id] else { continue }
            for k in keys {
                with(k) { $0.deadlines.append(dl) }
            }
        }
        for k in order {
            map[k]!.lastActivity = map[k]!.tasks.reduce("") { acc, x in
                let d = x.end ?? x.start
                return d > acc ? d : acc
            }
        }
        // Deterministic relevance order with the key as a total-order tiebreak. Scores computed
        // once per project, not per comparison (each score walks the task list + does date math).
        return order.compactMap { map[$0] }
            .map { (score: projectScore($0, today: today), p: $0) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.p.key < $1.p.key }
            .map(\.p)
    }

    /// Project relevance: open-work pressure + activity recency (30d decay) + nearest upcoming
    /// deadline (21d decay). Transparent + additive; weights tunable in one place.
    public static func projectScore(_ p: Project, today: String) -> Double {
        var s = 0.0
        let open = p.tasks.filter { $0.end == nil }
        s += Double(min(4, open.count))
        for x in open {
            s += Double(min(3, x.todo.priority ?? 0)) / 3
        }
        if !p.lastActivity.isEmpty {
            s += 4 * exp(-Double(abs(daysBetween(p.lastActivity, today))) / 30)
        }
        for d in p.deadlines {
            let iso = String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)
            let dd = daysBetween(today, iso)
            if dd >= 0 {
                s += 3 * exp(-Double(dd) / 21)
            }
        }
        return s
    }

    /// In-project row relevance: open state, priority, activity recency, near/overdue due.
    public static func taskScore(_ x: ProjTask, today: String) -> Double {
        var s = 0.0
        if !x.todo.done {
            s += 4
        }
        s += Double(x.todo.priority ?? 0)
        let anchor = x.end ?? x.start
        if !anchor.isEmpty {
            s += 3 * exp(-Double(abs(daysBetween(anchor, today))) / 30)
        }
        if let due = x.due {
            let dd = daysBetween(today, due)
            if dd >= -30, dd <= 14 {
                s += 2
            }
        }
        return s
    }

    /// Gantt display order (the chart's row sequence): #proj-pinned rows float ABOVE the rest,
    /// newest `created:` first (ISO stamps compare as strings; a missing created: sinks last
    /// among the pinned); unpinned rows keep the chronological start order.
    public static func chartRows(_ tasks: [ProjTask]) -> [ProjTask] {
        let pinned = tasks.filter { $0.todo.tags.contains("proj-pinned") }
            .sorted { ($0.todo.created ?? "") > ($1.todo.created ?? "") }
        let rest = tasks.filter { !$0.todo.tags.contains("proj-pinned") }
            .sorted { $0.start < $1.start }
        return pinned + rest
    }

    /// Projects ACTIVE during [rs, re]: some task overlapping the range, or an event bar in it.
    public static func shown(_ projects: [Project], rs: String, re: String) -> [Project] {
        projects.filter { p in
            p.tasks.contains { $0.start <= re && ($0.end == nil || $0.end! >= rs) }
                || p.events.contains { $0.start <= re && $0.end >= rs }
        }
    }
}

extension CalendarEngine {
    /// The built project list, cached per (editGen, noteGen, today) like the todo feed — and,
    /// like it, gen-only staleness serves the STALE list and rebuilds once the coalesced feed
    /// refresh lands (projFeed keys off the CACHED feed's gens, so it settles one beat after).
    public func projFeed(today: String) -> [Project] {
        let feedGens = todoFeedCache.map { ($0.gen, $0.noteGen) } ?? (-1, -1)
        if let c = projFeedCache, c.today == today,
           c.gen == feedGens.0, c.noteGen == feedGens.1 {
            return c.projects
        }
        let dls = items.deadlines.map { displayDeadline($0) }
        let projects = ProjIndex.build(todos: todoFeed(today: today), sources: todoSources(),
                                       deadlines: dls, today: today)
        let gens = todoFeedCache.map { ($0.gen, $0.noteGen) } ?? (caches.editGen, caches.noteGen)
        projFeedCache = (gens.0, gens.1, today, projects)
        return projects
    }
}
