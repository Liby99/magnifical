// eventkit-bridge — a macOS EventKit helper for libirabu's calendar import (docs §5).
//
// Two ways to run it:
//   • CLI (for the one-time permission grant, via `open` so the APP is TCC-responsible):
//       eventkit-bridge list-calendars [--out <file>]
//       eventkit-bridge events --from <ISO> --to <ISO> [--calendars id,id] [--out <file>]
//   • launchd agent (how the server uses it — the app is its own responsible process, so the
//     existing grant applies without needing a prompt):
//       eventkit-bridge --serve-once --requests <dir>
//     It processes every "<id>.req.json" ({cmd, from?, to?, calendars?}) in <dir>, writing
//     "<id>.res.json" (JSON array on success, {"error":…} on failure) atomically, then exits.

import EventKit
import Foundation

let store = EKEventStore()

enum BridgeError: Error { case accessDenied(Int); case badRequest(String) }

/// ── access ───────────────────────────────────────────────────────────────────────────────────
func ensureAccess() throws {
    let status = EKEventStore.authorizationStatus(for: .event)
    if status.rawValue == 3 {
        return
    } // authorized / fullAccess (read)
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
    } else {
        store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
    }
    _ = sem.wait(timeout: .now() + 30)
    if !granted {
        throw BridgeError.accessDenied(Int(status.rawValue))
    }
}

/// ── formatters / mappers ───────────────────────────────────────────────────────────────────────
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
}()

let dayFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
}()

let untilFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC"); f
        .locale = Locale(identifier: "en_US_POSIX"); return f
}()

func statusString(_ s: EKParticipantStatus) -> String {
    switch s {
    case .accepted: "accepted"
    case .declined: "declined"
    case .tentative: "tentative"
    case .pending: "needs-action"
    default: "unknown"
    }
}

func emailOf(_ p: EKParticipant?) -> String {
    (p?.url).map { $0.absoluteString.replacingOccurrences(
        of: "mailto:",
        with: ""
    ) } ?? ""
}

let bydayToken: [Int: String] = [1: "SU", 2: "MO", 3: "TU", 4: "WE", 5: "TH", 6: "FR", 7: "SA"]
func rruleString(_ r: EKRecurrenceRule) -> String {
    var parts: [String] = []
    switch r.frequency {
    case .daily: parts.append("FREQ=DAILY")
    case .weekly: parts.append("FREQ=WEEKLY")
    case .monthly: parts.append("FREQ=MONTHLY")
    case .yearly: parts.append("FREQ=YEARLY")
    @unknown default: parts.append("FREQ=DAILY")
    }
    if r.interval > 1 {
        parts.append("INTERVAL=\(r.interval)")
    }
    if let days = r.daysOfTheWeek, !days.isEmpty {
        let tokens = days.compactMap { bydayToken[$0.dayOfTheWeek.rawValue] }
        if !tokens.isEmpty {
            parts.append("BYDAY=\(tokens.joined(separator: ","))")
        }
    }
    if let end = r.recurrenceEnd {
        if let d = end.endDate {
            parts.append("UNTIL=\(untilFormatter.string(from: d))")
        } else if end.occurrenceCount > 0 {
            parts.append("COUNT=\(end.occurrenceCount)")
        }
    }
    return parts.joined(separator: ";")
}

/// ── compute (throwing; no process exit — reusable by CLI and serve modes) ──────────────────────
func calendarsResult() throws -> Any {
    try ensureAccess()
    return store.calendars(for: .event).map { c -> [String: Any] in
        var color = ""
        if let cg = c.cgColor, let comps = cg.components, comps.count >= 3 {
            color = String(
                format: "#%02X%02X%02X",
                Int((comps[0] * 255).rounded()),
                Int((comps[1] * 255).rounded()),
                Int((comps[2] * 255).rounded())
            )
        }
        return ["id": c.calendarIdentifier, "title": c.title, "source": c.source.title,
                "sourceType": String(c.source.sourceType.rawValue), "color": color,
                "allowsModify": c.allowsContentModifications]
    }
}

func eventsResult(fromISO: String, toISO: String, calendarIds: [String]) throws -> Any {
    try ensureAccess()
    guard let from = isoFormatter.date(from: fromISO), let to = isoFormatter.date(from: toISO) else {
        throw BridgeError.badRequest("from/to must be ISO8601")
    }
    let all = store.calendars(for: .event)
    let selected = calendarIds.isEmpty ? all : all.filter { calendarIds.contains($0.calendarIdentifier) }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: selected)
    return store.events(matching: predicate).map { e -> [String: Any] in
        var obj: [String: Any] = [
            "uid": e.calendarItemExternalIdentifier ?? NSNull(),
            "localId": e.calendarItemIdentifier,
            "calendarId": e.calendar.calendarIdentifier,
            "title": e.title ?? "(untitled)",
            "allDay": e.isAllDay,
            "location": e.location ?? NSNull(),
            "notes": e.notes ?? NSNull(),
            "url": e.url?.absoluteString ?? NSNull(),
            "organizer": emailOf(e.organizer),
            "status": String(e.status.rawValue),
        ]
        if e.isAllDay {
            obj["start"] = dayFormatter.string(from: e.startDate)
            obj["end"] = dayFormatter.string(from: e.endDate)
        } else {
            obj["start"] = isoFormatter.string(from: e.startDate)
            obj["end"] = isoFormatter.string(from: e.endDate)
        }
        obj["attendees"] = (e.attendees ?? []).map { [
            "name": $0.name ?? "",
            "email": emailOf($0),
            "status": statusString($0.participantStatus),
        ] as [String: Any] }
        obj["rrule"] = e.recurrenceRules?.first.map { rruleString($0) } ?? NSNull()
        obj["lastModified"] = e.lastModifiedDate.map { isoFormatter.string(from: $0) } ?? NSNull()
        return obj
    }
}

func runRequest(cmd: String, from: String?, to: String?, calendars: [String]) -> Any {
    do {
        switch cmd {
        case "list-calendars": return try calendarsResult()
        case "events":
            guard let f = from, let t = to else { throw BridgeError.badRequest("events needs from/to") }
            return try eventsResult(fromISO: f, toISO: t, calendarIds: calendars)
        default: return ["error": "unknown command: \(cmd)"]
        }
    } catch let BridgeError.accessDenied(s) {
        return ["error": "access-denied status=\(s)"]
    } catch {
        return ["error": "\(error)"]
    }
}

func jsonString(_ value: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
          let s = String(data: d, encoding: .utf8) else { return "{\"error\":\"json-encode-failed\"}" }
    return s
}

func writeResult(_ s: String, to path: String?) {
    if let p = path {
        try? s.write(toFile: p, atomically: true, encoding: .utf8)
    } else {
        print(s)
    }
}

/// ── arg parsing ────────────────────────────────────────────────────────────────────────────────
func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func csv(_ s: String?) -> [String] {
    s.map { $0.split(separator: ",").map(String.init) } ?? []
}

let sub = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

// ── serve-once (launchd) ───────────────────────────────────────────────────────────────────────
if sub == "--serve-once" {
    guard let dir = argValue("--requests")
    else { FileHandle.standardError.write("missing --requests\n".data(using: .utf8)!); exit(2) }
    let fm = FileManager.default
    for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".req.json") {
        let reqPath = "\(dir)/\(f)"
        let resPath = "\(dir)/" + f.replacingOccurrences(of: ".req.json", with: ".res.json")
        var cmd = "", from: String? = nil, to: String? = nil, cals: [String] = []
        if let data = fm.contents(atPath: reqPath),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cmd = o["cmd"] as? String ?? ""
            from = o["from"] as? String; to = o["to"] as? String
            if let c = o["calendars"] as? String {
                cals = csv(c)
            } else if let c = o["calendars"] as? [String] {
                cals = c
            }
        }
        let result = jsonString(runRequest(cmd: cmd, from: from, to: to, calendars: cals))
        // atomic publish: write .tmp then rename, so the poller never reads a partial file
        let tmp = resPath + ".tmp"
        try? result.write(toFile: tmp, atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: resPath)
        try? fm.moveItem(atPath: tmp, toPath: resPath)
        try? fm.removeItem(atPath: reqPath)
    }
    exit(0)
}

/// ── CLI (for the one-time grant via `open`) ────────────────────────────────────────────────────
let outPath = argValue("--out")
switch sub {
case "list-calendars":
    writeResult(jsonString(runRequest(cmd: "list-calendars", from: nil, to: nil, calendars: [])), to: outPath)
case "events":
    writeResult(
        jsonString(runRequest(
            cmd: "events",
            from: argValue("--from"),
            to: argValue("--to"),
            calendars: csv(argValue("--calendars"))
        )),
        to: outPath
    )
default:
    writeResult(
        "{\"error\":\"usage: list-calendars | events --from <ISO> --to <ISO> [--calendars id,id] | --serve-once --requests <dir>\"}",
        to: outPath
    )
    exit(2)
}
