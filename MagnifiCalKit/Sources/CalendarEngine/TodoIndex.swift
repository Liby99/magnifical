// The TODO tokenizer + index — the Swift port of the web's todos.ts, and (since the web app is
// legacy, 2026-07-30) the SOURCE OF TRUTH for the inline task-token DSL going forward. Phase 0 of
// the webview retirement (docs/webview-retirement-design.md): the native dashboard reads this
// directly instead of round-tripping dashboardDataJSON through a WKWebView.
//
// TODOs are GitHub-style markdown checkboxes living inside an event's `notes` (or per-occurrence
// notes) — `- [ ] submit the abstract due:2026-07-01 p:!!`. They are NOT a separate table: the
// markdown line is the canonical store; everything here is *derived* from it.
//
// Grammar (locked; matches todos.ts, verified by golden vectors in TodoIndexTests):
//   Every token is EITHER a sigil-ref (`#tag`, `@person`, `@type:slug`, a markdown/bare link) OR an
//   allowlisted `key:value` (`due:`, `start:`, `tz:`, `color:`, `done:`, `created:`, `followup:`,
//   and priority `p:!`…`p:!!!!!`). Every token is anchored to whitespace-or-line-start so an email
//   (`tommy@cs.jhu.edu`) never matches `@cs`. Link contents are masked out first, so `#frag` /
//   `@host` inside a URL are never tokens.
//
// Dependency-free and engine-state-free: pure value types over strings, so CalendarRender/UI (and
// the iPhone target) can call it without touching the engine.

import CalendarGeometry // utcCalendar (UTC-safe wall-clock date arithmetic)
import Foundation

// ── Types ──────────────────────────────────────────────────────────────────────────────────────

public struct TodoLink: Equatable, Codable, Sendable {
    public var label: String?
    public var url: String
    public init(label: String? = nil, url: String) {
        self.label = label; self.url = url
    }
}

/// What `tokenizeLine` extracts from a single line's text (no event context, no inheritance).
public struct TodoLineTokens: Equatable, Sendable {
    public var text = "" // the line text with all tokens stripped, whitespace-collapsed, trimmed
    public var priority: Int? // 1–5 (bang count), higher = more urgent
    public var due: String?
    public var tz: String? // timezone for `due:`
    public var start: String?
    public var color: String?
    public var done: String? // completion date token (distinct from the checkbox state)
    public var created: String? // `created:` stamp — when the item entered the list
    public var followup: String? // raw followup value: a duration ("30d") or a loose date
    public var tags: [String] = []
    public var entities: [String: [String]] = [:] // @type:slug refs keyed by type ("person" for bare @)
    public var links: [TodoLink] = []
}

/// The minimal shape `parseTodos` needs from an event — built straight from CalendarItems.
public struct TodoSource: Sendable {
    public var id: String
    public var kind: String // "timed" | "band" | "deadline"
    public var title: String
    public var color: String
    public var tags: [String]
    public var start: String // wall-clock "YYYY-MM-DD[THH:MM:SS]"; date part inherited as default due
    public var end: String // wall-clock end; its date is the base a `followup:<duration>` counts from
    public var originTz: String? // deadline origin tz, inherited as the default due tz
    public var notes: String?
    public var occurrenceNotes: [String: String]? // per-occurrence overrides, keyed by occurrence date
    public init(id: String, kind: String, title: String, color: String, tags: [String],
                start: String, end: String, originTz: String? = nil,
                notes: String?, occurrenceNotes: [String: String]? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.color = color; self.tags = tags
        self.start = start; self.end = end; self.originTz = originTz
        self.notes = notes; self.occurrenceNotes = occurrenceNotes
    }
}

/// A fully-resolved TODO: a soft-link to one source line, with event inheritance applied.
/// Codable with todos.ts field names so the golden vectors compare 1:1.
public struct ParsedTodo: Equatable, Codable, Sendable {
    public var raw: String // the full source line, verbatim
    public var text: String // human text with tokens stripped

    public var done: Bool // from the checkbox `[x]`
    public var doneDate: String? // from a `done:` token, if present
    public var created: String? // from a `created:` token

    // Provenance + soft-link anchor: which note, which line.
    public var source: String // "event" | "daily"
    public var eventId: String // "" for daily
    public var eventTitle: String // event title, or "Daily note · YYYY-MM-DD"
    public var eventKind: String // "timed" | "band" | "deadline" | "daily"
    public var occurrenceKey: String? // event source: key into occurrenceNotes
    public var dailyDate: String? // daily source: the note's date (the soft-link anchor)
    public var line: Int // 1-based line number within that note

    // Nesting: a task line indented under a preceding, less-indented task line is its child.
    public var indent: Int // 0 = top-level, 1 = child, …
    public var parentLine: Int? // 1-based line of the parent task within the same note

    public var priority: Int?
    public var due: String? // line `due:` else the inherited date
    public var dueTz: String?
    public var dueSource: String // "line" | "event"
    public var followup: String? // resolved follow-up date (YYYY-MM-DD)
    public var start: String? // show-from date (line token only)
    public var active: Bool // !done && (start == nil || today >= start)

    public var tags: [String] // event.tags ∪ line #tags (case-insensitive union, first-seen casing)
    public var people: [String]
    public var projects: [String]
    public var funding: [String]
    public var entities: [String: [String]]
    public var links: [TodoLink]

    public var color: String?
    public var colorSource: String // "line" | "event"
}

// ── The tokenizer / index ──────────────────────────────────────────────────────────────────────

public enum TodoIndex {
    public static let maxPriority = 5

    // Token patterns — verbatim ports of the todos.ts regexes (ICU syntax is compatible here).
    fileprivate static let mdLink = Re(#"\[([^\]]*)\]\((https?://[^)\s]+|[^)\s]+)\)"#)
    fileprivate static let bareURL = Re(#"(^|\s)(https?://[^\s]+)(?=\s|$)"#)
    fileprivate static let priority = Re(#"(^|\s)p:(!{1,})(?=\s|$)"#)
    static let dateValue = #"today|tomorrow|yesterday|-?\d+[dwmy]|\d{4}-\d{2}-\d{2}"#
    static let timeValue = #"\d{1,2}(?::\d{2})?(?:am|pm)|\d{1,2}:\d{2}"#
    fileprivate static let due = Re("(^|\\s)due:(\(dateValue)(?:[T ]\\d{2}:\\d{2})?|\(timeValue))(?=\\s|$)")
    fileprivate static let start = Re("(^|\\s)start:(\(dateValue))(?=\\s|$)")
    fileprivate static let tz = Re(#"(^|\s)tz:(AOE|[A-Za-z][\w/+-]*)(?=\s|$)"#)
    fileprivate static let color = Re(#"(^|\s)color:([\w-]+)(?=\s|$)"#)
    fileprivate static let done = Re(#"(^|\s)done:(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?)(?=\s|$)"#)
    fileprivate static let created = Re(#"(^|\s)created:(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?)(?=\s|$)"#)
    fileprivate static let followup = Re(#"(^|\s)followup:(\d+[dwmy]|\d{4}-\d{1,2}-\d{1,2})(?=\s|$)"#)
    fileprivate static let project = Re(#"(^|\s)project:([A-Za-z0-9_-]+)(?=\s|$)"#)
    fileprivate static let tag = Re(#"(^|\s)#([A-Za-z0-9_][\w-]*)(?=\s|$)"#)
    fileprivate static let entity = Re(#"(^|\s)@(?:([A-Za-z][\w-]*):)?([A-Za-z0-9_][\w-]*)(?=\s|$)"#)
    /// A GFM task-list line: indent+marker, the `[ ]`/`[x]` state, and the rest of the line.
    fileprivate static let taskLine = Re(#"^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\](.*)$"#)

    /// Tokenize one line of text (the part after a `- [ ] ` marker). Links are masked first so
    /// URL contents can't masquerade as `#`/`@` tokens; each remaining token is stripped from the
    /// text as it's consumed, leaving the human-readable remainder.
    /// Every `#tag` in a whole note — ANY line, not just todo rows. Tags are markdown tokens
    /// (`#[A-Za-z0-9_][\w-]*`, so `# Header` with its space never matches); the separate tags
    /// UI is gone and `rich.tags` is a CACHE recomputed from this. Case-insensitive dedupe,
    /// first-seen casing, appearance order. Fenced code blocks don't tokenize; links are masked
    /// by the line tokenizer.
    public static func noteTags(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lead = line.drop(while: { $0 == " " || $0 == "\t" })
            if lead.hasPrefix("```") || lead.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                continue
            }
            for t in tokenizeLine(String(line)).tags where seen.insert(t.lowercased()).inserted {
                out.append(t)
            }
        }
        return out
    }

    /// A legacy UI-era tag as a markdown token: illegal characters collapse to "-" (the old free-text
    /// field allowed anything; `#my tag` would otherwise parse as `#my`). nil when nothing survives.
    public static func tagToken(_ tag: String) -> String? {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    public static func tokenizeLine(_ input: String) -> TodoLineTokens {
        var t = TodoLineTokens()
        var text = input

        // 1) Markdown links first — nothing inside them tokenizes. 2) Bare URLs.
        text = mdLink.replaceAll(text) { g in
            t.links.append(TodoLink(label: g[1].isEmpty ? nil : g[1], url: g[2])); return " "
        }
        text = bareURL.replaceAll(text) { g in
            t.links.append(TodoLink(url: g[2])); return " "
        }

        // 3) Single-valued key:value tokens + priority. First occurrence wins.
        text = priority.replaceFirst(text) { g in
            t.priority = min(Self.maxPriority, g[2].count); return " "
        }
        text = due.replaceFirst(text) { g in t.due = g[2]; return " " }
        text = start.replaceFirst(text) { g in t.start = g[2]; return " " }
        text = tz.replaceFirst(text) { g in t.tz = g[2]; return " " }
        text = color.replaceFirst(text) { g in t.color = g[2]; return " " }
        text = done.replaceFirst(text) { g in t.done = g[2]; return " " }
        text = created.replaceFirst(text) { g in t.created = g[2]; return " " }
        text = followup.replaceFirst(text) { g in t.followup = g[2]; return " " }

        // 4) Multi-valued refs. `project:` first (sugar for `@project:`), then the sigils.
        text = project.replaceAll(text) { g in
            t.entities["project", default: []].append(g[2]); return " "
        }
        text = tag.replaceAll(text) { g in t.tags.append(g[2]); return " " }
        text = entity.replaceAll(text) { g in
            let type = g[2].isEmpty ? "person" : g[2].lowercased()
            t.entities[type, default: []].append(g[3]); return " "
        }

        t.text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t
    }

    // ── Date resolution (UTC-safe wall-clock arithmetic, like todos.ts) ────────────────────────

    static func pad2(_ n: Int) -> String {
        String(format: "%02d", n)
    }

    /// `30d` / `2w` / `3m` / `1y` added to a base `YYYY-MM-DD` date. Day/week adds are pure
    /// integer JDN arithmetic (this sits in chart axes loops and the feed build — the Calendar
    /// round-trip cost µs per call); month/year adds keep Calendar's overflow normalization
    /// (Jan 31 + 1m) — they're rare (`3m`/`1y` duration tokens only).
    public static func addDuration(_ baseIso: String, _ n: Int, _ unit: Character) -> String {
        if unit == "d" || unit == "w" {
            guard let num = ProjIndex.dayNumber(baseIso) else { return baseIso }
            return ProjIndex.isoFromDayNumber(num + n * (unit == "w" ? 7 : 1))
        }
        let p = baseIso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return baseIso }
        var c = DateComponents(year: p[0], month: p[1], day: p[2])
        if unit == "m" {
            c.month! += n
        } else {
            c.year! += n
        } // "y"
        let cal = utcCalendar
        guard let d = cal.date(from: c) else { return baseIso }
        let o = cal.dateComponents([.year, .month, .day], from: d)
        return "\(String(format: "%04d", o.year!))-\(pad2(o.month!))-\(pad2(o.day!))"
    }

    /// Resolve a raw `followup:` value: a duration off `endDate`, or a literal loose date.
    static func resolveFollowup(_ raw: String, endDate: String) -> String? {
        if let g = Re.followupDur.first(raw) {
            return addDuration(endDate, Int(g[1]) ?? 0, g[2].first ?? "d")
        }
        if let g = Re.looseDate.first(raw) {
            return "\(g[1])-\(pad2(Int(g[2]) ?? 1))-\(pad2(Int(g[3]) ?? 1))"
        }
        return nil
    }

    /// Resolve a `due:`/`start:` value to a concrete date. Explicit dates pass through; keywords
    /// and offsets resolve against `today`; a bare time resolves to today at that time.
    static func resolveDateToken(_ v: String, today: String?) -> String? {
        if Re.isoPrefix.first(v) != nil {
            return v
        } // explicit date (keeps any THH:MM)
        guard let today else { return nil }
        if v == "today" {
            return today
        }
        if v == "tomorrow" {
            return addDuration(today, 1, "d")
        }
        if v == "yesterday" {
            return addDuration(today, -1, "d")
        }
        if let g = Re.signedDur.first(v) {
            return addDuration(today, Int(g[1]) ?? 0, g[2].first ?? "d")
        }
        if let g = Re.time12.first(v) {
            let h = (Int(g[1])! % 12) + (g[3].lowercased() == "pm" ? 12 : 0)
            return "\(today)T\(pad2(h)):\(g[2].isEmpty ? "00" : g[2])"
        }
        if let g = Re.time24.first(v) {
            return "\(today)T\(pad2(Int(g[1])!)):\(g[2])"
        }
        return nil
    }

    // ── Nesting scan ───────────────────────────────────────────────────────────────────────────

    struct ScannedTask {
        var line: Int // 1-based
        var raw: String
        var done: Bool
        var tok: TodoLineTokens
        var depth: Int
        var parentLine: Int?
    }

    /// Indent width in columns (a tab counts as 4).
    static func indentWidth(_ line: some StringProtocol) -> Int {
        var w = 0
        for ch in line {
            if ch == " " {
                w += 1
            } else if ch == "\t" {
                w += 4
            } else {
                break
            }
        }
        return w
    }

    /// Walk a note's checkbox lines tracking NESTING: a task line indented deeper than the nearest
    /// preceding task line is its child. A non-blank, non-task line pops the chain back to its own
    /// indent; blank lines never break the chain; empty checkbox lines are skipped entirely.
    static func scanTaskLines(_ notes: String, _ visit: (ScannedTask) -> Void) {
        let lines = notes.components(separatedBy: "\n")
        var stack: [(width: Int, line: Int, depth: Int)] = []
        for (i, lineText) in lines.enumerated() {
            guard let m = taskLine.first(lineText) else {
                if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                }
                let w = indentWidth(lineText)
                while let top = stack.last, top.width >= w {
                    stack.removeLast()
                }
                continue
            }
            let tok = tokenizeLine(m[3])
            if tok.text.isEmpty {
                continue
            } // `- [ ]` with no task text never parents anything
            let width = indentWidth(m[1])
            while let top = stack.last, top.width >= width {
                stack.removeLast()
            }
            let top = stack.last
            let depth = top.map { $0.depth + 1 } ?? 0
            visit(ScannedTask(line: i + 1, raw: lineText, done: m[2].lowercased() == "x",
                              tok: tok, depth: depth, parentLine: top?.line))
            stack.append((width, i + 1, depth))
        }
    }

    // ── Inheritance + assembly ─────────────────────────────────────────────────────────────────

    struct Context {
        var source: String // "event" | "daily"
        var eventId: String
        var eventTitle: String
        var eventKind: String
        var occurrenceKey: String?
        var dailyDate: String?
        var inheritDate: String // default due
        var inheritEndDate: String // followup base
        var inheritColor: String
        var inheritTags: [String]
        var originTz: String?
    }

    /// Case-insensitive union preserving first-seen casing.
    static func unionCI(_ lists: [String]...) -> [String] {
        var seen: [String: String] = [:]
        var order: [String] = []
        for list in lists {
            for v in list {
                let k = v.lowercased()
                if seen[k] == nil {
                    seen[k] = v; order.append(v)
                }
            }
        }
        return order
    }

    static func buildTodo(_ ctx: Context, _ t: ScannedTask, today: String?) -> ParsedTodo {
        let dueTok = t.tok.due.flatMap { resolveDateToken($0, today: today) }
        let startTok = t.tok.start.flatMap { resolveDateToken($0, today: today) }
        let dueSource = dueTok != nil ? "line" : "event"
        let dueTz = t.tok.tz
            ?? (dueSource == "event" && ctx.eventKind == "deadline" ? ctx.originTz : nil)
        let followup = t.tok.followup.flatMap { resolveFollowup($0, endDate: ctx.inheritEndDate) }
        let colorSource = t.tok.color != nil ? "line" : "event"
        // Deferred items are inactive until their show-from date; with no `today` reference the
        // defer can't be evaluated, so a non-done item counts as active.
        let active = !t.done && (startTok == nil || today == nil || today! >= startTok!)
        return ParsedTodo(
            raw: t.raw, text: t.tok.text, done: t.done, doneDate: t.tok.done,
            created: t.tok.created,
            source: ctx.source, eventId: ctx.eventId, eventTitle: ctx.eventTitle,
            eventKind: ctx.eventKind, occurrenceKey: ctx.occurrenceKey, dailyDate: ctx.dailyDate,
            line: t.line, indent: t.depth, parentLine: t.parentLine,
            priority: t.tok.priority, due: dueTok ?? ctx.inheritDate, dueTz: dueTz,
            dueSource: dueSource, followup: followup, start: startTok, active: active,
            tags: unionCI(ctx.inheritTags, t.tok.tags),
            people: t.tok.entities["person"] ?? [],
            projects: t.tok.entities["project"] ?? [],
            funding: t.tok.entities["funding"] ?? [],
            entities: t.tok.entities, links: t.tok.links,
            color: t.tok.color ?? ctx.inheritColor, colorSource: colorSource
        )
    }

    /// Parse every checkbox line in an event's notes (and per-occurrence notes).
    public static func parseTodos(_ event: TodoSource, today: String? = nil) -> [ParsedTodo] {
        var out: [ParsedTodo] = []
        func scan(_ notes: String?, _ occKey: String?, _ date: String, _ endDate: String) {
            guard let notes else { return }
            let ctx = Context(source: "event", eventId: event.id, eventTitle: event.title,
                              eventKind: event.kind, occurrenceKey: occKey, dailyDate: nil,
                              inheritDate: date, inheritEndDate: endDate,
                              inheritColor: event.color, inheritTags: event.tags,
                              originTz: event.originTz)
            scanTaskLines(notes) { out.append(buildTodo(ctx, $0, today: today)) }
        }
        scan(event.notes, nil, String(event.start.prefix(10)), String(event.end.prefix(10)))
        // Sorted keys: Swift dictionaries don't preserve insertion order (JS objects do); a
        // deterministic order keeps the index stable across runs.
        for (key, notes) in (event.occurrenceNotes ?? [:]).sorted(by: { $0.key < $1.key }) {
            scan(notes, key, key, key)
        }
        return out
    }

    /// Parse a day's "daily note" (also weekly/monthly scope notes — the key is the anchor).
    public static func parseDailyNoteTodos(date: String, notes: String?,
                                           today: String? = nil) -> [ParsedTodo] {
        guard let notes else { return [] }
        var out: [ParsedTodo] = []
        let ctx = Context(source: "daily", eventId: "", eventTitle: "Daily note · \(date)",
                          eventKind: "daily", occurrenceKey: nil, dailyDate: date,
                          inheritDate: date, inheritEndDate: date,
                          inheritColor: "default", inheritTags: [], originTz: nil)
        scanTaskLines(notes) { out.append(buildTodo(ctx, $0, today: today)) }
        return out
    }

    /// The cross-event TODO index: every event's todos, flat + sorted by `orderedBefore`.
    public static func indexTodos(_ events: [TodoSource], today: String? = nil) -> [ParsedTodo] {
        events.flatMap { parseTodos($0, today: today) }.sorted(by: orderedBefore)
    }

    /// Default feed ordering: active first, then not-done, then due (undated last), then higher
    /// priority, then text. (todos.ts tiebreaks with localeCompare; here it's a case-insensitive
    /// lexicographic compare — the web app is legacy, exact collation parity isn't a contract.)
    public static func orderedBefore(_ a: ParsedTodo, _ b: ParsedTodo) -> Bool {
        if a.active != b.active {
            return a.active
        }
        if a.done != b.done {
            return b.done
        }
        let ad = a.due ?? "9999-99-99", bd = b.due ?? "9999-99-99"
        if ad != bd {
            return ad < bd
        }
        let ap = a.priority ?? 0, bp = b.priority ?? 0
        if ap != bp {
            return ap > bp
        }
        return a.text.lowercased() < b.text.lowercased()
    }

    // ── Soft-link write primitives ─────────────────────────────────────────────────────────────

    /// Flip the checkbox on `line` (1-based). `checked` nil toggles; with `stamp`, checking
    /// appends `done:<stamp>` and unchecking strips any `done:` token. Returns the new note, the
    /// SAME note on a no-op, or nil on a stale anchor (line gone / not a task line).
    public static func toggleTodoLine(_ noteText: String, line: Int,
                                      checked: Bool? = nil, stamp: String? = nil) -> String? {
        var lines = noteText.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count, let m = taskLine.first(lines[line - 1]) else {
            return nil
        }
        let isChecked = m[2].lowercased() == "x"
        let next = checked ?? !isChecked
        var rest = done.replaceAll(m[3]) { _ in "" }
        while rest.hasSuffix(" ") || rest.hasSuffix("\t") {
            rest.removeLast()
        }
        if next, let stamp {
            rest = "\(rest) done:\(stamp)"
        }
        let nextLine = "\(m[1])[\(next ? "x" : " ")]\(rest)"
        if nextLine == lines[line - 1] {
            return noteText
        }
        lines[line - 1] = nextLine
        return lines.joined(separator: "\n")
    }

    /// The PROJ quick-add write: append `- [ ] <todo> @project:<project> created:<stamp>
    /// #proj-pinned` into `note` under the top-level `# <project>` heading (case-sensitive
    /// match first, case-insensitive fallback) — after the last line of the section's LAST
    /// todo-list run, after its last content line when it has no list, or into a fresh
    /// blank-line-separated section at the end when the heading doesn't exist. Pure
    /// string → string; the panel wires it to setDailyNote.
    public static func appendProjectTodo(note: String, project: String, todo: String,
                                         stamp: String) -> String {
        let item = todo.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return note }
        let newLine = "- [ ] \(item) @project:\(project) created:\(stamp) #proj-pinned"
        var rows = note.components(separatedBy: "\n")
        func title(_ row: String) -> String? {
            row.hasPrefix("# ") ? String(row.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil
        }
        let head = rows.firstIndex(where: { title($0) == project })
            ?? rows.firstIndex(where: { title($0)?.lowercased() == project.lowercased() })
        guard let head else {
            while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.removeLast()
            }
            rows += rows.isEmpty ? ["# \(project)", newLine] : ["", "# \(project)", newLine]
            return rows.joined(separator: "\n")
        }
        // The section runs to the next top-level heading (or the end of the note).
        let end = (head + 1 ..< rows.count).first { rows[$0].hasPrefix("# ") } ?? rows.count
        // The last todo line in the section IS the last line of its last todo-list run; a
        // list-less section takes the line after its last non-blank content instead.
        let lastTodo = (head + 1 ..< end).last { taskLine.first(rows[$0]) != nil }
        let lastContent = (head ..< end).last {
            !rows[$0].trimmingCharacters(in: .whitespaces).isEmpty
        } ?? head
        rows.insert(newLine, at: (lastTodo ?? lastContent) + 1)
        return rows.joined(separator: "\n")
    }

    // ── One-line token rewrites (the PROJ row menu's pure parts) ───────────────────────────────

    /// Shared guard for the one-line rewrites below: verify `line` (1-based) is a task line,
    /// run `transform` on that raw line, and rejoin. toggleTodoLine's return contract: the new
    /// note, the SAME note on a no-op, or nil on a stale anchor (line gone / not a task line).
    static func rewriteTaskLine(_ noteText: String, line: Int,
                                _ transform: (String) -> String) -> String? {
        var lines = noteText.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count, taskLine.first(lines[line - 1]) != nil else {
            return nil
        }
        let next = transform(lines[line - 1])
        if next == lines[line - 1] {
            return noteText
        }
        lines[line - 1] = next
        return lines.joined(separator: "\n")
    }

    /// Trailing spaces/tabs stripped so appended tokens always join with exactly one space.
    private static func trimmedTail(_ row: String) -> String {
        var r = row
        while r.hasSuffix(" ") || r.hasSuffix("\t") {
            r.removeLast()
        }
        return r
    }

    /// Set the row's `color:` token: replace an existing `color:<x>` in place or append
    /// ` color:<name>`. rewriteTaskLine's return contract.
    public static func setColorToken(_ noteText: String, line: Int, color value: String) -> String? {
        rewriteTaskLine(noteText, line: line) { row in
            if Self.color.first(row) != nil {
                return Self.color.replaceFirst(row) { g in "\(g[1])color:\(value)" }
            }
            return trimmedTail(row) + " color:\(value)"
        }
    }

    /// Set the row's priority: replace an existing `p:!…` token in place or append ` p:` +
    /// `level` bangs (clamped to 1…maxPriority). rewriteTaskLine's return contract.
    public static func setPriority(_ noteText: String, line: Int, level: Int) -> String? {
        let bangs = String(repeating: "!", count: max(1, min(maxPriority, level)))
        return rewriteTaskLine(noteText, line: line) { row in
            if Self.priority.first(row) != nil {
                return Self.priority.replaceFirst(row) { g in "\(g[1])p:\(bangs)" }
            }
            return trimmedTail(row) + " p:\(bangs)"
        }
    }

    /// Remove the row's `p:!…` token entirely (the priority submenu's "None"); no-op when the
    /// row has no priority. rewriteTaskLine's return contract.
    public static func removePriority(_ noteText: String, line: Int) -> String? {
        rewriteTaskLine(noteText, line: line) { row in
            Self.priority.replaceFirst(row) { _ in "" }
        }
    }

    /// Append ` #<tag>` to the row unless it's already tagged (case-insensitive dedupe against
    /// the line's parsed tags, so URLs can't false-match). rewriteTaskLine's return contract.
    public static func addTag(_ noteText: String, line: Int, tag name: String) -> String? {
        rewriteTaskLine(noteText, line: line) { row in
            guard let m = taskLine.first(row) else { return row }
            if tokenizeLine(m[3]).tags.contains(where: { $0.lowercased() == name.lowercased() }) {
                return row
            }
            return trimmedTail(row) + " #\(name)"
        }
    }

    /// Remove ` #<tag>` from the row (case-insensitive; no-op when absent) — addTag's inverse,
    /// the row menu's Unpin. Collapses the doubled space a mid-line removal leaves behind.
    public static func removeTag(_ noteText: String, line: Int, tag name: String) -> String? {
        rewriteTaskLine(noteText, line: line) { row in
            // (?![\w-]) — NOT \b: the tag charset includes '-', and a word boundary between
            // "pinned" and "-" let "#proj-pinned" match INSIDE "#proj-pinned-extra".
            guard let re = try? NSRegularExpression(
                pattern: "\\s?#\(NSRegularExpression.escapedPattern(for: name))(?![\\w-])",
                options: [.caseInsensitive]
            ) else { return row }
            let ns = row as NSString
            guard let m = re.firstMatch(in: row, range: NSRange(location: 0, length: ns.length))
            else { return row }
            return ns.replacingCharacters(in: m.range, with: "")
        }
    }

    /// Remove the task line entirely — children/sub-items keep their own lines; only this one
    /// goes. Returns the new note, or nil on a stale anchor (line gone / not a task line).
    public static func removeTodoLine(_ noteText: String, line: Int) -> String? {
        var lines = noteText.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count, taskLine.first(lines[line - 1]) != nil else {
            return nil
        }
        lines.remove(at: line - 1)
        return lines.joined(separator: "\n")
    }

    /// "Start time marking": the 1-based lines of every TOP-LEVEL task line without a `created:`
    /// token yet — the editor stamps exactly these when an editing session ends.
    public static func linesNeedingCreated(_ noteText: String) -> [Int] {
        var out: [Int] = []
        scanTaskLines(noteText) { t in
            if t.depth == 0, t.tok.created == nil {
                out.append(t.line)
            }
        }
        return out
    }
}

// ── Regex helper ───────────────────────────────────────────────────────────────────────────────
// NSRegularExpression wrapper with JS-replace-like callbacks. Patterns compile once (static lets).
// Group accessor returns "" for unmatched optional groups, like JS's undefined-coalescing here.
// fileprivate: TodoNotifyScan has its own (older, simpler) `Re`; keeping this one file-scoped
// avoids the collision until the notify scan migrates onto TodoIndex.

private struct Re: @unchecked Sendable {
    let rx: NSRegularExpression
    init(_ pattern: String) {
        // Force-try: every pattern is a compile-time literal, exercised by the test suite.
        // swiftlint:disable:next force_try
        rx = try! NSRegularExpression(pattern: pattern, options: [])
    }

    private func groups(_ m: NSTextCheckingResult, _ s: String) -> [String] {
        (0 ..< m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : (s as NSString).substring(with: r)
        }
    }

    func first(_ s: String) -> [String]? {
        let ns = s as NSString
        return rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
            .map { groups($0, s) }
    }

    /// Replace the FIRST match via a callback receiving the groups (JS `replace` w/o /g).
    func replaceFirst(_ s: String, _ with: ([String]) -> String) -> String {
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return s
        }
        // JS callbacks replace the WHOLE match, including the leading (^|\s) group — mirror that.
        return ns.replacingCharacters(in: m.range, with: with(groups(m, s)))
    }

    /// Replace EVERY match via a callback (JS `replace` with /g). Callbacks run LEFT-TO-RIGHT
    /// (side effects like collected links/tags keep source order, exactly like JS); the string
    /// splice itself is applied back-to-front so NSRange offsets stay valid.
    func replaceAll(_ s: String, _ with: ([String]) -> String) -> String {
        let ns = s as NSString
        let ms = rx.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return s }
        let repls = ms.map { with(groups($0, s)) } // forward order — callback effects match JS
        var out = s
        for (m, repl) in zip(ms, repls).reversed() {
            out = (out as NSString).replacingCharacters(in: m.range, with: repl)
        }
        return out
    }

    // Small private patterns used by the resolvers.
    static let followupDur = Re(#"^(\d+)([dwmy])$"#)
    static let looseDate = Re(#"^(\d{4})-(\d{1,2})-(\d{1,2})$"#)
    static let isoPrefix = Re(#"^\d{4}-\d{2}-\d{2}"#)
    static let signedDur = Re(#"^(-?\d+)([dwmy])$"#)
    static let time12 = Re(#"^(\d{1,2})(?::(\d{2}))?([aApP][mM])$"#)
    static let time24 = Re(#"^(\d{1,2}):(\d{2})$"#)
}
