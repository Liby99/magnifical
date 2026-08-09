// The TODO feed: sectioning + nesting over the TodoIndex — the Swift port of dashboard.ts's
// sectionsForDay / rangeTodoSections (webview retirement phase 1). Pure functions over
// [ParsedTodo]; the engine-side cached index lives in CalendarEngine+TodoFeed.
//
// Sectioning semantics (locked, matching the web dashboard):
//   DAY: Today's Items / Overdue / Remember to Followup / High Priority · Due Soon / Due Soon /
//        Recently Completed (a RECENT_DONE_DAYS window). Roots only; each root renders with its
//        full subtree.
//   RANGE (week/month): TODOs this week|month (open roots whose operative date falls in range —
//        a qualifying SUB-item promotes its root) / Completed this week|month (done roots by
//        done-stamp, newest first).

import Foundation

public struct TodoSection: Sendable {
    public var key: String // "dueDay" | "overdue" | "followup" | "highSoon" | "dueSoon" | "done" | "open"
    public var title: String
    public var items: [ParsedTodo] // ROOT todos only — render each with its subtree
    public var done: Bool
}

/// Per-scope layering prefs (mirrors DashTodoPrefs / the web's TodoPrefs): which SOURCES feed the
/// list, which COLLECTIONS (section keys) render, deadlines on/off.
public struct TodoFeedPrefs: Sendable {
    public var deadlines: Bool
    public var sections: [String]
    public var sources: [String] // "event" | "daily" | "weekly" | "monthly"
    public init(deadlines: Bool = true, sections: [String], sources: [String]) {
        self.deadlines = deadlines; self.sections = sections; self.sources = sources
    }

    public static let day = TodoFeedPrefs(
        sections: ["dueDay", "overdue", "followup", "highSoon", "dueSoon", "done"],
        sources: ["event", "daily"]
    )
    public static let week = TodoFeedPrefs(
        sections: ["open", "done"], sources: ["event", "daily", "weekly"]
    )
    public static let month = TodoFeedPrefs(
        sections: ["open", "done"], sources: ["event", "daily", "weekly", "monthly"]
    )
}

public enum TodoFeed {
    public static let highPriority = 3
    public static let soonDays = 7
    public static let followupWindow = 7
    public static let recentDoneDays = 7

    public static func dueDate(_ t: ParsedTodo) -> String {
        String((t.due ?? "").prefix(10))
    }

    /// The operative date: a followup acts as the due date when set.
    public static func opDate(_ t: ParsedTodo) -> String {
        t.followup ?? dueDate(t)
    }

    /// A fully deterministic identity so items tying on the primary keys keep a STABLE order:
    /// soft-link anchor, then LINE NUMBER (same-note ties keep source order — subtrees stay
    /// under their parents), then the raw line.
    public static func tieKey(_ t: ParsedTodo) -> String {
        "\(t.source)\0\(t.eventId)\0\(t.occurrenceKey ?? "")\0\(t.dailyDate ?? "")\0" +
            "\(String(format: "%06d", t.line))\0\(t.raw)"
    }

    /// Which layer a todo came from: event notes, or the note kind its dailyDate key encodes.
    public static func layer(_ t: ParsedTodo) -> String {
        if t.source == "event" {
            return "event"
        }
        let d = t.dailyDate ?? ""
        return d.hasPrefix("week:") ? "weekly" : d.hasPrefix("month:") ? "monthly" : "daily"
    }

    /// The note-scope identity a nesting parent/child share (source + event/occurrence or note key).
    public static func scopeKey(_ t: ParsedTodo) -> String {
        "\(t.source)\0\(t.eventId)\0\(t.occurrenceKey ?? "")\0\(t.dailyDate ?? "")"
    }

    /// #pinned (case-insensitive) — the TODO panel's pin tag (PROJ's is #proj-pinned).
    public static func isPinned(_ t: ParsedTodo) -> Bool {
        t.tags.contains { $0.lowercased() == "pinned" }
    }

    /// Either pin tag (#pinned / #proj-pinned) → the accent pin prefix in the NOTE PREVIEW
    /// (a note belongs to no one panel). The panels each show only their OWN tag's pin:
    /// #pinned in the TODO panel, #proj-pinned on the PROJ gantt labels.
    public static func hasPinTag(_ tags: [String]) -> Bool {
        tags.contains { let l = $0.lowercased(); return l == "pinned" || l == "proj-pinned" }
    }

    /// Layer the #pinned semantics over built sections: a "Pinned" section on TOP (every
    /// pinned todo in the pool, newest `created:` first, missing stamps last — mirroring
    /// ProjIndex.chartRows' pinned ordering), and within every OTHER section a STABLE
    /// partition floating pinned items first (their existing relative order kept, the rest
    /// unchanged). Pinned items stay members of their normal sections too — the overlap is
    /// intended. Exempt from the prefs.sections filter: pinning is an explicit per-item act.
    static func withPinned(_ sections: [TodoSection], pool: [ParsedTodo]) -> [TodoSection] {
        var out = sections.map { s in
            var s2 = s
            s2.items = s.items.filter(isPinned) + s.items.filter { !isPinned($0) }
            return s2
        }
        let pinned = pool.filter(isPinned).sorted { a, b in
            let ac = a.created ?? "", bc = b.created ?? ""
            return ac != bc ? ac > bc : tieKey(a) < tieKey(b)
        }
        if !pinned.isEmpty {
            out.insert(TodoSection(key: "pinned", title: "Pinned", items: pinned, done: false),
                       at: 0)
        }
        return out
    }

    /// Children grouped under their parent's (note-scope, line) soft link, in line order.
    public static func childrenIndex(_ todos: [ParsedTodo]) -> [String: [ParsedTodo]] {
        var idx: [String: [ParsedTodo]] = [:]
        for t in todos {
            guard let p = t.parentLine else { continue }
            idx["\(scopeKey(t))\0\(p)", default: []].append(t)
        }
        for k in idx.keys {
            idx[k]!.sort { $0.line < $1.line }
        }
        return idx
    }

    /// A root and all its descendants, in source order (parent first, then each child's subtree).
    public static func subtree(_ t: ParsedTodo, _ kids: [String: [ParsedTodo]]) -> [ParsedTodo] {
        var out: [ParsedTodo] = []
        func walk(_ n: ParsedTodo) {
            out.append(n)
            for c in kids["\(scopeKey(n))\0\(n.line)"] ?? [] {
                walk(c)
            }
        }
        walk(t)
        return out
    }

    /// Primary in-section ordering: operative date, then higher priority, then the tiebreak.
    static func byOp(_ a: ParsedTodo, _ b: ParsedTodo) -> Bool {
        let ad = opDate(a), bd = opDate(b)
        if ad != bd {
            return ad < bd
        }
        let ap = a.priority ?? 0, bp = b.priority ?? 0
        if ap != bp {
            return ap > bp
        }
        return tieKey(a) < tieKey(b)
    }

    static func byDoneDesc(_ a: ParsedTodo, _ b: ParsedTodo) -> Bool {
        let ad = a.doneDate ?? "", bd = b.doneDate ?? ""
        if ad != bd {
            return ad > bd
        } // newest completion first
        return tieKey(a) < tieKey(b)
    }

    /// The DAY view's grouped sections for `viewIso` (ports dashboard.ts sectionsForDay).
    /// `today` picks the lead section's title ("Today's Items" vs "Due This Day").
    public static func sectionsForDay(_ todos: [ParsedTodo], viewIso: String, today: String? = nil,
                                      prefs: TodoFeedPrefs = .day) -> [TodoSection] {
        let pool = todos.filter { prefs.sources.contains(layer($0)) }
        let roots = pool.filter { $0.parentLine == nil }
        let shown = roots.filter { !$0.done && ($0.start == nil || $0.start! <= viewIso) }
        let soonEnd = TodoIndex.addDuration(viewIso, soonDays, "d")
        let followEnd = TodoIndex.addDuration(viewIso, followupWindow, "d")

        let overdue = shown.filter { opDate($0) < viewIso }.sorted(by: byOp)
        let followups = shown.filter { f in
            f.followup.map { $0 >= viewIso && $0 <= followEnd } ?? false
        }.sorted(by: byOp)
        let plain = shown.filter { $0.followup == nil }
        let dueThisDay = plain.filter { dueDate($0) == viewIso }.sorted(by: byOp)
        let highSoon = plain.filter {
            ($0.priority ?? 0) >= highPriority && dueDate($0) > viewIso && dueDate($0) <= soonEnd
        }.sorted(by: byOp)
        let lowSoon = plain.filter {
            ($0.priority ?? 0) < highPriority && dueDate($0) > viewIso && dueDate($0) <= soonEnd
        }.sorted(by: byOp)
        let recentStart = TodoIndex.addDuration(viewIso, -recentDoneDays, "d")
        let completed = roots.filter { t in
            guard t.done, let d = t.doneDate.map({ String($0.prefix(10)) }) else { return false }
            return d >= recentStart && d <= viewIso
        }.sorted(by: byDoneDesc)

        let base: [TodoSection] = [
            TodoSection(key: "dueDay", title: "", items: dueThisDay, done: false),
            TodoSection(key: "overdue", title: "Overdue", items: overdue, done: false),
            TodoSection(key: "followup", title: "Remember to Followup", items: followups, done: false),
            TodoSection(key: "highSoon", title: "High Priority · Due Soon", items: highSoon, done: false),
            TodoSection(key: "dueSoon", title: "Due Soon", items: lowSoon, done: false),
            TodoSection(key: "done", title: "Recently Completed", items: completed, done: true),
        ].compactMap { s in
            guard !s.items.isEmpty, prefs.sections.contains(s.key) else { return nil }
            var s2 = s
            if s.key == "dueDay" {
                s2.title = viewIso == today ? "Today's Items" : "Due This Day"
            }
            return s2
        }
        return withPinned(base, pool: pool)
    }

    /// The WEEK/MONTH range sections (ports dashboard.ts rangeTodoSections). Roots only; a
    /// qualifying open SUB-item PROMOTES its root, roots ordered by their earliest qualifying
    /// member; completed = done roots finished in range, minus any already shown open.
    public static func rangeSections(_ todos: [ParsedTodo], start: String, end: String,
                                     word: String, prefs: TodoFeedPrefs) -> [TodoSection] {
        let pool = todos.filter { prefs.sources.contains(layer($0)) }
        let inR = { (d: String) in d >= start && d <= end }
        let byLine = Dictionary(pool.map { ("\(scopeKey($0))\0\($0.line)", $0) },
                                uniquingKeysWith: { a, _ in a })
        func rootOf(_ t: ParsedTodo) -> ParsedTodo {
            var cur = t
            while let p = cur.parentLine, let up = byLine["\(scopeKey(cur))\0\(p)"] {
                cur = up
            }
            return cur
        }
        var open: [ParsedTodo] = []
        var openKeys = Set<String>()
        for h in pool.filter({ !$0.done && inR(opDate($0)) }).sorted(by: byOp) {
            let r = rootOf(h)
            if openKeys.insert(tieKey(r)).inserted {
                open.append(r)
            }
        }
        let completed = pool.filter { t in
            guard t.done, t.parentLine == nil, let d = t.doneDate.map({ String($0.prefix(10)) })
            else { return false }
            return inR(d) && !openKeys.contains(tieKey(t))
        }.sorted(by: byDoneDesc)
        let base = [
            TodoSection(key: "open", title: "TODOs \(word)", items: open, done: false),
            TodoSection(key: "done", title: "Completed \(word)", items: completed, done: true),
        ].filter { !$0.items.isEmpty && prefs.sections.contains($0.key) }
        return withPinned(base, pool: pool)
    }
}
