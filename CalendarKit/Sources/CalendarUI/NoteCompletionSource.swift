// NativeNoteEditor's autocomplete engine (ports noteEditor.ts's entitySource + dateSource):
// trigger scanning, entity/date completion options, loose-date parsing, and ⌘-click link
// hit-testing.
// Split from NativeNoteEditor.swift (audit round, 2026-08-02).

import AppKit

extension NativeNoteEditor {
    // ── Autocomplete engine (ports noteEditor.ts's entitySource + dateSource) ──────────────

    enum TriggerKind {
        case project, person, bareAt, tag
        case date(key: String) // due / start / created / done
    }

    struct Trigger {
        let kind: TriggerKind
        let partialRange: NSRange // the text an accepted completion replaces
        let partial: String
    }

    /// The completion trigger at the caret, scanning the line prefix — mirrors the web's
    /// matchBefore patterns (order matters: namespaced @ before bare @).
    static func completionTrigger(in tv: NSTextView) -> Trigger? {
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        guard caret <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(caret, max(0, ns.length - 1)), length: 0))
        let prefix = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
        func match(_ pattern: String, _ kind: (String) -> TriggerKind, sigilLen: Int) -> Trigger? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: prefix,
                                        range: NSRange(location: 0, length: (prefix as NSString).length))
            else { return nil }
            let full = m.range
            let partialLoc = line.location + full.location + sigilLen
            let partial = (prefix as NSString).substring(
                from: full.location + sigilLen
            )
            return Trigger(kind: kind(partial),
                           partialRange: NSRange(location: partialLoc, length: caret - partialLoc),
                           partial: partial)
        }
        if let t = match(#"@project:[\w-]*$"#, { _ in .project }, sigilLen: 9) {
            return t
        }
        if let t = match(#"@person:[\w-]*$"#, { _ in .person }, sigilLen: 8) {
            return t
        }
        if let t = match(#"@[\w-]*$"#, { _ in .bareAt }, sigilLen: 1) {
            return t
        }
        if let t = match(#"#[\w-]*$"#, { _ in .tag }, sigilLen: 1) {
            return t
        }
        if let re = try? NSRegularExpression(pattern: #"(due|start|created|done|followup):[\w/-]*$"#),
           let m = re.firstMatch(in: prefix,
                                 range: NSRange(location: 0, length: (prefix as NSString).length)) {
            let key = (prefix as NSString).substring(with: m.range(at: 1))
            let sigil = key.count + 1
            let partialLoc = line.location + m.range.location + sigil
            return Trigger(kind: .date(key: key),
                           partialRange: NSRange(location: partialLoc, length: caret - partialLoc),
                           partial: (prefix as NSString).substring(from: m.range.location + sigil))
        }
        return nil
    }

    /// Options for a trigger. Labeled date options render "label → concrete"; the editor
    /// inserts only the concrete part. Entity options insert verbatim.
    static func completionOptions(for t: Trigger,
                                  index: (projects: [String], people: [String], tags: [String])?,
                                  dueAnchor: (label: String, value: String)?) -> [String] {
        func filtered(_ xs: [String]) -> [String] {
            t.partial.isEmpty ? xs
                : xs.filter { $0.lowercased().hasPrefix(t.partial.lowercased()) }
        }
        switch t.kind {
        case .project: return filtered(index?.projects ?? [])
        case .person: return filtered(index?.people ?? [])
        case .tag: return filtered(index?.tags ?? [])
        case .bareAt:
            var opts = filtered(index?.people ?? [])
            for ns in ["project:", "person:"] where t.partial.isEmpty || ns.hasPrefix(t.partial.lowercased()) {
                opts.append(ns)
            }
            return opts
        case let .date(key):
            return dateOptions(key: key, partial: t.partial, dueAnchor: dueAnchor)
        }
    }

    /// noteEditor.ts's dateSource: loose forms → concrete dates. due/start are date-only and
    /// future-oriented; created/done carry minute times and resolve within this year.
    static func dateOptions(key: String, partial: String,
                            dueAnchor: (label: String, value: String)?) -> [String] {
        let now = Date()
        let cal = Calendar.current
        let wantTime = key == "created" || key == "done"
        let future = key == "due" || key == "start" || key == "followup" // planning tokens point forward
        func iso(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            return wantTime ? day + String(format: "T%02d:%02d", c.hour!, c.minute!) : day
        }
        var opts: [String] = []
        func push(_ label: String, _ d: Date) {
            opts.append("\(label) → \(iso(d))")
        }
        let p = partial.lowercased()
        if let d = parseLooseDate(p, now: now, future: future), !p.isEmpty {
            push(partial, d) // the typed freeform, concretized, on top
        }
        if future, !p.isEmpty, p.allSatisfy(\.isLetter) {
            let wd = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let today = cal.component(.weekday, from: now) - 1
            for (i, w) in wd.enumerated() where w.hasPrefix(p) {
                let ahead = ((i - today) + 7) % 7
                push(String(w.prefix(3)),
                     cal.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: now)!)
            }
        }
        let statics: [(String, Date)] = [
            ("now", now), ("today", now),
            ("tomorrow", cal.date(byAdding: .day, value: 1, to: now)!),
            ("3d", cal.date(byAdding: .day, value: 3, to: now)!),
            ("1w", cal.date(byAdding: .day, value: 7, to: now)!),
        ]
        for (l, d) in statics where (p.isEmpty || l.hasPrefix(p)) && l != p {
            push(l, d)
        }
        if key == "due", let anchor = dueAnchor,
           p.isEmpty || anchor.label.lowercased().hasPrefix(p) {
            opts.append("\(anchor.label) → \(anchor.value)")
        }
        return opts
    }

    /// "3d"/"2w"/"1m", "july-5"/"jul5", "7/5" → a concrete Date (the web's parseLooseDate).
    static func parseLooseDate(_ s: String, now: Date, future: Bool) -> Date? {
        let cal = Calendar.current
        if let m = s.wholeMatch(of: #/(\d+)(d|w|m)/#) {
            let n = Int(m.1) ?? 0
            switch m.2 {
            case "d": return cal.date(byAdding: .day, value: n, to: now)
            case "w": return cal.date(byAdding: .day, value: 7 * n, to: now)
            default: return cal.date(byAdding: .month, value: n, to: now)
            }
        }
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        func resolve(_ month: Int, _ day: Int) -> Date? {
            guard (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
            let year = cal.component(.year, from: now)
            var c = DateComponents(year: year, month: month, day: day)
            guard var d = cal.date(from: c) else { return nil }
            if future, d.timeIntervalSince(now) < -86400 {
                c.year = year + 1
                d = cal.date(from: c) ?? d
            }
            return d
        }
        if let m = s.wholeMatch(of: #/([a-z]{3,9})[-/ ]?(\d{1,2})/#) {
            guard let mi = months.firstIndex(where: { $0.hasPrefix(m.1) }) else { return nil }
            return resolve(mi + 1, Int(m.2) ?? 0)
        }
        if let m = s.wholeMatch(of: #/(\d{1,2})[-/](\d{1,2})/#) {
            return resolve(Int(m.1) ?? 0, Int(m.2) ?? 0)
        }
        return nil
    }

    /// The markdown/bare URL under `index`, if any (the web's linkAt, line-local scan).
    static func linkAt(_ text: String, index: Int) -> URL? {
        let ns = text as NSString
        guard index <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
        let lineText = ns.substring(with: line)
        let rel = index - line.location
        let re = try? NSRegularExpression(
            pattern: #"\[[^\]]*\]\(([^)\s]+)\)|(?:https?://|www\.)[^\s)]+"#
        )
        guard let re else { return nil }
        let lineNS = lineText as NSString
        for m in re.matches(in: lineText, range: NSRange(location: 0, length: lineNS.length)) {
            guard m.range.contains(rel) || m.range.location == rel else { continue }
            var raw = m.range(at: 1).location != NSNotFound
                ? lineNS.substring(with: m.range(at: 1))
                : lineNS.substring(with: m.range)
            if !raw.contains("://") {
                raw = "https://" + raw
            }
            return URL(string: raw)
        }
        return nil
    }
}
