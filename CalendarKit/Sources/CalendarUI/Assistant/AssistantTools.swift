// The assistant's tool registry. Stage 1 = the read-only calendar tools, ported from
// src/lib/assistant/tools/calendar.ts (the mutating create/update/delete tools + web + memory
// tools arrive in later stages). Each tool reads the shared CalendarEngine via ToolContext.

import CalendarEngine
import CalendarGeometry // Repeat / YMD / occKey — recurrence config + occurrence-level delete
import Foundation

/// ── Registry ────────────────────────────────────────────────────────────────────────
@MainActor
enum AssistantTools {
    static let all: [any AssistantTool] = [
        GetScreenStateTool(),
        ListEventsTool(),
        GetEventTool(),
        GetTracksTool(),
        GetDailyNoteTool(),
        SetDailyNoteTool(),
        ListTodosTool(),
        SetTrackNameTool(),
        SetViewTool(),
        CreateEventTool(),
        UpdateEventTool(),
        DeleteEventTool(),
        WebSearchTool(),
        WebOpenTool(),
        RememberTool(),
        ForgetTool(),
    ]

    static func tool(named name: String) -> (any AssistantTool)? {
        all.first { $0.def.name == name }
    }

    static var defs: [ToolDef] {
        all.map(\.def)
    }
}

/// ── get_screen_state ──────────────────────────────────────────────────────────────────
struct GetScreenStateTool: AssistantTool {
    let def = ToolDef(
        name: "get_screen_state",
        description: "Return the calendar's current on-screen state: year, zoom level, and focused month.",
        parameters: .parse(#"{"type":"object","properties":{},"additionalProperties":false}"#)
    )
    let readOnly = true
    let actionKind = ActionKind.getScreenState
    func card(_ args: JSONValue, result: JSONValue) -> String {
        let zoom = (result["zoom"]?.stringValue ?? "view").capitalized
        let month = result["focusedMonthName"]?.stringValue ?? ""
        let year = result["year"]?.intValue.map(String.init) ?? ""
        return "View: \(zoom) · \(month) \(year)"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return .obj([
            "year": .num(e.year),
            "zoom": .str(zoomName(e)),
            "focusedMonth": .num(e.focus),
            "focusedMonthName": .str(monthName(e.focus)),
            "today": .str(iso(now.year ?? e.year, (now.month ?? 1) - 1, now.day ?? 1)),
        ])
    }
}

/// ── list_events ───────────────────────────────────────────────────────────────────────
struct ListEventsTool: AssistantTool {
    private static let cap = 120 // never dump a whole year into the context

    let def = ToolDef(
        name: "list_events",
        description: "List calendar items: timed events, bands, and deadlines. PREFER a from/to "
            + "window scoped to the question ('today' → that one day; 'this week' → those 7 days) — "
            + "bands overlapping the window are included. Optionally filter by kind or a text query "
            + "(matches title, tags, notes). Results are date-sorted and capped at 120.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "from":{"type":"string","description":"YYYY-MM-DD — window start (inclusive)."},
          "to":{"type":"string","description":"YYYY-MM-DD — window end (inclusive). With from, bands overlapping the window are included."},
          "year":{"type":"integer","description":"Whole-year listing when no from/to; defaults to the focused year."},
          "kind":{"type":"string","enum":["timed","band","deadline"],"description":"Filter to a single kind."},
          "query":{"type":"string","description":"Case-insensitive text search across title, tags, and notes."}
        },"additionalProperties":false}
        """#)
    )
    let readOnly = true
    let actionKind = ActionKind.readCalendar
    func card(_ args: JSONValue, result: JSONValue) -> String {
        let count = result["count"]?.intValue ?? 0
        let scope = result["range"]?.stringValue ?? result["year"]?.intValue.map(String.init) ?? ""
        let q = args["query"]?.stringValue.map { " · “\($0)”" } ?? ""
        return "Lookup: \(count) item\(count == 1 ? "" : "s") · \(scope)\(q)"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        let kind = args["kind"]?.stringValue
        let query = args["query"]?.stringValue?.lowercased()

        // Window: either endpoint alone means a single-day window.
        var from = args["from"]?.stringValue.flatMap(parseDate)
        var to = args["to"]?.stringValue.flatMap(parseDate)
        if from == nil {
            from = to
        }
        if to == nil {
            to = from
        }
        func key(_ y: Int, _ m: Int, _ d: Int) -> Int {
            y * 10000 + (m + 1) * 100 + d
        }
        let fromKey = from.map { key($0.0, $0.1, $0.2) } ?? Int.min
        let toKey = to.map { key($0.0, $0.1, $0.2) } ?? Int.max
        let years: [Int] = if let f = from, let t = to {
            Array(min(f.0, t.0) ... max(f.0, t.0))
        } else {
            [args["year"]?.intValue ?? e.year]
        }

        func matches(_ title: String, _ id: String) -> Bool {
            guard let query else { return true }
            if title.lowercased().contains(query) {
                return true
            }
            if e.richTags(id).joined(separator: " ").lowercased().contains(query) {
                return true
            }
            return e.notes(id).lowercased().contains(query)
        }

        var items: [(k: Int, v: JSONValue)] = []
        for y in years {
            if kind == nil || kind == "timed" {
                for ev in e.displayEvents(for: y) {
                    let k = key(ev.year, ev.month, ev.day)
                    guard k >= fromKey, k <= toKey, matches(ev.title, ev.id) else { continue }
                    items.append((k, .obj([
                        "id": .str(ev.id), "kind": .str("timed"),
                        "date": .str(iso(ev.year, ev.month, ev.day)),
                        "weekday": .str(weekday(ev.year, ev.month, ev.day)),
                        "start": .str(hhmm(ev.startHour)), "end": .str(hhmm(ev.endHour)),
                        "title": .str(ev.title), "color": .str(ev.color),
                    ])))
                }
            }
            if kind == nil || kind == "band" {
                for b in e.displayBands(for: y) {
                    // Bands OVERLAP the window (not just start inside it).
                    let s = key(b.year, b.month, b.startDay), t = key(b.year, b.month, b.endDay)
                    guard s <= toKey, t >= fromKey, matches(b.title, b.id) else { continue }
                    items.append((s, .obj([
                        "id": .str(b.id), "kind": .str("band"), "track": .num(laneOut(b.track)),
                        "start": .str(iso(b.year, b.month, b.startDay)),
                        "end": .str(iso(b.year, b.month, b.endDay)),
                        "title": .str(b.title), "color": .str(b.color),
                    ])))
                }
            }
            if kind == nil || kind == "deadline" {
                for d in e.displayDeadlines(for: y) {
                    let k = key(d.year, d.month, d.day)
                    guard k >= fromKey, k <= toKey, matches(d.title, d.id) else { continue }
                    items.append((k, .obj([
                        "id": .str(d.id), "kind": .str("deadline"),
                        "date": .str(iso(d.year, d.month, d.day)),
                        "weekday": .str(weekday(d.year, d.month, d.day)),
                        "time": .str(hhmm(d.hour)),
                        "title": .str(d.title), "color": .str(d.color),
                    ])))
                }
            }
        }
        items.sort { $0.k < $1.k }

        var out: [String: JSONValue] = [
            "count": .num(items.count),
            "events": .arr(items.prefix(Self.cap).map(\.v)),
        ]
        if let f = from, let t = to {
            out["range"] = .str("\(iso(f.0, f.1, f.2)) – \(iso(t.0, t.1, t.2))")
        } else {
            out["year"] = .num(years[0])
        }
        if items.count > Self.cap {
            out["truncated"] = .str("showing the first \(Self.cap) of \(items.count) — narrow with from/to or query")
        }
        return .obj(out)
    }
}

/// ── get_event ─────────────────────────────────────────────────────────────────────────
struct GetEventTool: AssistantTool {
    let def = ToolDef(
        name: "get_event",
        description: "Full detail for ONE item by id: title, when, color, tags, notes, promoted "
            + "lane, repeat, timezone. Use after list_events when you need the notes/details.",
        parameters: .parse(
            #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#
        )
    )
    let readOnly = true
    let actionKind = ActionKind.readCalendar
    func card(_ args: JSONValue, result: JSONValue) -> String {
        if let err = result["error"]?.stringValue {
            return "Lookup failed: \(err)"
        }
        return "Lookup: “\(result["title"]?.stringValue ?? "event")” detail"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        guard let id = args["id"]?.stringValue else { return .obj(["error": .str("missing 'id'")]) }
        guard let kind = e.kind(of: id) else { return .obj(["error": .str("no item with id \(id)")]) }
        var out: [String: JSONValue] = ["id": .str(id), "kind": .str(kind.rawValue)]
        switch kind {
        case .timed:
            guard let ev0 = e.event(id) else { break }
            let ev = e.displayEvent(ev0) // convert to the current view timezone (matches list_events + the prompt)
            out["title"] = .str(ev.title); out["color"] = .str(ev.color)
            out["date"] = .str(iso(ev.year, ev.month, ev.day))
            out["weekday"] = .str(weekday(ev.year, ev.month, ev.day))
            out["start"] = .str(hhmm(ev.startHour)); out["end"] = .str(hhmm(ev.endHour))
            if let tz = ev0
                .anchorTz {
                out["anchorTz"] = .str(tz)
            } // the event's own zone (times above are in the view zone)
        case .band:
            guard let b = e.band(id) else { break }
            out["title"] = .str(b.title); out["color"] = .str(b.color); out["track"] = .num(laneOut(b.track))
            out["start"] = .str(iso(b.year, b.month, b.startDay))
            out["end"] = .str(iso(b.year, b.month, b.endDay))
        case .deadline:
            guard let d0 = e.deadline(id) else { break }
            let d = e.displayDeadline(d0) // convert to the current view timezone
            out["title"] = .str(d.title); out["color"] = .str(d.color)
            out["date"] = .str(iso(d.year, d.month, d.day))
            out["weekday"] = .str(weekday(d.year, d.month, d.day))
            out["time"] = .str(hhmm(d.hour))
            if let tz = d0
                .anchorTz {
                out["anchorTz"] = .str(tz)
            } // the deadline's own zone (time above is in the view zone)
        }
        let tags = e.richTags(id)
        if !tags.isEmpty {
            out["tags"] = .arr(tags.map(JSONValue.str))
        }
        let notes = e.notes(id)
        if !notes.isEmpty {
            out["notes"] = .str(String(notes.prefix(2000)))
        }
        if let lane = e.promoteTrack(id) {
            out["promoteTrack"] = .num(laneOut(lane))
        }
        if let r = e.repeatConfig(id) {
            out["repeats"] = .str(r.kind)
        }
        return .obj(out)
    }
}

/// ── get_daily_note / set_daily_note (the dashboard NOTE tab) ──────────────────────────
struct GetDailyNoteTool: AssistantTool {
    let def = ToolDef(
        name: "get_daily_note",
        description: "Read the user's free-form daily note (the day view's NOTE tab, markdown — "
            + "often holds TODOs and plans) for a date.",
        parameters: .parse(
            #"{"type":"object","properties":{"date":{"type":"string","description":"YYYY-MM-DD"}},"required":["date"],"additionalProperties":false}"#
        )
    )
    let readOnly = true
    let actionKind = ActionKind.readCalendar
    func card(_ args: JSONValue, result: JSONValue) -> String {
        "Lookup: daily note · \(args["date"]?.stringValue ?? "")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        guard let date = args["date"]?.stringValue, parseDate(date) != nil else {
            return .obj(["error": .str("missing or invalid 'date' (YYYY-MM-DD)")])
        }
        let note = e.dailyNote(date)
        return .obj(["date": .str(date), "note": .str(String(note.prefix(4000))),
                     "empty": .bool(note.isEmpty)])
    }
}

struct SetDailyNoteTool: AssistantTool {
    let def = ToolDef(
        name: "set_daily_note",
        description: "Replace a date's daily note (markdown). Read it first with get_daily_note and "
            + "preserve what the user already wrote unless asked to remove it.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "date":{"type":"string","description":"YYYY-MM-DD"},
          "note":{"type":"string","description":"The full new markdown note ('' clears it)."}
        },"required":["date","note"],"additionalProperties":false}
        """#)
    )
    let readOnly = false // writes user data → auditor-gated
    let actionKind = ActionKind.setDailyNote
    func card(_ args: JSONValue, result: JSONValue) -> String {
        if let err = result["error"]?.stringValue {
            return "Note update failed: \(err)"
        }
        return "Updated daily note · \(args["date"]?.stringValue ?? "")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        guard let date = args["date"]?.stringValue, parseDate(date) != nil else {
            return .obj(["error": .str("missing or invalid 'date' (YYYY-MM-DD)")])
        }
        e.setDailyNote(date, args["note"]?.stringValue ?? "")
        return .obj(["ok": .bool(true), "date": .str(date)])
    }
}

/// AI-facing track numbers are 1-BASED (1–4, top to bottom — how users speak: "the 3rd track"
/// is track 3). The engine stores 0-based lanes; convert at THIS boundary only.
private func laneIn(_ n: Int?) -> Int? {
    n.map { max(0, min(3, $0 - 1)) }
}

private func laneOut(_ n: Int) -> Double {
    Double(n + 1)
}

/// ── get_tracks ────────────────────────────────────────────────────────────────────────
struct GetTracksTool: AssistantTool {
    let def = ToolDef(
        name: "get_tracks",
        description: "Return the four band-lane names (tracks 1–4, top to bottom) for each of the 12 months.",
        parameters: .parse(#"{"type":"object","properties":{"year":{"type":"integer"}},"additionalProperties":false}"#)
    )
    let readOnly = true
    let actionKind = ActionKind.readCalendar
    func card(_ args: JSONValue, result: JSONValue) -> String {
        "Lookup: track names"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        // trackNames is [[String]] — one 4-element lane-name array per month (0–11). Emit
        // explicit 1-based track numbers so the model never guesses at array indexing.
        let byMonth = e.items.trackNames.map { names in
            JSONValue.arr(names.enumerated().map { i, n in
                JSONValue.obj(["track": .num(Double(i + 1)), "name": .str(n)])
            })
        }
        return .obj(["note": .str("Tracks are numbered 1–4, top to bottom."),
                     "trackNamesByMonth": .arr(byMonth)])
    }
}

/// ── set_view ──────────────────────────────────────────────────────────────────────────
struct SetViewTool: AssistantTool {
    let def = ToolDef(
        name: "set_view",
        description: "Navigate the calendar UI. Switch year, focus a month (0–11), zoom to "
            + "'year' | 'month' | 'week' | 'day', or pass 'date' to fly straight to that day's "
            + "daily view. Only the fields you provide change. Read-only w.r.t. data.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "year":{"type":"integer"},
          "zoom":{"type":"string","enum":["year","month","week","day"]},
          "focusedMonth":{"type":"integer","minimum":0,"maximum":11,"description":"0 = January."},
          "date":{"type":"string","description":"YYYY-MM-DD — fly to this specific day (opens the day view)."}
        },"additionalProperties":false}
        """#)
    )
    // UI navigation only — not a data mutation, so not auditor-gated (matches the web set_view).
    let readOnly = true
    let actionKind = ActionKind.setView
    func card(_ args: JSONValue, result: JSONValue) -> String {
        let month = monthName(result["focusedMonth"]?.intValue ?? 0)
        let year = result["year"]?.intValue ?? 0
        let zoom = result["zoom"]?.stringValue ?? ""
        // e.g. "Navigation: Sep 2026 · month"
        return "Navigation: \(month) \(year)\(zoom.isEmpty ? "" : " · \(zoom)")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        // Report the DESTINATION, not the live state — navigation is an animated flight that can
        // pass through the year view, so reading the zoom immediately would lie ("year").
        if let ds = args["date"]?.stringValue, let (y, m, d) = parseDate(ds) {
            e.setView(year: y, zoom: args["zoom"]?.stringValue, focusedMonth: m, day: d)
            return .obj(["ok": .bool(true), "year": .num(y), "zoom": .str("day"),
                         "focusedMonth": .num(m), "date": .str(ds)])
        }
        e.setView(year: args["year"]?.intValue,
                  zoom: args["zoom"]?.stringValue,
                  focusedMonth: args["focusedMonth"]?.intValue)
        return .obj([
            "ok": .bool(true),
            "year": .num(args["year"]?.intValue ?? e.year),
            "zoom": .str(args["zoom"]?.stringValue ?? zoomName(e)),
            "focusedMonth": .num(args["focusedMonth"]?.intValue ?? e.focus),
        ])
    }
}

/// ── create_event (mutating → auditor-gated) ─────────────────────────────────────────────
struct CreateEventTool: AssistantTool {
    let def = ToolDef(
        name: "create_event",
        description: "Create a calendar item. kind='timed' needs date + start/end times; "
            + "kind='band' is an all-day bar (date = start day, optional endDate, track 1–4); "
            + "kind='deadline' is a due moment (date + time via 'start'). Times are 'HH:MM' (24h).",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "kind":{"type":"string","enum":["timed","band","deadline"]},
          "title":{"type":"string"},
          "date":{"type":"string","description":"YYYY-MM-DD (band: the start day)."},
          "endDate":{"type":"string","description":"YYYY-MM-DD — band end day (same month). Optional."},
          "start":{"type":"string","description":"HH:MM — timed start, or the deadline's time."},
          "end":{"type":"string","description":"HH:MM — timed end."},
          "track":{"type":"integer","minimum":1,"maximum":4,"description":"Band lane 1–4, top to bottom (users say \\"the 3rd track\\" for track 3)."},
          "color":{"type":"string","description":"Named color, e.g. blue/green/red/orange/purple."},
          "promoteTrack":{"type":"integer","minimum":1,"maximum":4,"description":"Mirror a timed/deadline onto this monthly track lane (1–4, top to bottom) as a ghost band."},
          "timezone":{"type":"string","description":"IANA id (e.g. Asia/Tokyo) or \"AOE\" — the zone 'date'/'start'/'end' are stated in. The item is ANCHORED to that zone: the original wall-clock time is stored verbatim and the calendar converts for display. Use whenever the source has a clear native timezone (a JST broadcast, an AOE CfP). timed + deadline only."},
          "repeat":{"type":"object","description":"Recurrence.","properties":{
            "kind":{"type":"string","enum":["daily","weekly","weekdays","yearly"]},
            "n":{"type":"integer","description":"Every n weeks/years (default 1)."},
            "until":{"type":"string","description":"YYYY-MM-DD inclusive end (term bound)."},
            "days":{"type":"array","items":{"type":"integer","minimum":0,"maximum":6},"description":"Weekdays for weekly, 0=Sun."},
            "exdates":{"type":"array","items":{"type":"string"},"description":"YYYY-MM-DD dates to skip (holidays/breaks)."}
          }},
          "notes":{"type":"string"},
          "tags":{"type":"array","items":{"type":"string"}}
        },"required":["kind","title","date"],"additionalProperties":false}
        """#)
    )
    let readOnly = false
    let actionKind = ActionKind.createEvent
    func card(_ args: JSONValue, result: JSONValue) -> String {
        if let err = result["error"]?.stringValue {
            return "Create failed: \(err)"
        }
        let title = args["title"]?.stringValue ?? "event"
        let kind = result["kind"]?.stringValue ?? "item"
        let segments = result["segments"]?.intValue ?? 1
        let span = segments > 1 ? " (\(segments) months)" : ""
        return "Created \(kind)\(span): \(title)"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        guard let kind = args["kind"]?.stringValue else { return .obj(["error": .str("missing 'kind'")]) }
        guard let dateStr = args["date"]?.stringValue, let (y, m, d) = parseDate(dateStr) else {
            return .obj(["error": .str("missing or invalid 'date' (expected YYYY-MM-DD)")])
        }
        let title = args["title"]?.stringValue ?? "New event"
        let color = args["color"]?.stringValue ?? "blue"
        let notes = mdUnescape(args["notes"]?.stringValue)
        let tags = (args["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
        let anchorTz = args["timezone"]?.stringValue

        let promote = laneIn(args["promoteTrack"]?.intValue)
        let repeatCfg = repeatConfig(from: args["repeat"])

        switch kind {
        case "timed":
            let start = args["start"]?.stringValue.flatMap(parseTime) ?? 9
            let end = args["end"]?.stringValue.flatMap(parseTime) ?? min(24, start + 1)
            let id = e.createTimedEvent(year: y, month: m, day: d, startHour: start,
                                        endHour: max(start + 0.25, end), title: title, color: color,
                                        notes: notes, tags: tags, promoteTrack: promote,
                                        anchorTz: anchorTz, byAI: true)
            if let repeatCfg {
                e.setRepeat(id, repeatCfg)
            }
            // Echo the PARSED rule so the model can verify what was actually stored (a malformed
            // days list used to be dropped silently while the model reported success).
            var out: [String: JSONValue] = ["ok": .bool(true), "id": .str(id), "kind": .str("timed")]
            if let r = repeatCfg {
                out["repeat"] = .str("\(r.kind)"
                    + (r.days.map { " days:\($0)" } ?? "")
                    + (r.until.map { " until:\($0)" } ?? "")
                    + ((r.exdates?.isEmpty == false) ? " exdates:\(r.exdates!.count)" : ""))
            }
            return .obj(out)
        case "band":
            // A band may span months; the engine splits a cross-month range into one segment per
            // month. Default the end to the start day (a one-day band) when no endDate is given.
            let end = args["endDate"]?.stringValue.flatMap(parseDate) ?? (y, m, d)
            let track = laneIn(args["track"]?.intValue) ?? 0
            let ids = e.createBandSpan(startYear: y, startMonth: m, startDay: d,
                                       endYear: end.0, endMonth: end.1, endDay: end.2, track: track,
                                       title: title, color: color, notes: notes, tags: tags, byAI: true)
            if let repeatCfg, let first = ids.first {
                e.setRepeat(first, repeatCfg)
            }
            return .obj([
                "ok": .bool(true), "kind": .str("band"),
                "id": .str(ids.first ?? ""), "segments": .num(ids.count),
                "ids": .arr(ids.map(JSONValue.str)),
                "repeats": .bool(repeatCfg != nil),
            ])
        case "deadline":
            let hour = args["start"]?.stringValue.flatMap(parseTime) ?? 17
            // With `timezone`, the given date+time ARE that zone's wall clock — stored verbatim,
            // anchored there (the calendar converts for display; the original time survives).
            let id = e.createDeadline(year: y, month: m, day: d, hour: hour, title: title,
                                      color: color, notes: notes, tags: tags,
                                      promoteTrack: promote, anchorTz: anchorTz, byAI: true)
            if let repeatCfg {
                e.setRepeat(id, repeatCfg)
            }
            var out: [String: JSONValue] = ["ok": .bool(true), "id": .str(id), "kind": .str("deadline"),
                                            "date": .str(iso(y, m, d)), "time": .str(hhmm(hour))]
            if let anchorTz {
                out["anchoredTz"] = .str(anchorTz)
            }
            return .obj(out)
        default:
            return .obj(["error": .str("unknown kind '\(kind)'")])
        }
    }
}

/// ── update_event (mutating → auditor-gated) ─────────────────────────────────────────────
struct UpdateEventTool: AssistantTool {
    let def = ToolDef(
        name: "update_event",
        description: "Edit an existing item by id. Provide a 'patch' with only the fields to change. "
            + "Dates are 'YYYY-MM-DD', times 'HH:MM'. Moving a band's date/endDate re-spans it "
            + "(including across months). Get ids from list_events.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "id":{"type":"string"},
          "patch":{"type":"object","properties":{
            "title":{"type":"string"},"color":{"type":"string"},
            "date":{"type":"string","description":"YYYY-MM-DD. For a band: the new start day (length is kept unless endDate is also given)."},
            "endDate":{"type":"string","description":"YYYY-MM-DD — band end day (may be a different month)."},
            "start":{"type":"string","description":"HH:MM (timed start / deadline time)."},
            "end":{"type":"string","description":"HH:MM (timed end)."},
            "track":{"type":"integer","minimum":1,"maximum":4},
            "promoteTrack":{"type":["integer","null"],"minimum":1,"maximum":4,"description":"Lane 1–4 (top to bottom) to mirror onto; null clears the promotion."},
            "repeat":{"type":["object","null"],"description":"Recurrence {kind,n,until,days,exdates} — same shape as create_event; null or kind 'none' clears it. To skip single dates, set/extend exdates."},
            "notes":{"type":"string","description":"REPLACES the notes."},
            "appendNotes":{"type":"string","description":"Appends to the existing notes (e.g. add a TODO line) without touching what's there."},
            "tags":{"type":"array","items":{"type":"string"}}
          }}
        },"required":["id","patch"],"additionalProperties":false}
        """#)
    )
    let readOnly = false
    let actionKind = ActionKind.updateEvent
    func card(_ args: JSONValue, result: JSONValue) -> String {
        if let err = result["error"]?.stringValue {
            return "Update failed: \(err)"
        }
        if result["ok"]?.boolValue == false {
            return "Update failed: item not found"
        }
        if let title = args["patch"]?["title"]?.stringValue {
            return "Updated: \(title)"
        }
        return "Updated \(result["kind"]?.stringValue ?? "event")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        guard let id = args["id"]?.stringValue else { return .obj(["error": .str("missing 'id'")]) }
        guard let itemKind = e.kind(of: id) else { return .obj(["error": .str("no item with id \(id)")]) }
        let patch = args["patch"] ?? .null

        // notes: replace, or append to what's already there (the TODO-in-notes flow).
        var notes = mdUnescape(patch["notes"]?.stringValue)
        if notes == nil, let extra = mdUnescape(patch["appendNotes"]?.stringValue), !extra.isEmpty {
            let existing = e.notes(id)
            notes = existing.isEmpty ? extra : existing + "\n" + extra
        }

        // repeat: object sets the recurrence, null / kind "none" clears it.
        if let rv = patch["repeat"] {
            if case .null = rv {
                e.setRepeat(id, nil)
            } else {
                e.setRepeat(id, repeatConfig(from: rv))
            }
        }

        // promoteTrack: an integer sets the mirror lane; an explicit JSON null clears it.
        var promote: Int? = nil, clearPromote = false
        if let pv = patch["promoteTrack"] {
            if case .null = pv {
                clearPromote = true
            } else {
                promote = laneIn(pv.intValue)
            }
        }

        // Band moves/resizes re-span the band (handles cross-month ranges by splitting per month).
        if itemKind == .band, patch["date"] != nil || patch["endDate"] != nil {
            guard let b = e.band(id) else { return .obj(["error": .str("no item with id \(id)")]) }
            let start = patch["date"]?.stringValue.flatMap(parseDate) ?? (b.year, b.month, b.startDay)
            let end: (Int, Int, Int) = if let pe = patch["endDate"]?.stringValue.flatMap(parseDate) {
                pe
            } else if patch["date"] != nil {
                addDays(start, b.endDay - b.startDay)
            } // keep length
            else {
                (b.year, b.month, b.endDay)
            }
            // Apply the non-geometry fields first so the re-span carries them over.
            e.updateItem(id: id, title: patch["title"]?.stringValue, color: patch["color"]?.stringValue,
                         track: laneIn(patch["track"]?.intValue), notes: notes,
                         tags: patch["tags"]?.arrayValue?.compactMap(\.stringValue), byAI: true)
            let ids = e.reshapeBand(id: id, startYear: start.0, startMonth: start.1, startDay: start.2,
                                    endYear: end.0, endMonth: end.1, endDay: end.2)
            return .obj(["ok": .bool(!ids.isEmpty), "id": .str(ids.first ?? id),
                         "kind": .str("band"), "segments": .num(ids.count)])
        }

        var year: Int?, month: Int?, day: Int?
        var startHour: CGFloat?, endHour: CGFloat?, hour: CGFloat?
        if let ds = patch["date"]?.stringValue, let (py, pm, pd) = parseDate(ds) {
            year = py; month = pm; day = pd
        }
        if let ss = patch["start"]?.stringValue, let t = parseTime(ss) {
            if itemKind == .deadline {
                hour = t
            } else {
                startHour = t
            }
        }
        if let ee = patch["end"]?.stringValue, let t = parseTime(ee) {
            endHour = t
        }

        let ok = e.updateItem(
            id: id, title: patch["title"]?.stringValue, color: patch["color"]?.stringValue,
            year: year, month: month, day: day, startHour: startHour, endHour: endHour,
            track: laneIn(patch["track"]?.intValue), hour: hour,
            notes: notes,
            tags: patch["tags"]?.arrayValue?.compactMap(\.stringValue),
            promoteTrack: promote, clearPromote: clearPromote, byAI: true
        )
        return .obj(["ok": .bool(ok), "id": .str(id), "kind": .str(itemKind.rawValue)])
    }
}

/// ── delete_event (mutating + confirm → resolve-only, UI-confirmed) ──────────────────────
struct DeleteEventTool: AssistantTool {
    let def = ToolDef(
        name: "delete_event",
        description: "Delete a calendar item by id. This does NOT delete immediately — it stages the "
            + "deletion and asks the user to confirm in the UI. For a RECURRING event, pass "
            + "occurrenceDate to remove only that one occurrence (a skip) — never delete the whole "
            + "series for a single skip. Get ids from list_events.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "id":{"type":"string"},
          "occurrenceDate":{"type":"string","description":"YYYY-MM-DD — remove only this occurrence of a recurring event (punches an exdate hole), not the series."}
        },"required":["id"],"additionalProperties":false}
        """#)
    )
    let readOnly = false
    let confirm = true
    let actionKind = ActionKind.deleteEvent
    func card(_ args: JSONValue, result: JSONValue) -> String {
        if let err = result["error"]?.stringValue {
            return "Delete failed: \(err)"
        }
        let title = result["title"]?.stringValue ?? "item"
        if let od = result["occurrenceDate"]?.stringValue {
            return "Confirm skip: \(title) · \(od)"
        }
        return "Confirm delete: \(title)"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        guard let id = args["id"]?.stringValue else { return .obj(["error": .str("missing 'id'")]) }
        guard let kind = e.kind(of: id) else { return .obj(["error": .str("no item with id \(id)")]) }
        let title: String = switch kind {
        case .timed: e.event(id)?.title ?? "event"
        case .band: e.band(id)?.title ?? "band"
        case .deadline: e.deadline(id)?.title ?? "deadline"
        }
        let date = e.dateOf(id).map { iso($0.0, $0.1, $0.2) } ?? ""
        // RESOLVE ONLY — do NOT delete here. The UI confirmation card triggers the actual removal.
        var out: [String: JSONValue] = [
            "staged": .bool(true), "awaiting_user_confirmation": .bool(true),
            "id": .str(id), "kind": .str(kind.rawValue), "title": .str(title), "date": .str(date),
        ]
        if let od = args["occurrenceDate"]?.stringValue {
            guard parseDate(od) != nil else { return .obj(["error": .str("invalid occurrenceDate")]) }
            guard e.repeatConfig(id) != nil else {
                return .obj(["error": .str("item \(id) is not recurring — omit occurrenceDate to delete it")])
            }
            out["occurrenceDate"] = .str(od)
            out["mode"] = .str("occurrence")
        } else {
            out["mode"] = .str("series")
        }
        return .obj(out)
    }
}

/// ── list_todos — the TODO panel's contents ──────────────────────────────────────────────
struct ListTodosTool: AssistantTool {
    private static let cap = 100

    let def = ToolDef(
        name: "list_todos",
        description: "List the user's TODOs — the markdown checkboxes the TODO panel gathers from "
            + "event notes and daily notes. Each entry has text, done, due date (if any), priority "
            + "(1–5 from p:!…), tags, and its source. Use for 'what should I work on' questions "
            + "alongside list_events. Default: unchecked only.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "includeDone":{"type":"boolean","description":"Also include checked-off items (default false)."},
          "query":{"type":"string","description":"Case-insensitive text filter."},
          "dueFrom":{"type":"string","description":"YYYY-MM-DD — drop DATED todos due before this (undated ones stay)."},
          "dueTo":{"type":"string","description":"YYYY-MM-DD — drop DATED todos due after this (undated ones stay)."}
        },"additionalProperties":false}
        """#)
    )
    let readOnly = true
    let actionKind = ActionKind.readCalendar
    func card(_ args: JSONValue, result: JSONValue) -> String {
        let n = result["count"]?.intValue ?? 0
        return "Lookup: \(n) todo\(n == 1 ? "" : "s")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        let includeDone = args["includeDone"]?.boolValue ?? false
        let query = args["query"]?.stringValue?.lowercased()
        let dueFrom = args["dueFrom"]?.stringValue
        let dueTo = args["dueTo"]?.stringValue

        var todos: [(sort: String, v: JSONValue)] = []
        func harvest(_ notes: String, source: [String: JSONValue]) {
            for raw in notes.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard let m = line.range(of: #"^[-*]\s*\[( |x|X)\]\s*"#, options: .regularExpression)
                else { continue }
                let checked = line.range(of: #"^[-*]\s*\[[xX]\]"#, options: .regularExpression) != nil
                if checked && !includeDone {
                    continue
                }
                let text = String(line[m.upperBound...])
                if let query, !text.lowercased().contains(query) {
                    continue
                }

                let due = text.range(of: #"due:(\d{4}-\d{2}-\d{2})"#, options: .regularExpression)
                    .map { String(text[$0].dropFirst(4)) }
                if let due {
                    if let dueFrom, due < dueFrom {
                        continue
                    }
                    if let dueTo, due > dueTo {
                        continue
                    }
                }
                let bangs = text.range(of: #"\bp:(!{1,5})"#, options: .regularExpression)
                    .map { text[$0].filter { $0 == "!" }.count }
                let tags: [String] = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .compactMap { word in
                        guard word.hasPrefix("#"), word.count > 1 else { return nil }
                        let t = word.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                        return t.isEmpty ? nil : String(t)
                    }

                var entry = source
                entry["text"] = .str(text)
                entry["done"] = .bool(checked)
                if let due {
                    entry["due"] = .str(due)
                }
                if let bangs {
                    entry["priority"] = .num(bangs)
                }
                if !tags.isEmpty {
                    entry["tags"] = .arr(tags.map(JSONValue.str))
                }
                todos.append((due ?? "9999", .obj(entry)))
            }
        }

        for item in e.notedItems() {
            harvest(item.notes, source: [
                "source": .str("event"), "eventId": .str(item.id),
                "eventTitle": .str(item.title), "eventDate": .str(iso(item.year, item.month, item.day)),
            ])
        }
        for (date, note) in e.allDailyNotes() {
            harvest(note, source: ["source": .str("dailyNote"), "date": .str(date)])
        }

        todos.sort { $0.sort < $1.sort } // dated first (ascending), undated after
        var out: [String: JSONValue] = [
            "count": .num(todos.count),
            "todos": .arr(todos.prefix(Self.cap).map(\.v)),
        ]
        if todos.count > Self.cap {
            out["truncated"] =
                .str("showing the first \(Self.cap) of \(todos.count) — narrow with query or dueFrom/dueTo")
        }
        return .obj(out)
    }
}

/// ── set_track_name (mutating → auditor-gated) ───────────────────────────────────────────
struct SetTrackNameTool: AssistantTool {
    let def = ToolDef(
        name: "set_track_name",
        description: "Rename one of the four monthly track lanes. Check current names with get_tracks.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "month":{"type":"integer","minimum":0,"maximum":11,"description":"0 = January."},
          "track":{"type":"integer","minimum":1,"maximum":4},
          "name":{"type":"string"}
        },"required":["month","track","name"],"additionalProperties":false}
        """#)
    )
    let readOnly = false
    let actionKind = ActionKind.setTrackName
    func card(_ args: JSONValue, result: JSONValue) -> String {
        if let err = result["error"]?.stringValue {
            return "Rename failed: \(err)"
        }
        let m = args["month"]?.intValue.map(monthName) ?? "?"
        return "Renamed lane \(args["track"]?.intValue ?? 1) (\(m)): \(args["name"]?.stringValue ?? "")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let e = ctx.engine else { return .obj(["error": .str("calendar unavailable")]) }
        guard let m = args["month"]?.intValue, (0 ... 11).contains(m),
              let t = args["track"]?.intValue, (1 ... 4).contains(t),
              let name = args["name"]?.stringValue else {
            return .obj(["error": .str("need month (0–11), track (1–4), and name")])
        }
        e.setTrackName(m, t - 1, name)
        return .obj(["ok": .bool(true), "month": .num(m), "track": .num(Double(t)), "name": .str(name)])
    }
}

// ── Shared formatting helpers ─────────────────────────────────────────────────────────
// Month/weekday names come from CalendarGeometry's canonical MONTH_NAMES / WD3.

private func monthName(_ m: Int) -> String {
    MONTH_NAMES.indices.contains(m) ? MONTH_NAMES[m] : "?"
}

@MainActor private func zoomName(_ e: CalendarEngine) -> String {
    e.isDayLevel ? "day" : e.isWeekLevel ? "week" : e.isMonthLevel ? "month" : "year"
}

private func iso(_ y: Int, _ m: Int, _ d: Int) -> String {
    String(format: "%04d-%02d-%02d", y, m + 1, d)
}

private func hhmm(_ h: CGFloat) -> String {
    let total = max(0, Int((h * 60).rounded()))
    return String(format: "%02d:%02d", (total / 60) % 24, total % 60)
}

/// Recurrence config from a tool's `repeat` argument; nil when absent/none/invalid.
/// Tolerant on two REAL model mistakes (caught by eval trajectory S001, where they silently
/// produced a Tuesdays-only series for a Tue/Thu class):
///   • day NAMES ("TUE"/"Thursday") coerce to 0=Sun..6=Sat integers
///   • kind "weekly" WITH a multi-day list upgrades to "weekdays" (weekly ignores `days`)
private func repeatConfig(from v: JSONValue?) -> Repeat? {
    guard let o = v?.asObject, var kind = o["kind"]?.stringValue, kind != "none" else { return nil }
    let dayNames = ["su": 0, "mo": 1, "tu": 2, "we": 3, "th": 4, "fr": 5, "sa": 6]
    let days = o["days"]?.arrayValue?.compactMap { d -> Int? in
        if let n = d.intValue {
            return (0 ... 6).contains(n) ? n : nil
        }
        guard let s = d.stringValue?.lowercased(), s.count >= 2 else { return nil }
        return dayNames[String(s.prefix(2))]
    }
    if kind == "weekly", (days?.count ?? 0) > 1 {
        kind = "weekdays"
    }
    return Repeat(kind: kind,
                  n: o["n"]?.intValue,
                  until: o["until"]?.stringValue,
                  days: days,
                  exdates: o["exdates"]?.arrayValue?.compactMap(\.stringValue))
}

/// (year, month0, day) + n days, in a DST-free UTC calendar.
private func addDays(_ ymd: (Int, Int, Int), _ n: Int) -> (Int, Int, Int) {
    let cal = utcCalendar
    var c = DateComponents(); c.year = ymd.0; c.month = ymd.1 + 1; c.day = ymd.2
    guard let d0 = cal.date(from: c), let d1 = cal.date(byAdding: .day, value: n, to: d0)
    else { return ymd }
    let o = cal.dateComponents([.year, .month, .day], from: d1)
    return (o.year ?? ymd.0, (o.month ?? 1) - 1, o.day ?? ymd.2)
}

/// Defensive Markdown unescape for the LLM's `notes`: models occasionally double-escape, leaving a
/// LITERAL backslash-n in the note text, which renders as "\n" instead of a line break. A real
/// backslash-n is never intended in calendar notes, so rewrite the common escapes.
private func mdUnescape(_ s: String?) -> String? {
    guard let s, s.contains("\\") else { return s }
    return s.replacingOccurrences(of: "\\r\\n", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\t", with: "  ")
}

private func weekday(_ y: Int, _ m: Int, _ d: Int) -> String {
    var c = DateComponents(); c.year = y; c.month = m + 1; c.day = d
    guard let date = Calendar(identifier: .gregorian).date(from: c) else { return "" }
    let wd = Calendar(identifier: .gregorian).component(.weekday, from: date) // 1 = Sun
    return WD3.indices.contains(wd - 1) ? WD3[wd - 1] : ""
}
