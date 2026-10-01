// The MagnifiCal backup codec (`.mgc`; legacy `.mdc` files are identical). A DEFLATE zip whose layout mirrors the
// web app's data export (src/lib/backup.ts): a `manifest.json` + a `database.json` whose value is an
// object keyed by table name, each an array of rows, with `Date` columns tagged `{"__bk":"date","v":ISO}`.
// The web dumps all 32 Prisma tables; the native app owns only three — `calendarItem` (events/bands/
// deadlines), `calendarPrefs`, and `dailyNote` — so we populate those and leave the rest empty. This keeps
// a native `.mdc` importable by the web app and lets us import the web's export. (The manifest's
// interchange id is written as "magnifical" since 0.4.x; import never validates it, so legacy
// "libirabu"-stamped backups — and ours in the retired web importer, which checks only structure —
// still round-trip.) Dates use the same UTC wall-clock convention as the web (start = UTC(y,mo,d)+hour).

import CalendarGeometry
import Foundation
#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

public enum MDCBackup {
    public static let app = "magnifical" // manifest interchange id (file extension is .mgc / legacy .mdc)
    public static let format = 1
    static let dateTag = "__bk"

    /// The web's full table list, in dependency order (parents → children). We only fill three.
    static let tables = [
        "user", "verificationToken", "account", "session", "calendarData", "track", "person", "project",
        "paper", "proposal", "fundingSource", "trip", "subscription", "deadline", "apiKey", "calEvent",
        "calendarItem", "calendarConnection", "triageItem", "userApiKey", "calendarPrefs", "dailyNote",
        "task", "expense", "eventPerson", "projectPerson", "paperAuthor", "attachment", "aIConversation",
        "aIMessage", "actionLog", "assistantMemory",
    ]

    public enum BackupError: Error, LocalizedError {
        case notABackup, badJSON
        public var errorDescription: String? {
            switch self {
            case .notABackup: "That file isn't a MagnifiCal backup (missing manifest or database)."
            case .badJSON: "The backup's data could not be read."
            }
        }
    }

    /// One attachment going into (or coming out of) a backup: the blob + its identity.
    public struct FileEntry: Sendable {
        public let hash: String // full sha256
        public let name: String
        public let uti: String
        public let data: Data
        public init(hash: String, name: String, uti: String, data: Data) {
            self.hash = hash; self.name = name; self.uti = uti; self.data = data
        }
    }

    /// ── ENCODE ──────────────────────────────────────────────────────────────────────
    /// Build the JSON entries of a `.mdc` zip from the engine's state, plus one
    /// `files/<sha256>.<ext>` entry per attachment (the web export's convention — its
    /// `attachment` table row carries the identity; the note linkage IS the note text).
    public static func encode(_ s: PersistedState, exportedAt: Date, username: String = "magical",
                              attachments: [FileEntry] = []) throws -> [String: Data] {
        var items: [[String: Any]] = []
        for e in s.events {
            items.append(itemRow(timed: e, rich: s.rich?[e.id], at: exportedAt))
        }
        for b in s.bands {
            items.append(itemRow(band: b, rich: s.rich?[b.id], at: exportedAt))
        }
        for d in s.deadlines {
            items.append(itemRow(deadline: d, rich: s.rich?[d.id], at: exportedAt))
        }

        let prefsRow: [String: Any] = [
            "userId": "", "mainTz": "America/New_York", "altTz": NSNull(),
            "trackNames": s.monthTrackNames ?? [], "autoSync": true,
            "updatedAt": dateVal(exportedAt),
        ]
        let noteRows: [[String: Any]] = (s.dailyNotes ?? [:]).sorted { $0.key < $1.key }.map {
            ["userId": "", "date": $0.key, "notes": $0.value, "updatedAt": dateVal(exportedAt)]
        }

        var attachmentRows: [[String: Any]] = []
        var fileEntries: [String: Data] = [:]
        for a in attachments.sorted(by: { $0.hash < $1.hash }) {
            let path = storagePath(hash: a.hash, name: a.name)
            attachmentRows.append(["id": a.hash, "userId": "", "filename": a.name,
                                   "mime": mime(forUTI: a.uti, name: a.name), "bytes": a.data.count,
                                   "sha256": a.hash, "storagePath": path,
                                   "createdAt": dateVal(exportedAt)])
            fileEntries["files/\(path)"] = a.data
        }

        var db: [String: Any] = [:]
        for t in tables {
            db[t] = [] as [Any]
        }
        db["calendarItem"] = items
        db["calendarPrefs"] = [prefsRow]
        db["dailyNote"] = noteRows
        db["attachment"] = attachmentRows

        var counts: [String: Int] = [:]
        for t in tables {
            counts[t] = ((db[t] as? [Any])?.count) ?? 0
        }
        let manifest: [String: Any] = [
            "app": app, "format": format, "exportedAt": iso(exportedAt),
            "username": username, "counts": counts, "files": fileEntries.count,
        ]

        var out = fileEntries
        out["database.json"] = try JSONSerialization.data(withJSONObject: db, options: [])
        out["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest,
                                                          options: [.prettyPrinted, .sortedKeys])
        return out
    }

    /// The zip-entry leaf for a blob — `<sha256>.<ext>`, matching the web's storagePath.
    private static func storagePath(hash: String, name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    private static func mime(forUTI uti: String, name: String) -> String {
        #if canImport(UniformTypeIdentifiers)
            if let m = UTType(uti)?.preferredMIMEType {
                return m
            }
        #endif
        return "application/octet-stream"
    }

    private static func itemRow(timed e: TimedEvent, rich: RichFields?, at now: Date) -> [String: Any] {
        base(id: e.id, kind: "timed", title: e.title, color: e.color, rich: rich, at: now)
            .merging(["start": dateVal(isoUTC(e.year, e.month, e.day, Double(e.startHour))),
                      "end": dateVal(isoUTC(e.year, e.month, e.day, Double(e.endHour))),
                      "anchorTz": e.anchorTz as Any? ?? NSNull()]) { a, _ in a }
    }

    private static func itemRow(band b: BandEvent, rich: RichFields?, at now: Date) -> [String: Any] {
        base(id: b.id, kind: "band", title: b.title, color: b.color, rich: rich, at: now)
            .merging(["start": dateVal(isoUTC(b.year, b.month, b.startDay, 0)),
                      "end": dateVal(isoUTC(b.year, b.month, b.endDay, 0)),
                      "track": b.track]) { a, _ in a }
    }

    private static func itemRow(deadline d: Deadline, rich: RichFields?, at now: Date) -> [String: Any] {
        base(id: d.id, kind: "deadline", title: d.title, color: d.color, rich: rich, at: now)
            .merging(["start": dateVal(isoUTC(d.year, d.month, d.day, Double(d.hour))),
                      "end": dateVal(isoUTC(d.year, d.month, d.day, Double(d.hour))),
                      "originTz": d.originTz ?? (rich?.originTz as Any? ?? NSNull()),
                      "anchorTz": d.anchorTz as Any? ?? NSNull()]) { a, _ in a }
    }

    private static func base(id: String, kind: String, title: String, color: String,
                             rich: RichFields?, at now: Date) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "userId": "", "kind": kind, "title": title, "color": color,
            "tags": rich?.tags ?? [], "notes": rich?.notes ?? NSNull(),
            "occurrenceNotes": rich?.occurrenceNotes ?? NSNull(),
            "createdByAI": rich?.createdByAI ?? false,
            "source": rich?.source ?? "manual", "hidden": rich?.hidden ?? false,
            "promoteTrack": rich?.promoteTrack ?? NSNull(),
            "createdAt": dateVal(now), "updatedAt": dateVal(now),
        ]
        if let rj = rich?.repeatJSON, let obj = try? JSONSerialization.jsonObject(with: Data(rj.utf8)) {
            row["repeat"] = obj
        }
        return row
    }

    /// ── DECODE ──────────────────────────────────────────────────────────────────────
    /// Read a `.mdc`/`.zip`'s entries back into a PersistedState (only the calendar tables are read).
    public static func decode(_ files: [String: Data]) throws -> PersistedState {
        guard let manifestData = files["manifest.json"],
              let dbData = files["database.json"] else { throw BackupError.notABackup }
        guard (try? JSONSerialization.jsonObject(with: manifestData)) is [String: Any]
        else { throw BackupError.notABackup }
        guard let db = try? JSONSerialization.jsonObject(with: dbData) as? [String: Any]
        else { throw BackupError.badJSON }

        var events: [TimedEvent] = [], bands: [BandEvent] = [], deadlines: [Deadline] = []
        var rich: [String: RichFields] = [:]
        for row in (db["calendarItem"] as? [[String: Any]]) ?? [] {
            guard let id = row["id"] as? String, let kind = row["kind"] as? String,
                  let start = dateFrom(row["start"]) else { continue }
            let title = row["title"] as? String ?? ""
            let color = row["color"] as? String ?? "default"
            let (sy, sm, sd) = utcYMD(start)
            switch kind {
            case "band":
                let end = dateFrom(row["end"]) ?? start
                // Day COUNT, not the end's day-of-month: a cross-month (spilling) band exports a
                // real ISO end date in the next month — reading back just its day component
                // silently truncated the span (Jan 30–Feb 2 became Jan 30).
                let span = utcCalendar.dateComponents([.day], from: start, to: end).day ?? 0
                let track = (row["track"] as? Int) ?? 0
                bands.append(BandEvent(id: id, year: sy, month: sm, track: max(0, min(3, track)),
                                       startDay: sd, endDay: sd + max(0, span), title: title, color: color))
            case "deadline":
                deadlines.append(Deadline(id: id, year: sy, month: sm, day: sd, hour: hourInto(start, dayOf: start),
                                          title: title, color: color, originTz: row["originTz"] as? String,
                                          anchorTz: (row["anchorTz"] as? String) ?? DeadlineTZ.concrete("auto")))
            default: // timed
                let end = dateFrom(row["end"]) ?? start
                events.append(TimedEvent(id: id, year: sy, month: sm, day: sd,
                                         startHour: hourInto(start, dayOf: start),
                                         endHour: hourInto(end, dayOf: start), title: title, color: color,
                                         anchorTz: (row["anchorTz"] as? String) ?? DeadlineTZ.concrete("auto")))
            }
            rich[id] = richFrom(row)
        }

        let prefs = (db["calendarPrefs"] as? [[String: Any]])?.first
        let trackNames = prefs?["trackNames"] as? [[String]]
        var dailyNotes: [String: String] = [:]
        for row in (db["dailyNote"] as? [[String: Any]]) ?? [] {
            if let date = row["date"] as? String, let notes = row["notes"] as? String {
                dailyNotes[date] = notes
            }
        }
        return PersistedState(events: events, bands: bands, deadlines: deadlines,
                              monthTrackNames: trackNames, rich: rich, dailyNotes: dailyNotes)
    }

    /// The backup's attachments: `attachment` table rows joined to their `files/` payloads.
    /// Rows missing a payload (or a hash) are skipped; legacy backups without `files/` → [].
    /// Verification is NOT done here — the AttachmentStore's adopt path hash-checks on landing.
    public static func decodeAttachments(_ files: [String: Data]) -> [FileEntry] {
        guard let dbData = files["database.json"],
              let db = try? JSONSerialization.jsonObject(with: dbData) as? [String: Any]
        else { return [] }
        var out: [FileEntry] = []
        for row in (db["attachment"] as? [[String: Any]]) ?? [] {
            guard let hash = (row["sha256"] as? String) ?? (row["id"] as? String),
                  let path = row["storagePath"] as? String,
                  let data = files["files/\(path)"] else { continue }
            let name = (row["filename"] as? String) ?? path
            out.append(FileEntry(hash: hash, name: name,
                                 uti: uti(fromMime: row["mime"] as? String, name: name),
                                 data: data))
        }
        return out
    }

    /// Best-effort UTI from the row's mime (web backups) with a filename-extension fallback.
    private static func uti(fromMime mime: String?, name: String) -> String {
        #if canImport(UniformTypeIdentifiers)
            if let mime, let t = UTType(mimeType: mime) {
                return t.identifier
            }
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, let t = UTType(filenameExtension: ext) {
                return t.identifier
            }
        #endif
        return "public.data"
    }

    private static func richFrom(_ row: [String: Any]) -> RichFields {
        var repeatJSON: String? = nil
        if let rep = row["repeat"], !(rep is NSNull), let d = try? JSONSerialization.data(withJSONObject: rep) {
            repeatJSON = String(data: d, encoding: .utf8)
        }
        return RichFields(
            notes: row["notes"] as? String,
            tags: (row["tags"] as? [String]) ?? [],
            repeatJSON: repeatJSON,
            promoteTrack: row["promoteTrack"] as? Int,
            originTz: row["originTz"] as? String,
            source: (row["source"] as? String) ?? "manual",
            hidden: (row["hidden"] as? Bool) ?? false,
            createdByAI: (row["createdByAI"] as? Bool) ?? false,
            occurrenceNotes: row["occurrenceNotes"] as? [String: String]
        )
    }

    /// ── Date helpers (UTC wall-clock, matching the web) ────────────────────────────────
    private static func dateVal(_ iso: String) -> [String: String] {
        [dateTag: "date", "v": iso]
    }

    private static func dateVal(_ d: Date) -> [String: String] {
        [dateTag: "date", "v": iso(d)]
    }

    private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private static func iso(_ d: Date) -> String {
        isoFmt.string(from: d)
    }

    /// "YYYY-MM-DDThh:mm:ss.000Z" for (year, 0-based month, day) + an hour fraction, all in UTC — exactly
    /// how the web stores a floating time (Date.UTC(y,mo,d) + hour*3600s → toISOString).
    private static func isoUTC(_ y: Int, _ m0: Int, _ d: Int, _ hour: Double) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        var c = DateComponents(); c.year = y; c.month = m0 + 1; c.day = d
        let date = (cal.date(from: c) ?? Date()).addingTimeInterval(hour * 3600)
        let x = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.000Z",
                      x.year ?? y, x.month ?? m0 + 1, x.day ?? d, x.hour ?? 0, x.minute ?? 0, x.second ?? 0)
    }

    private static let utc = utcTimeZone // canonical (Dates.swift)
    /// Parse a value that is either a `{"__bk":"date","v":ISO}` dict or a raw ISO string → Date.
    private static func dateFrom(_ v: Any?) -> Date? {
        if let dict = v as? [String: Any], let s = dict["v"] as? String {
            return parseISO(s)
        }
        if let s = v as? String {
            return parseISO(s)
        }
        return nil
    }

    private static func parseISO(_ s: String) -> Date? {
        if let d = isoFmt.date(from: s) {
            return d
        }
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) {
            return d
        }
        // Bare wall-clock "YYYY-MM-DDThh:mm:ss" (no zone) → interpret as UTC.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let parts = s.split(separator: "T")
        guard parts.count >= 1 else { return nil }
        let dp = parts[0].split(separator: "-").compactMap { Int($0) }
        guard dp.count == 3 else { return nil }
        var c = DateComponents(); c.year = dp[0]; c.month = dp[1]; c.day = dp[2]
        if parts.count == 2 {
            let tp = parts[1].prefix(8).split(separator: ":").compactMap { Int($0) }
            if tp.count >= 2 {
                c.hour = tp[0]; c.minute = tp[1]; c.second = tp.count > 2 ? tp[2] : 0
            }
        }
        return cal.date(from: c)
    }

    private static func utcYMD(_ d: Date) -> (year: Int, month0: Int, day: Int) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return (c.year ?? 2026, (c.month ?? 1) - 1, c.day ?? 1)
    }

    /// Hours of `d` measured from the UTC midnight of `ref`'s day (so an end at next-day midnight → 24).
    private static func hourInto(_ d: Date, dayOf ref: Date) -> CGFloat {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let mid = cal.startOfDay(for: ref)
        return CGFloat(d.timeIntervalSince(mid) / 3600)
    }
}
