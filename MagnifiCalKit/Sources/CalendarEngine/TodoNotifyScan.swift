// Todo-line scanning for NOTIFICATIONS — a deliberately small Swift port of the parts of the web
// tokenizer (src/lib/assistant/tools/todos.ts, the ground truth) that the notification planner
// needs: the checkbox-line shape, done-ness, inline #tags, `due:` values (explicit date/time,
// day/week/month/year offsets, today/tomorrow, bare times) and `tz:`. The dashboard webview keeps
// using the full JS tokenizer for rendering — this scanner exists only so the native scheduler can
// anchor todo notifications without a webview round-trip. Unsupported sigils (followup:, start:,
// priorities, entities) are stripped from the title but don't schedule anything in v1.

import CalendarGeometry
import CoreGraphics
import Foundation

/// One checkbox line, resolved far enough to schedule (or reject) a notification for it.
struct ScannedTodo: Equatable {
    var title: String // line text with sigil tokens stripped — the notification title
    var due: YMD? // resolved due DATE; nil = dateless (caller may inherit the source item's date)
    var dueHour: CGFloat? // fractional wall-clock hour when the due had a time part; nil = date-only
    var tz: String? // `tz:` value ("AOE"/IANA); nil = main tz
    var tags: Set<String> // lowercased inline #tags — "notify"/"silent" drive the override logic
    var done: Bool // checked box or a `done:` stamp — never notifies
    var lineKey: String // stable content hash — the id survives unrelated note edits
}

enum TodoScan {
    /// All checkbox lines of one markdown note. `today` anchors relative due values (offsets,
    /// today/tomorrow, bare times) — pass the CURRENT day so each resync re-resolves them.
    static func scan(_ note: String, today: YMD) -> [ScannedTodo] {
        note.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
            scanLine(String($0), today: today)
        }
    }

    private static func scanLine(_ line: String, today: YMD) -> ScannedTodo? {
        guard let m = TASK_LINE.firstMatch(line), m.count >= 3 else { return nil }
        let mark = m[1], rest = m[2]
        let done = mark.lowercased() == "x" || DONE.firstMatch(rest) != nil
        let tags = Set(TAG.allMatches(rest).compactMap { $0.count > 2 ? $0[2].lowercased() : nil })
        let tz = TZ.firstMatch(rest).flatMap { $0.count > 2 ? $0[2] : nil }
        let (due, hour) = resolveDue(rest, today: today)
        return ScannedTodo(title: stripSigils(rest), due: due, dueHour: hour, tz: tz,
                           tags: tags, done: done, lineKey: fnv1a(rest))
    }

    /// ── due: resolution (subset of the web's DATE_VALUE/TIME_VALUE grammar) ─────────────────
    private static func resolveDue(_ s: String, today: YMD) -> (YMD?, CGFloat?) {
        if let m = DUE_FULL.firstMatch(s), m.count >= 3, let ymd = parseISO(m[2]) {
            var hour: CGFloat?
            if m.count >= 5, let h = Int(m[3]), let mi = Int(m[4]) {
                hour = CGFloat(h) + CGFloat(mi) / 60
            }
            return (ymd, hour)
        }
        if let m = DUE_AMPM.firstMatch(s), m.count >= 5, let h12 = Int(m[2]) {
            let mi = Int(m[3]) ?? 0
            let h = (h12 % 12) + (m[4].lowercased() == "pm" ? 12 : 0)
            return (today, CGFloat(h) + CGFloat(mi) / 60)
        }
        if let m = DUE_24H.firstMatch(s), m.count >= 4, let h = Int(m[2]), let mi = Int(m[3]), h < 24 {
            return (today, CGFloat(h) + CGFloat(mi) / 60)
        }
        if let m = DUE_OFFSET.firstMatch(s), m.count >= 4, let n = Int(m[2]) {
            let unit: Calendar.Component = switch m[3] {
            case "w": .weekOfYear
            case "m": .month
            case "y": .year
            default: .day
            }
            return (addToYMD(today, n, unit), nil)
        }
        if let m = DUE_KEYWORD.firstMatch(s), m.count >= 3 {
            return (m[2] == "tomorrow" ? addToYMD(today, 1, .day) : today, nil)
        }
        return (nil, nil)
    }

    private static func parseISO(_ s: String) -> YMD? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return YMD(p[0], p[1] - 1, p[2])
    }

    /// Day math in a fixed UTC calendar (the same wall-clock treatment as Recurrence.swift).
    private static func addToYMD(_ p: YMD, _ n: Int, _ unit: Calendar.Component) -> YMD? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let base = cal.date(from: DateComponents(year: p.year, month: p.month + 1, day: p.day)),
              let d = cal.date(byAdding: unit, value: n, to: base) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return YMD(c.year ?? p.year, (c.month ?? 1) - 1, c.day ?? p.day)
    }

    /// Line text minus every sigil token — what the user reads as "the todo" in a banner.
    private static func stripSigils(_ s: String) -> String {
        var out = s
        out = MD_LINK.stringByReplacing(out, withTemplate: "$1") // [text](url) → text
        for re in [SIGIL_KV, TAG, ENTITY, PRIORITY] {
            out = re.stringByReplacing(out, withTemplate: " ")
        }
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// FNV-1a — a STABLE content hash (Swift's Hasher is seeded per launch, useless as a
    /// notification identifier that must survive restarts).
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 {
            h = (h ^ UInt64(b)) &* 0x100_0000_01B3
        }
        return String(h, radix: 36)
    }

    // ── Token patterns (mirroring todos.ts; NSRegularExpression via the tiny wrapper below) ──
    private static let TASK_LINE = Re(#"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\](.*)$"#)
    private static let DONE = Re(#"(^|\s)done:\d{4}-\d{2}-\d{2}"#)
    private static let TAG = Re(#"(^|\s)#([A-Za-z0-9_][\w-]*)(?=\s|$)"#)
    private static let TZ = Re(#"(^|\s)tz:(AOE|[A-Za-z][\w/+-]*)(?=\s|$)"#)
    private static let DUE_FULL = Re(#"(^|\s)due:(\d{4}-\d{2}-\d{2})(?:[T ](\d{1,2}):(\d{2}))?(?=\s|$)"#)
    private static let DUE_AMPM = Re(#"(^|\s)due:(\d{1,2})(?::(\d{2}))?(am|pm)(?=\s|$)"#)
    private static let DUE_24H = Re(#"(^|\s)due:(\d{1,2}):(\d{2})(?=\s|$)"#)
    private static let DUE_OFFSET = Re(#"(^|\s)due:(-?\d+)([dwmy])(?=\s|$)"#)
    private static let DUE_KEYWORD = Re(#"(^|\s)due:(today|tomorrow)(?=\s|$)"#)
    private static let SIGIL_KV = Re(#"(^|\s)(?:due|tz|color|done|start|followup|p):[^\s]+"#)
    private static let ENTITY = Re(#"(^|\s)@(?:[A-Za-z][\w-]*:)?[A-Za-z0-9_][\w-]*(?=\s|$)"#)
    private static let PRIORITY = Re(#"(^|\s)p:!{1,}(?=\s|$)"#)
    private static let MD_LINK = Re(#"\[([^\]]*)\]\([^)\s]+\)"#)
}

/// Minimal NSRegularExpression wrapper: capture groups as [String] ("" for unmatched groups).
private struct Re {
    let re: NSRegularExpression
    init(_ pattern: String) {
        re = try! NSRegularExpression(pattern: pattern)
    }

    private func groups(_ m: NSTextCheckingResult, _ s: String) -> [String] {
        (0 ..< m.numberOfRanges).map {
            Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? ""
        }
    }

    func firstMatch(_ s: String) -> [String]? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)).map { groups($0, s) }
    }

    func allMatches(_ s: String) -> [[String]] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { groups($0, s) }
    }

    func stringByReplacing(_ s: String, withTemplate t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
}
