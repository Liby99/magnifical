// The "managed note block" for imported events — a Swift port of the web's src/lib/import/managedNote.ts
// (docs/calendar-import-design.md §7). An imported event's note is a fixed two-region layout: a
// vendor-owned managed block (PREFIX) delimited by HTML-comment markers, and the user's own free text
// (POSTFIX). The markers render invisibly in the notes preview (no rehype-raw) yet persist in the
// stored string — so re-sync swaps only the vendor part and keeps the user's text verbatim.

import Foundation

public enum ManagedNote {
    static let begin = "libirabu:import:begin"
    static let end = "libirabu:import:end"
    /// Whole managed block (markers + body), dot-matches-newline, case-insensitive.
    private static let blockPattern = "<!--\\s*\(begin)[\\s\\S]*?\(end)\\s*-->"

    /// Split a stored note into its managed prefix (incl. markers; "" if none) and the user postfix.
    public static func splitNote(_ notes: String?) -> (managed: String, user: String) {
        let text = notes ?? ""
        guard let r = text.range(of: blockPattern, options: [.regularExpression, .caseInsensitive]) else {
            return ("", text)
        }
        let user = (String(text[text.startIndex ..< r.lowerBound]) + String(text[r.upperBound...]))
            .replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return (String(text[r]), user)
    }

    /// One parsed `key: value` row of a managed block (parseManaged).
    public struct ManagedField: Sendable {
        public let label: String
        public let value: String
        public let href: String? // value is a URL → render as a link
    }

    /// Markers stripped (both comment lines), body trimmed — the web's flattenManaged.
    public static func flattenManaged(_ notes: String?) -> String {
        (notes ?? "")
            .replacingOccurrences(
                of: "[ \\t]*<!--\\s*\(begin)[\\s\\S]*?-->[ \\t]*\\n?", with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "[ \\t]*<!--\\s*\(end)\\s*-->[ \\t]*\\n?", with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse a stored managed block into key/value fields + the trailing free-text description
    /// (the web's parseManaged) — for the structured table in note previews.
    public static func parseManaged(_ managed: String)
        -> (fields: [ManagedField], description: String) {
        let lines = flattenManaged(managed).components(separatedBy: "\n")
        let re = try? NSRegularExpression(pattern: #"^([\w ]+?):\s*(.*)$"#)
        var fields: [ManagedField] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                break // blank line → the rest is the description
            }
            let ns = line as NSString
            guard let m = re?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
            else { break } // first non key:value line → description starts here
            let value = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            fields.append(ManagedField(
                label: ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                value: value,
                href: isURL(value) ? value : nil
            ))
            i += 1
        }
        let desc = lines[min(i, lines.count)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, desc)
    }

    /// Recombine into the canonical "prefix + blank line + postfix".
    public static func composeNote(_ managed: String, _ user: String) -> String {
        let m = managed.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty {
            return u
        }
        return u.isEmpty ? m : "\(m)\n\n\(u)"
    }

    /// Re-sync: swap in a freshly-rendered managed block, preserving the user's postfix verbatim. A
    /// blank `fresh` drops the managed block entirely (keeping the user text).
    public static func replaceManaged(_ notes: String?, _ fresh: String) -> String {
        composeNote(fresh, splitNote(notes).user)
    }

    /// ── Rendering vendor details → a managed block ──────────────────────────────────────────────
    /// Keep vendor text from smuggling in our markers (which would corrupt later splits).
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(
            of: "libirabu:import:(begin|end)",
            with: "libirabu import",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func isURL(_ s: String) -> Bool {
        s.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let statusMark = ["accepted": "✓", "declined": "✗", "tentative": "~", "needs-action": "?"]
    private static func linkLabel(_ url: String) -> String {
        guard let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "").lowercased()
        else { return "link" }
        if host.contains("zoom.") {
            return "zoom"
        }
        if host.contains("meet.google") {
            return "meet"
        }
        if host.contains("teams.") {
            return "teams"
        }
        if host.contains("webex") {
            return "webex"
        }
        return "link"
    }

    /// True if a vendor event carries any detail worth a note (beyond bare provenance).
    public static func hasDetail(
        url: String?,
        location: String?,
        organizer: String?,
        attendees: Int,
        description: String?
    ) -> Bool {
        (url.map(isURL) ?? false) || !(location ?? "").isEmpty || !(organizer ?? "").isEmpty
            || attendees > 0 || !(description ?? "").isEmpty
    }

    /// Render a vendor event's details into a managed block (a PREFIX; callers compose with the postfix).
    public static func render(provenance: String, meetingUrl: String?, location: String?,
                              organizer: String?, attendees: [(name: String, status: String)],
                              description: String?) -> String {
        var lines = ["<!-- \(begin) -->", "imported from: \(sanitize(provenance))"]
        let loc = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = { () -> String in
            let u = (meetingUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !u.isEmpty, isURL(u) {
                return u
            }
            return isURL(loc) ? loc : ""
        }()
        if !url.isEmpty {
            lines.append("\(linkLabel(url)): \(url)")
        }
        if !loc.isEmpty, !isURL(loc) {
            lines.append("location: \(sanitize(loc))")
        }
        if let org = organizer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !org.isEmpty {
            lines.append("organizer: \(sanitize(org))")
        }
        if !attendees.isEmpty {
            let names = attendees.map { a -> String in
                let n = a.name.isEmpty ? "someone" : a.name
                let mark = statusMark[a.status] ?? ""
                return sanitize(mark.isEmpty ? n : "\(n) \(mark)")
            }
            lines.append("attendees: \(names.joined(separator: ", "))")
        }
        let desc = htmlToMarkdown(description ?? "")
        if !desc.isEmpty {
            lines.append(""); lines.append(sanitize(desc))
        }
        lines.append("<!-- \(end) -->")
        return lines.joined(separator: "\n")
    }

    /// Vendor descriptions are sometimes HTML (Google/Exchange). Convert to clean markdown; plain text
    /// passes through. Mirrors the web's htmlToMarkdown (links → md, <br>/<p> → newlines, tags stripped).
    static func htmlToMarkdown(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: "[<&]", options: .regularExpression) != nil else { return t }
        func rx(_ str: String, _ pat: String, _ rep: String) -> String {
            str.replacingOccurrences(of: pat, with: rep, options: [.regularExpression, .caseInsensitive])
        }
        var r = t
        r = rx(r, "<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>", "[$2]($1)")
        r = rx(r, "<br\\s*/?>", "\n")
        r = rx(r, "</(p|div|h[1-6]|li|tr)>", "\n")
        r = rx(r, "<li\\b[^>]*>", "\n• ")
        r = rx(r, "<[^>]+>", "")
        r = r.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        r = rx(r, "[ \\t]+\n", "\n")
        r = rx(r, "\n{3,}", "\n\n")
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
