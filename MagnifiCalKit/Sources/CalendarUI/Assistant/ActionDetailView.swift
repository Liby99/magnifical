// The expanded action card's body — a tool call's request/result rendered as REAL elements
// (label/value rows, color swatches, tag pills, result links), dispatched on the payload's shape.
// Ported from the web app's ActionDetail (AssistantPanel.tsx); raw JSON only as a last resort.
// Split out of ConversationView so the transcript view stays focused on layout.

import CalendarGeometry // MONTH_NAMES
import SwiftUI

struct ActionDetailView: View {
    let paramsJSON: String
    let resultJSON: String
    let theme: Theme

    private static let months = MONTH_NAMES // canonical (CalendarGeometry/Dates.swift)

    var body: some View {
        let args = JSONValue.parse(paramsJSON).asObject ?? [:]
        let res = JSONValue.parse(resultJSON).asObject ?? [:]
        VStack(alignment: .leading, spacing: 6) {
            content(args: args, res: res)
        }
    }

    @ViewBuilder private func content(args: [String: JSONValue], res: [String: JSONValue]) -> some View {
        if let err = res["error"]?.stringValue {
            row("Error") { Text(err).foregroundStyle(Color(hex: 0xE0483B)) }
        } else if args["title"] != nil, args["date"] != nil { // create_event
            eventRows(args)
        } else if let patch = args["patch"]?.asObject { // update_event
            patchRows(patch)
        } else if let results = res["results"]?.arrayValue { // web_search
            searchRows(results)
        } else if let url = res["url"]?.stringValue, res["text"] != nil { // web_open
            webOpenRows(url: url, title: res["title"]?.stringValue,
                        text: res["text"]?.stringValue ?? "")
        } else if let events = res["events"]?.arrayValue { // list_events
            listRows(res, events: events)
        } else if let todos = res["todos"]?.arrayValue { // list_todos
            todoRows(res, todos: todos)
        } else if res["zoom"] != nil || res["focusedMonth"] != nil { // set_view / screen
            viewRows(res)
        } else if let key = args["key"]?.stringValue { // remember / forget
            row("Key") { plain(key) }
            if let v = args["value"] {
                row("Value") { plain(compact(v)) }
            }
        } else if res["staged"]?.boolValue == true { // delete (resolved)
            row("Event") { plain(res["title"]?.stringValue ?? "") }
            row("Date") { plain(res["date"]?.stringValue ?? "") }
        } else { // fallback
            Text(paramsJSON == "{}" ? resultJSON : paramsJSON)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.textMuted).lineLimit(10).textSelection(.enabled)
        }
    }

    // ── Per-shape renderers ────────────────────────────────────────────────────────

    /// Event-shaped args (create_event): Title / Kind / When / Color / Lane / Tags / Notes.
    @ViewBuilder private func eventRows(_ a: [String: JSONValue]) -> some View {
        row("Title") { plain(a["title"]?.stringValue ?? "") }
        if let kind = a["kind"]?.stringValue {
            row("Kind") { badge(kind) }
        }
        row("When") { plain(whenLabel(a)) }
        if let color = a["color"]?.stringValue {
            row("Color") { swatch(color) }
        }
        if let lane = (a["promoteTrack"] ?? a["track"])?.intValue {
            row("Lane") { plain("\(lane)") }
        }
        if let tags = a["tags"]?.arrayValue?.compactMap(\.stringValue), !tags.isEmpty {
            row("Tags") { tagPills(tags) }
        }
        if let notes = a["notes"]?.stringValue, !notes.isEmpty {
            row("Notes") { plain(String(notes.prefix(200))).foregroundStyle(theme.textMuted) }
        }
    }

    /// update_event: one row per patched field.
    private func patchRows(_ patch: [String: JSONValue]) -> some View {
        ForEach(patch.keys.sorted(), id: \.self) { key in
            row(key.capitalized) {
                if key == "color", let c = patch[key]?.stringValue {
                    swatch(c)
                } else if key == "tags", let t = patch[key]?.arrayValue?.compactMap(\.stringValue) {
                    tagPills(t)
                } else {
                    plain(compact(patch[key] ?? .null))
                }
            }
        }
    }

    private func searchRows(_ results: [JSONValue]) -> some View {
        ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { _, r in
            if let urlStr = r["url"]?.stringValue, let url = URL(string: urlStr) {
                Link(r["title"]?.stringValue ?? urlStr, destination: url)
                    .font(.system(size: 11.5)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func webOpenRows(url: String, title: String?, text: String) -> some View {
        row("Page") {
            if let u = URL(string: url) {
                Link(title?.isEmpty == false ? title! : url, destination: u)
                    .font(.system(size: 11.5)).lineLimit(1)
            } else {
                plain(url)
            }
        }
        Text(String(text.prefix(400)) + (text.count > 400 ? "…" : ""))
            .font(.system(size: 11)).foregroundStyle(theme.textMuted).lineLimit(6).textSelection(.enabled)
    }

    @ViewBuilder private func listRows(_ res: [String: JSONValue], events: [JSONValue]) -> some View {
        if let year = res["year"]?.intValue {
            row("Year") { plain("\(year)") }
        }
        row("Items") { plain("\(res["count"]?.intValue ?? events.count)") }
        ForEach(Array(events.prefix(6).enumerated()), id: \.offset) { _, ev in
            HStack(spacing: 6) {
                if let c = ev["color"]?.stringValue {
                    Circle().fill(theme.eventColor(c)).frame(width: 6, height: 6)
                }
                Text(ev["title"]?.stringValue ?? "")
                    .font(.system(size: 11)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Text(ev["date"]?.stringValue ?? ev["start"]?.stringValue ?? "")
                    .font(.system(size: 10)).foregroundStyle(theme.textMuted)
            }
        }
        if events.count > 6 {
            Text("…and \(events.count - 6) more").font(.system(size: 10)).foregroundStyle(theme.textMuted)
        }
    }

    @ViewBuilder private func todoRows(_ res: [String: JSONValue], todos: [JSONValue]) -> some View {
        row("Items") { plain("\(res["count"]?.intValue ?? todos.count)") }
        ForEach(Array(todos.prefix(6).enumerated()), id: \.offset) { _, t in
            HStack(spacing: 6) {
                Image(systemName: t["done"]?.boolValue == true ? "checkmark.square" : "square")
                    .font(.system(size: 9)).foregroundStyle(theme.textMuted)
                Text(t["text"]?.stringValue ?? "")
                    .font(.system(size: 11)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Text(t["due"]?.stringValue ?? "")
                    .font(.system(size: 10)).foregroundStyle(theme.textMuted)
            }
        }
        if todos.count > 6 {
            Text("…and \(todos.count - 6) more").font(.system(size: 10)).foregroundStyle(theme.textMuted)
        }
    }

    @ViewBuilder private func viewRows(_ res: [String: JSONValue]) -> some View {
        if let y = res["year"]?.intValue {
            row("Year") { plain("\(y)") }
        }
        if let z = res["zoom"]?.stringValue {
            row("Zoom") { badge(z) }
        }
        if let m = res["focusedMonth"]?.intValue, Self.months.indices.contains(m) {
            row("Month") { plain(Self.months[m]) }
        }
    }

    // ── Row + element helpers ──────────────────────────────────────────────────────

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.textMuted)
                .frame(width: 48, alignment: .trailing)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func plain(_ s: String) -> Text {
        Text(s).font(.system(size: 11.5)).foregroundStyle(theme.text)
    }

    private func badge(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textMuted)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(theme.textMuted.opacity(0.14), in: Capsule())
    }

    private func swatch(_ color: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(theme.eventColor(color)).frame(width: 9, height: 9)
            plain(color)
        }
    }

    private func tagPills(_ tags: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(5), id: \.self) { t in badge("#" + t) }
        }
    }

    /// "Jul 18 · 09:00–10:00" style summary from create_event args.
    private func whenLabel(_ a: [String: JSONValue]) -> String {
        func pretty(_ iso: String?) -> String {
            guard let iso, let (_, m, d) = parseDate(iso), Self.months.indices.contains(m)
            else { return iso ?? "" }
            return "\(Self.months[m]) \(d)"
        }
        let date = pretty(a["date"]?.stringValue)
        switch a["kind"]?.stringValue {
        case "band":
            let end = a["endDate"]?.stringValue.map { pretty($0) }
            return end != nil && end != date ? "\(date) – \(end!)" : date
        case "deadline":
            let t = a["start"]?.stringValue ?? "17:00"
            return "\(date) · \(t)"
        default:
            let s = a["start"]?.stringValue ?? ""
            let e = a["end"]?.stringValue ?? ""
            if s.isEmpty {
                return date
            }
            return "\(date) · \(s)\(e.isEmpty ? "" : "–\(e)")"
        }
    }

    private func compact(_ v: JSONValue) -> String {
        switch v {
        case let .string(s): return s
        case let .number(n): return n == n.rounded() ? String(Int(n)) : String(n)
        case let .bool(b): return b ? "yes" : "no"
        case .null: return "—"
        case let .array(a):
            let strs = a.compactMap(\.stringValue)
            return strs.count == a.count ? strs.joined(separator: ", ") : "\(a.count) items"
        case .object:
            return String(v.jsonString.prefix(120))
        }
    }
}

/// Three blinking dots shown while the assistant's reply is in flight.
struct TypingDots: View {
    let color: Color
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle().frame(width: 6, height: 6).foregroundStyle(color)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
    }
}
