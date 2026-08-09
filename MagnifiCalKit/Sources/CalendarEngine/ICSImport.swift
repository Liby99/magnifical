// Minimal RFC-5545 (.ics) importer. The web app parses .ics server-side with the `node-ical` library
// (src/lib/import/ical.ts) then normalizes (src/lib/import/normalize.ts); this is a focused native port
// of the field mapping + kind decisions for the common cases:
//   • all-day (VALUE=DATE), single or multi-day        → band (DTEND is exclusive → inclusive last day)
//   • timed on one day                                  → timed event
//   • timed spanning multiple days                      → promoted to a band over the day span
//   • never a deadline (imports don't create deadlines, matching normalize.ts)
// Vendor extras (LOCATION / ORGANIZER / ATTENDEE / DESCRIPTION / URL) go into a managed-note block
// (ManagedNote), exactly like the Apple Calendar import. Timed instants are resolved to the device's
// local wall-clock (the app's floating-time convention; the web uses the user's main tz = "auto").

import CalendarGeometry
import Foundation

public enum ICSImport {
    /// Parse `.ics` text into native seed items. `provenance` is a short source label (usually the file
    /// name) shown in the managed-note block. Returns items keyed for `CalendarEngine.importItems`.
    public static func items(from text: String, provenance: String)
        -> (events: [TimedEvent], bands: [BandEvent], rich: [String: RichFields]) {
        var events: [TimedEvent] = [], bands: [BandEvent] = []
        var rich: [String: RichFields] = [:]
        for ve in vevents(in: text) {
            guard let s = ve.start else { continue } // skip timeless rows (matches node-ical guard)
            guard ve.status != "CANCELLED" else { continue } // Outlook METHOD:CANCEL stubs aren't events
            let title = ve.summary.isEmpty ? "(untitled)" : ve.summary
            let color = "default"
            let block = ManagedNote.render(
                provenance: "iCal · \(provenance)",
                meetingUrl: ve.url, location: ve.location, organizer: ve.organizer,
                attendees: ve.attendees.map { ($0.name, $0.status ?? "") }, description: ve.description
            )
            let notes = block.isEmpty ? nil : block

            if s.allDay {
                // Inclusive last day: DTEND (or DTSTART+DURATION) is exclusive in iCal, so subtract
                // a day; none → single day.
                let endExclusive = ve.effectiveEnd
                let last = endExclusive.map { addDays($0, -1) } ?? s
                let lastClamped = (ymd(last) < ymd(s)) ? s : last
                for seg in bandSegments(from: s, to: lastClamped) {
                    let id = "ics-\(UUID().uuidString)"
                    bands.append(BandEvent(id: id, year: seg.year, month: seg.month, track: 0,
                                           startDay: seg.startDay, endDay: seg.endDay, title: title, color: color))
                    rich[id] = importedRich(notes)
                }
            } else if let e = ve.effectiveEnd, ymd(e) != ymd(s) {
                // Multi-day timed → promoted to an all-day band over the span (normalize.ts).
                for seg in bandSegments(from: s, to: e) {
                    let id = "ics-\(UUID().uuidString)"
                    bands.append(BandEvent(id: id, year: seg.year, month: seg.month, track: 0,
                                           startDay: seg.startDay, endDay: seg.endDay, title: title, color: color))
                    rich[id] = importedRich(notes)
                }
            } else {
                // Single-day timed event.
                let e = ve.effectiveEnd ?? s
                let id = "ics-\(UUID().uuidString)"
                events.append(TimedEvent(id: id, year: s.year, month: s.month - 1, day: s.day, // WC month is 1-based
                                         startHour: hourOf(s), endHour: max(hourOf(s), hourOf(e)),
                                         title: title, color: color,
                                         anchorTz: DeadlineTZ.concrete("auto"))) // parsed into device-local wall-clock
                rich[id] = importedRich(notes)
            }
        }
        return (events, bands, rich)
    }

    private static func importedRich(_ notes: String?) -> RichFields {
        RichFields(notes: notes, tags: ["imported"], source: "ical")
    }

    /// The calendar's own display name, from the VCALENDAR-level X-WR-CALNAME header (Google —
    /// and most providers — set it on exported/secret feeds). nil when absent.
    public static func feedCalendarName(from text: String) -> String? {
        for line in unfold(text) {
            guard let (name, _, value) = property(line), name == "X-WR-CALNAME" else { continue }
            let clean = unescapeText(value).trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        return nil
    }

    // ── Wall-clock model ──────────────────────────────────────────────────────────────
    /// A resolved date/time in the device's local wall clock. `allDay` drops the time.
    private struct WC { var year, month, day, hour, minute: Int; var allDay: Bool }
    private static func ymd(_ w: WC) -> Int {
        w.year * 10000 + w.month * 100 + w.day
    }

    private static func hourOf(_ w: WC) -> CGFloat {
        CGFloat(w.hour) + CGFloat(w.minute) / 60
    }

    private static func addDays(_ w: WC, _ n: Int) -> WC {
        var c = DateComponents(); c.year = w.year; c.month = w.month; c.day = w.day
        let cal = utcCalendar
        guard let base = cal.date(from: c), let moved = cal.date(byAdding: .day, value: n, to: base) else { return w }
        let d = cal.dateComponents([.year, .month, .day], from: moved)
        return WC(
            year: d.year ?? w.year,
            month: d.month ?? w.month,
            day: d.day ?? w.day,
            hour: w.hour,
            minute: w.minute,
            allDay: w.allDay
        )
    }

    /// ── VEVENT extraction ─────────────────────────────────────────────────────────────
    private struct VEvent {
        var summary = "", location: String? = nil, organizer: String? = nil, url: String? = nil,
            description: String? = nil
        var start: WC?, end: WC? = nil
        var durationMinutes: Int? // DURATION property (Outlook sometimes sends it instead of DTEND)
        var status: String? // STATUS — CANCELLED stubs (METHOD:CANCEL mails) are skipped
        var attendees: [(name: String, status: String?)] = []
        // Feed-subscription extras (see feedItems): stable identity + recurrence.
        var uid: String?
        var rrule: String?
        var exdates: [WC] = []
        var recurrenceId: WC?
        /// DTEND, else DTSTART + DURATION. For all-day events both are EXCLUSIVE ends.
        var effectiveEnd: WC? {
            end ?? start.flatMap { s in durationMinutes.map { addMinutes(s, $0) } }
        }
    }

    private static func vevents(in text: String) -> [VEvent] {
        let lines = unfold(text)
        // The file's own VTIMEZONE definitions — the resolver of last resort for TZIDs that are
        // neither IANA nor Windows zone names. (VTIMEZONE property lines are skipped by the VEVENT
        // loop below: `cur` is nil outside BEGIN/END:VEVENT.)
        let tzdb = vtimezones(in: lines)
        var out: [VEvent] = [], cur: VEvent? = nil
        for line in lines {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" {
                cur = VEvent(); continue
            }
            if upper == "END:VEVENT" {
                if let c = cur {
                    out.append(c)
                }; cur = nil; continue
            }
            guard var event = cur, let (name, params, value) = property(line) else { continue }
            switch name {
            case "SUMMARY": event.summary = unescapeText(value)
            case "LOCATION": event.location = unescapeText(value).isEmpty ? nil : unescapeText(value)
            case "DESCRIPTION": event.description = unescapeText(value).isEmpty ? nil : unescapeText(value)
            case "URL": event.url = value.isEmpty ? nil : value
            case "ORGANIZER": event.organizer = displayName(params: params, value: value)
            case "ATTENDEE": if let a = displayName(params: params, value: value) {
                    event.attendees.append((
                        a,
                        params["PARTSTAT"]
                    ))
                }
            case "DTSTART": event.start = parseDT(value: value, params: params, tzdb: tzdb)
            case "DTEND": event.end = parseDT(value: value, params: params, tzdb: tzdb)
            case "DURATION": event.durationMinutes = durationMinutes(value)
            case "STATUS": event.status = value.uppercased()
            case "UID": event.uid = value.isEmpty ? nil : value
            case "RRULE": event.rrule = value
            case "RECURRENCE-ID": event.recurrenceId = parseDT(value: value, params: params, tzdb: tzdb)
            case "EXDATE": // may carry several comma-separated date-times
                for v in value.split(separator: ",") {
                    if let d = parseDT(value: String(v), params: params, tzdb: tzdb) {
                        event.exdates.append(d)
                    }
                }
            default: break
            }
            cur = event
        }
        return out
    }

    /// Join RFC-5545 folded continuation lines (a leading space/tab continues the previous line).
    private static func unfold(_ text: String) -> [String] {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var out: [String] = []
        for piece in raw {
            let s = String(piece)
            if let first = s.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1] += String(s.dropFirst())
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Split "NAME;PARAM=VAL;...:value" → (NAME uppercased, params, value). The separators are the
    /// first ':' and the ';'s OUTSIDE double quotes — param values containing ':'/';'/',' are
    /// quoted per RFC 5545 (Outlook: TZID="(UTC+05:30) Chennai, Kolkata, Mumbai, New Delhi").
    private static func property(_ line: String) -> (name: String, params: [String: String], value: String)? {
        var inQuotes = false
        var colon: String.Index? = nil
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ":", !inQuotes {
                colon = i; break
            }
            i = line.index(after: i)
        }
        guard let colon else { return nil }
        let value = String(line[line.index(after: colon)...])
        let parts = splitOutsideQuotes(line[line.startIndex ..< colon], on: ";")
        guard let name = parts.first?.uppercased() else { return nil }
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            if let eq = p.firstIndex(of: "=") {
                params[String(p[p.startIndex ..< eq]).uppercased()] = String(p[p.index(after: eq)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return (name, params, value)
    }

    private static func splitOutsideQuotes(_ s: Substring, on sep: Character) -> [String] {
        var out: [String] = [], cur = "", inQuotes = false
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle(); cur.append(ch)
            } else if ch == sep, !inQuotes {
                out.append(cur); cur = ""
            } else {
                cur.append(ch)
            }
        }
        out.append(cur)
        return out
    }

    /// ORGANIZER/ATTENDEE: prefer the CN= parameter, else the mailto: address local part.
    private static func displayName(params: [String: String], value: String) -> String? {
        if let cn = params["CN"], !cn.isEmpty {
            return cn
        }
        let v = value.hasPrefix("mailto:") || value.hasPrefix("MAILTO:") ? String(value.dropFirst(7)) : value
        return v.isEmpty ? nil : v
    }

    /// Parse a DTSTART/DTEND value into a device-local wall clock. Handles VALUE=DATE (all-day),
    /// UTC ("…Z"), TZID=<zone> — IANA names, Outlook/Windows zone names, the file's own VTIMEZONE
    /// definitions, or an embedded UTC±HH:MM — and floating date-times.
    private static func parseDT(value: String, params: [String: String], tzdb: [String: VTZ]) -> WC? {
        let v = value.trimmingCharacters(in: .whitespaces)
        // All-day: VALUE=DATE, or a bare 8-digit date.
        if params["VALUE"] == "DATE" || (v.count == 8 && !v.contains("T")) {
            guard v.count >= 8, let y = Int(v.prefix(4)), let mo = Int(v.dropFirst(4).prefix(2)),
                  let d = Int(v.dropFirst(6).prefix(2)) else { return nil }
            return WC(year: y, month: mo, day: d, hour: 0, minute: 0, allDay: true)
        }
        // Date-time: YYYYMMDD 'T' HHMMSS ['Z'].
        let core = v.hasSuffix("Z") ? String(v.dropLast()) : v
        let halves = core.split(separator: "T", maxSplits: 1).map(String.init)
        guard halves.count == 2, halves[0].count >= 8, halves[1].count >= 4,
              let y = Int(halves[0].prefix(4)), let mo = Int(halves[0].dropFirst(4).prefix(2)),
              let d = Int(halves[0].dropFirst(6).prefix(2)),
              let h = Int(halves[1].prefix(2)), let mi = Int(halves[1].dropFirst(2).prefix(2)) else { return nil }
        let floating = WC(year: y, month: mo, day: d, hour: h, minute: mi, allDay: false)
        // Floating (no Z, no TZID) → the numbers ARE the wall clock. Otherwise resolve the instant in its
        // source zone and re-read it in the device zone.
        let isUTC = v.hasSuffix("Z")
        let zone: TimeZone?
        if isUTC {
            zone = utcTimeZone
        } else if let tzid = params["TZID"] {
            zone = sourceZone(tzid, month: mo, day: d, minutes: h * 60 + mi, year: y, tzdb: tzdb)
        } else {
            return floating
        }
        // An unresolvable TZID falls back to FLOATING (the wall clock as the sender wrote it) —
        // never UTC: assuming UTC shifted every Outlook invite by the device's whole UTC offset
        // (the "-4h on import" bug — Windows zone names are not IANA identifiers).
        guard let zone else { return floating }
        var src = DateComponents(); src.year = y; src.month = mo; src.day = d; src.hour = h; src.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let instant = cal.date(from: src) else { return floating }
        let lc = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        return WC(
            year: lc.year ?? y,
            month: lc.month ?? mo,
            day: lc.day ?? d,
            hour: lc.hour ?? h,
            minute: lc.minute ?? mi,
            allDay: false
        )
    }

    /// ── TZID resolution ───────────────────────────────────────────────────────────────
    /// Resolve a TZID to the zone the sender meant, trying, in order:
    ///   1. an IANA identifier ("America/New_York") — the standards-compliant case;
    ///   2. a trailing IANA path — Mozilla-style "/mozilla.org/20070129_1/America/New_York";
    ///   3. a Windows zone name ("Eastern Standard Time") — what Outlook/Exchange writes;
    ///   4. the file's own VTIMEZONE definition (seasonal offsets, resolved for the event's date);
    ///   5. an embedded numeric offset — "(UTC-05:00) …", "GMT-0400", "+0530".
    /// nil → the caller treats the time as floating (never UTC).
    private static func sourceZone(_ tzid: String, month: Int, day: Int, minutes: Int, year: Int,
                                   tzdb: [String: VTZ]) -> TimeZone? {
        if let z = TimeZone(identifier: tzid) {
            return z
        }
        let parts = tzid.split(separator: "/").map(String.init)
        if parts.count >= 2, let z = TimeZone(identifier: parts.suffix(2).joined(separator: "/")) {
            return z
        }
        if let iana = windowsTZ[tzid], let z = TimeZone(identifier: iana) {
            return z
        }
        if let vtz = tzdb[tzid] {
            return TimeZone(secondsFromGMT: vtz.offset(month: month, day: day, minutes: minutes, year: year))
        }
        if let secs = embeddedOffsetSeconds(tzid) {
            return TimeZone(secondsFromGMT: secs)
        }
        return nil
    }

    /// "(UTC-05:00) Eastern Time (US & Canada)", "GMT-0400", "+05:30" → seconds east of GMT.
    private static func embeddedOffsetSeconds(_ tzid: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: #"([+-])(\d{1,2}):?(\d{2})?"#),
              let m = re.firstMatch(in: tzid, range: NSRange(tzid.startIndex..., in: tzid)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: tzid).map { String(tzid[$0]) }
        }
        guard let sign = group(1), let h = group(2).flatMap(Int.init) else { return nil }
        let mi = group(3).flatMap(Int.init) ?? 0
        let total = h * 3600 + mi * 60
        return sign == "-" ? -total : total
    }

    /// ── VTIMEZONE (self-defined zones) ────────────────────────────────────────────────
    /// One STANDARD/DAYLIGHT component: the offset it switches TO and when in the year it starts.
    private struct SeasonRule {
        var offsetTo = 0 // seconds east of GMT (TZOFFSETTO)
        var startStamp = "" // DTSTART value — the NEWEST definition wins when a zone lists revisions
        var month = 1 // transition month (RRULE BYMONTH, else DTSTART's month)
        var monthDay: Int? // BYMONTHDAY (rare)
        var weekOrd: Int? // BYDAY ordinal: 1…4, -1 = last (−2 = one before last, …)
        var weekday: Int? // BYDAY day: 0=Sun … 6=Sat
        var minutes = 120 // transition time-of-day (DTSTART's clock; iCal convention 02:00)

        /// Day-of-month this rule's transition lands on in `year`.
        func transitionDay(year: Int) -> Int {
            if let md = monthDay {
                return md
            }
            guard let ord = weekOrd, let wd = weekday else { return 1 }
            let cal = utcCalendar
            var c = DateComponents(); c.year = year; c.month = month; c.day = 1
            guard let first = cal.date(from: c) else { return 1 }
            let firstDow = (cal.dateComponents([.weekday], from: first).weekday ?? 1) - 1 // 0=Sun
            let dim = daysInMonth(year, month - 1)
            if ord >= 1 {
                return Swift.min(1 + ((wd - firstDow + 7) % 7) + (ord - 1) * 7, dim)
            }
            let lastDow = (firstDow + dim - 1) % 7
            return dim - ((lastDow - wd + 7) % 7) + (ord + 1) * 7 // -1 = last, -2 = the one before
        }
    }

    private struct VTZ {
        var standard: SeasonRule?, daylight: SeasonRule? = nil
        /// The offset in force at a given local date/time. Single-component zones are fixed;
        /// two-component zones pick the season by the yearly transition points (southern-hemisphere
        /// zones wrap the year end).
        func offset(month: Int, day: Int, minutes: Int, year: Int) -> Int {
            guard let st = standard, let dl = daylight else { return (standard ?? daylight)?.offsetTo ?? 0 }
            func key(_ r: SeasonRule) -> (Int, Int, Int) {
                (r.month, r.transitionDay(year: year), r.minutes)
            }
            let t = (month, day, minutes), dlK = key(dl), stK = key(st)
            let inDaylight = dlK < stK ? (t >= dlK && t < stK) : (t >= dlK || t < stK)
            return inDaylight ? dl.offsetTo : st.offsetTo
        }
    }

    /// Parse the file's VTIMEZONE blocks into TZID → seasonal rules. Only consulted for TZIDs that
    /// resolve neither as IANA nor as Windows names (self-defined/custom zones).
    private static func vtimezones(in lines: [String]) -> [String: VTZ] {
        var out: [String: VTZ] = [:]
        var tzid: String? = nil, vtz: VTZ? = nil
        var comp: SeasonRule? = nil, compIsStandard = true
        let dayMap = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]
        for line in lines {
            switch line.uppercased() {
            case "BEGIN:VTIMEZONE": tzid = nil; vtz = VTZ(); continue
            case "END:VTIMEZONE":
                if let id = tzid, let z = vtz {
                    out[id] = z
                }
                tzid = nil; vtz = nil; continue
            case "BEGIN:STANDARD", "BEGIN:DAYLIGHT":
                guard vtz != nil else { continue }
                comp = SeasonRule(); compIsStandard = line.uppercased().hasSuffix("STANDARD"); continue
            case "END:STANDARD", "END:DAYLIGHT":
                if let c = comp, vtz != nil {
                    // Zones may list historical revisions — keep the newest (largest DTSTART).
                    if compIsStandard {
                        if (vtz!.standard?.startStamp ?? "") <= c.startStamp {
                            vtz!.standard = c
                        }
                    } else if (vtz!.daylight?.startStamp ?? "") <= c.startStamp {
                        vtz!.daylight = c
                    }
                }
                comp = nil; continue
            default: break
            }
            guard vtz != nil, let (name, _, value) = property(line) else { continue }
            guard comp != nil else {
                if name == "TZID" {
                    tzid = value
                }
                continue
            }
            switch name {
            case "TZOFFSETTO": comp!.offsetTo = offsetSeconds(value) ?? 0
            case "DTSTART":
                comp!.startStamp = value
                if value.count >= 6, let m = Int(value.dropFirst(4).prefix(2)) {
                    comp!.month = m
                }
                if let t = value.split(separator: "T").last, t.count >= 4,
                   let h = Int(t.prefix(2)), let m = Int(t.dropFirst(2).prefix(2)) {
                    comp!.minutes = h * 60 + m
                }
            case "RRULE":
                for part in value.split(separator: ";") {
                    let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    switch kv[0].uppercased() {
                    case "BYMONTH": comp!.month = Int(kv[1]) ?? comp!.month
                    case "BYMONTHDAY": comp!.monthDay = Int(kv[1])
                    case "BYDAY":
                        comp!.weekday = dayMap[String(kv[1].suffix(2)).uppercased()]
                        comp!.weekOrd = Int(kv[1].dropLast(2)) ?? 1
                    default: break
                    }
                }
            default: break
            }
        }
        return out
    }

    /// "±HHMM[SS]" (TZOFFSETTO) → seconds east of GMT.
    private static func offsetSeconds(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let digits = t.dropFirst().filter(\.isNumber)
        guard digits.count >= 2, let h = Int(digits.prefix(2)) else { return nil }
        let m = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
        let sec = digits.count >= 6 ? Int(digits.dropFirst(4).prefix(2)) ?? 0 : 0
        let total = h * 3600 + m * 60 + sec
        return sign == "-" ? -total : total
    }

    /// ISO-8601 duration subset for the DURATION property: P[nW][nD][T[nH][nM][nS]] → minutes.
    /// A month designator (P1M outside a T section) is ambiguous → nil (the event stays a point).
    private static func durationMinutes(_ s: String) -> Int? {
        var mins = 0, num = "", inTime = false, any = false
        for ch in s.uppercased() {
            switch ch {
            case "P", "+": continue
            case "-": return nil // negative durations aren't meaningful for an event span
            case "T": inTime = true
            case "0" ... "9": num.append(ch)
            case "W": mins += (Int(num) ?? 0) * 7 * 24 * 60; num = ""; any = true
            case "D": mins += (Int(num) ?? 0) * 24 * 60; num = ""; any = true
            case "H": mins += (Int(num) ?? 0) * 60; num = ""; any = true
            case "M":
                guard inTime else { return nil } // calendar months — not a fixed span
                mins += Int(num) ?? 0; num = ""; any = true
            case "S": num = ""; any = true
            default: return nil
            }
        }
        return any ? mins : nil
    }

    private static func addMinutes(_ w: WC, _ n: Int) -> WC {
        var c = DateComponents(); c.year = w.year; c.month = w.month; c.day = w.day
        c.hour = w.hour; c.minute = w.minute
        let cal = utcCalendar
        guard let base = cal.date(from: c), let moved = cal.date(byAdding: .minute, value: n, to: base)
        else { return w }
        let d = cal.dateComponents([.year, .month, .day, .hour, .minute], from: moved)
        return WC(year: d.year ?? w.year, month: d.month ?? w.month, day: d.day ?? w.day,
                  hour: d.hour ?? w.hour, minute: d.minute ?? w.minute, allDay: w.allDay)
    }

    /// Windows zone name → IANA identifier (the CLDR windowsZones "001" mapping) — what
    /// Outlook/Exchange writes as TZID. Foundation only resolves IANA names, so without this
    /// every Outlook invite fell back to UTC (a whole-UTC-offset shift on import).
    static let windowsTZ: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12",
        "UTC-11": "Etc/GMT+11",
        "Aleutian Standard Time": "America/Adak",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Marquesas Standard Time": "Pacific/Marquesas",
        "Alaskan Standard Time": "America/Anchorage",
        "UTC-09": "Etc/GMT+9",
        "Pacific Standard Time (Mexico)": "America/Tijuana",
        "UTC-08": "Etc/GMT+8",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time (Mexico)": "America/Mazatlan",
        "Mountain Standard Time": "America/Denver",
        "Yukon Standard Time": "America/Whitehorse",
        "Central America Standard Time": "America/Guatemala",
        "Central Standard Time": "America/Chicago",
        "Easter Island Standard Time": "Pacific/Easter",
        "Central Standard Time (Mexico)": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina",
        "SA Pacific Standard Time": "America/Bogota",
        "Eastern Standard Time (Mexico)": "America/Cancun",
        "Eastern Standard Time": "America/New_York",
        "Haiti Standard Time": "America/Port-au-Prince",
        "Cuba Standard Time": "America/Havana",
        "US Eastern Standard Time": "America/Indiana/Indianapolis",
        "Turks And Caicos Standard Time": "America/Grand_Turk",
        "Paraguay Standard Time": "America/Asuncion",
        "Atlantic Standard Time": "America/Halifax",
        "Venezuela Standard Time": "America/Caracas",
        "Central Brazilian Standard Time": "America/Cuiaba",
        "SA Western Standard Time": "America/La_Paz",
        "Pacific SA Standard Time": "America/Santiago",
        "Newfoundland Standard Time": "America/St_Johns",
        "Tocantins Standard Time": "America/Araguaina",
        "E. South America Standard Time": "America/Sao_Paulo",
        "SA Eastern Standard Time": "America/Cayenne",
        "Argentina Standard Time": "America/Buenos_Aires",
        "Montevideo Standard Time": "America/Montevideo",
        "Magallanes Standard Time": "America/Punta_Arenas",
        "Saint Pierre Standard Time": "America/Miquelon",
        "Bahia Standard Time": "America/Bahia",
        "UTC-02": "Etc/GMT+2",
        "Mid-Atlantic Standard Time": "Etc/GMT+2",
        "Greenland Standard Time": "America/Godthab",
        "Azores Standard Time": "Atlantic/Azores",
        "Cape Verde Standard Time": "Atlantic/Cape_Verde",
        "UTC": "Etc/UTC",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "Sao Tome Standard Time": "Africa/Sao_Tome",
        "Morocco Standard Time": "Africa/Casablanca",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw",
        "W. Central Africa Standard Time": "Africa/Lagos",
        "GTB Standard Time": "Europe/Bucharest",
        "Middle East Standard Time": "Asia/Beirut",
        "Egypt Standard Time": "Africa/Cairo",
        "E. Europe Standard Time": "Europe/Chisinau",
        "West Bank Standard Time": "Asia/Hebron",
        "South Africa Standard Time": "Africa/Johannesburg",
        "FLE Standard Time": "Europe/Kiev",
        "Israel Standard Time": "Asia/Jerusalem",
        "South Sudan Standard Time": "Africa/Juba",
        "Kaliningrad Standard Time": "Europe/Kaliningrad",
        "Sudan Standard Time": "Africa/Khartoum",
        "Libya Standard Time": "Africa/Tripoli",
        "Namibia Standard Time": "Africa/Windhoek",
        "Jordan Standard Time": "Asia/Amman",
        "Arabic Standard Time": "Asia/Baghdad",
        "Syria Standard Time": "Asia/Damascus",
        "Turkey Standard Time": "Europe/Istanbul",
        "Arab Standard Time": "Asia/Riyadh",
        "Belarus Standard Time": "Europe/Minsk",
        "Russian Standard Time": "Europe/Moscow",
        "E. Africa Standard Time": "Africa/Nairobi",
        "Volgograd Standard Time": "Europe/Volgograd",
        "Iran Standard Time": "Asia/Tehran",
        "Arabian Standard Time": "Asia/Dubai",
        "Astrakhan Standard Time": "Europe/Astrakhan",
        "Azerbaijan Standard Time": "Asia/Baku",
        "Russia Time Zone 3": "Europe/Samara",
        "Mauritius Standard Time": "Indian/Mauritius",
        "Saratov Standard Time": "Europe/Saratov",
        "Georgian Standard Time": "Asia/Tbilisi",
        "Caucasus Standard Time": "Asia/Yerevan",
        "Afghanistan Standard Time": "Asia/Kabul",
        "West Asia Standard Time": "Asia/Tashkent",
        "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
        "Pakistan Standard Time": "Asia/Karachi",
        "Qyzylorda Standard Time": "Asia/Qyzylorda",
        "India Standard Time": "Asia/Kolkata",
        "Sri Lanka Standard Time": "Asia/Colombo",
        "Nepal Standard Time": "Asia/Kathmandu",
        "Central Asia Standard Time": "Asia/Almaty",
        "Bangladesh Standard Time": "Asia/Dhaka",
        "Omsk Standard Time": "Asia/Omsk",
        "Myanmar Standard Time": "Asia/Yangon",
        "SE Asia Standard Time": "Asia/Bangkok",
        "Altai Standard Time": "Asia/Barnaul",
        "W. Mongolia Standard Time": "Asia/Hovd",
        "North Asia Standard Time": "Asia/Krasnoyarsk",
        "N. Central Asia Standard Time": "Asia/Novosibirsk",
        "Tomsk Standard Time": "Asia/Tomsk",
        "China Standard Time": "Asia/Shanghai",
        "North Asia East Standard Time": "Asia/Irkutsk",
        "Singapore Standard Time": "Asia/Singapore",
        "W. Australia Standard Time": "Australia/Perth",
        "Taipei Standard Time": "Asia/Taipei",
        "Ulaanbaatar Standard Time": "Asia/Ulaanbaatar",
        "Aus Central W. Standard Time": "Australia/Eucla",
        "Transbaikal Standard Time": "Asia/Chita",
        "Tokyo Standard Time": "Asia/Tokyo",
        "North Korea Standard Time": "Asia/Pyongyang",
        "Korea Standard Time": "Asia/Seoul",
        "Yakutsk Standard Time": "Asia/Yakutsk",
        "Cen. Australia Standard Time": "Australia/Adelaide",
        "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "West Pacific Standard Time": "Pacific/Port_Moresby",
        "Tasmania Standard Time": "Australia/Hobart",
        "Vladivostok Standard Time": "Asia/Vladivostok",
        "Lord Howe Standard Time": "Australia/Lord_Howe",
        "Bougainville Standard Time": "Pacific/Bougainville",
        "Russia Time Zone 10": "Asia/Srednekolymsk",
        "Magadan Standard Time": "Asia/Magadan",
        "Norfolk Standard Time": "Pacific/Norfolk",
        "Sakhalin Standard Time": "Asia/Sakhalin",
        "Central Pacific Standard Time": "Pacific/Guadalcanal",
        "Russia Time Zone 11": "Asia/Kamchatka",
        "Kamchatka Standard Time": "Asia/Kamchatka",
        "New Zealand Standard Time": "Pacific/Auckland",
        "UTC+12": "Etc/GMT-12",
        "Fiji Standard Time": "Pacific/Fiji",
        "Chatham Islands Standard Time": "Pacific/Chatham",
        "UTC+13": "Etc/GMT-13",
        "Tonga Standard Time": "Pacific/Tongatapu",
        "Samoa Standard Time": "Pacific/Apia",
        "Line Islands Standard Time": "Pacific/Kiritimati",
    ]

    private static func unescapeText(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
        out = out.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
        out = out.replacingOccurrences(of: "\\\\", with: "\\")
        return out
    }

    // ── Band segmentation ───────────────────────────────────────────────────────────
    /// Split an inclusive [start, end] day span into one band segment per calendar month (native bands
    /// live in a single month), clamped to each month's day range — mirrors CalendarEngine.createBandSpan.
    private struct Seg { var year, month, startDay, endDay: Int }
    private static func bandSegments(from start: WC, to end: WC) -> [Seg] {
        var (sy, sm, sd) = (start.year, start.month, start.day)
        var (ey, em, ed) = (end.year, end.month, end.day)
        if (ey, em, ed) < (sy, sm, sd) {
            swap(&sy, &ey); swap(&sm, &em); swap(&sd, &ed)
        }
        var out: [Seg] = []
        var (y, m) = (sy, sm)
        var guardN = 0
        while (y, m) <= (ey, em), guardN < 480 {
            guardN += 1
            let dim = daysInMonth(y, m - 1) // daysInMonth uses 0-based month
            let first = (y == sy && m == sm) ? sd : 1
            let lastD = (y == ey && m == em) ? ed : dim
            out.append(Seg(year: y, month: m - 1, startDay: max(1, min(dim, first)), endDay: max(1, min(dim, lastD))))
            m += 1; if m > 12 {
                m = 1; y += 1
            }
        }
        return out
    }

    /// ── Feed subscriptions (Google Calendar secret ICS URLs etc.) ─────────────────────
    /// Parse feed text into READ-ONLY imported items with STABLE ids that survive refetches:
    ///   series key  "gcal-<feedKey>-<uid>"          (user overlays — color/hide/notes — key here)
    ///   occurrence  "<series>-YYYYMMDD-HHMM"        (same suffix shape as the Apple import, so the
    ///                                                whole imported-series machinery applies)
    /// Recurring VEVENTs expand a subset of RRULE (DAILY/WEEKLY/BYDAY/YEARLY + INTERVAL + UNTIL +
    /// COUNT, minus EXDATEs) across `years`; overridden instances (RECURRENCE-ID) replace their slot.
    /// MONTHLY and fancier rules fall back to the base occurrence only.
    public static func feedItems(from text: String, feedKey: String, years: ClosedRange<Int>,
                                 provenance: String = "Calendar feed")
        -> (events: [TimedEvent], bands: [BandEvent], rich: [String: RichFields], uids: [String: String]) {
        var events: [TimedEvent] = [], bands: [BandEvent] = []
        var rich: [String: RichFields] = [:]
        var uids: [String: String] = [:] // series id → raw UID (for the Google "Edit original" link)
        let parsed = vevents(in: text)
        // Overridden instances claim their original slot so the base expansion skips it.
        var overridden: Set<String> = []
        for ve in parsed {
            if let rid = ve.recurrenceId, let uid = ve.uid {
                overridden.insert("\(uid)|\(rid.year)-\(rid.month)-\(rid.day)")
            }
        }

        func sanitize(_ u: String) -> String {
            String(u.map { $0.isLetter || $0.isNumber || "._@".contains($0) ? $0 : "_" }.prefix(64))
        }

        for ve in parsed {
            guard let s = ve.start else { continue }
            guard ve.status != "CANCELLED" else { continue } // cancelled instances aren't events
            let title = ve.summary.isEmpty ? "(untitled)" : ve.summary
            let uid = ve.uid ?? "\(title)-\(s.year)\(s.month)\(s.day)"
            let series = "gcal-\(feedKey)-\(sanitize(uid))"
            if ve.uid != nil {
                uids[series] = uid
            }
            let block = ManagedNote.render(provenance: provenance,
                                           meetingUrl: ve.url, location: ve.location, organizer: ve.organizer,
                                           attendees: ve.attendees.map { ($0.name, $0.status ?? "") },
                                           description: ve.description)
            if rich[series] == nil {
                rich[series] = importedRich(block.isEmpty ? nil : block)
            }

            // Occurrence start dates: the base date + RRULE expansion (skipping EXDATEs and slots
            // claimed by an overridden instance). An overridden instance is its own single event.
            var starts: [WC] = if ve.recurrenceId != nil {
                [s]
            } else if let rule = ve.rrule {
                expandRRule(base: s, rule: rule, years: years)
            } else {
                [s]
            }
            let ex = Set(ve.exdates.map { "\($0.year)-\($0.month)-\($0.day)" })
            starts = starts.filter { w in
                !ex.contains("\(w.year)-\(w.month)-\(w.day)")
                    && (ve.recurrenceId != nil || !overridden.contains("\(uid)|\(w.year)-\(w.month)-\(w.day)"))
            }

            for w in starts {
                guard years.contains(w.year) else { continue }
                let suffix = String(format: "-%04d%02d%02d-%02d%02d", w.year, w.month, w.day, w.hour, w.minute)
                if s.allDay {
                    let endEx = ve.effectiveEnd
                    let span = endEx.map { max(0, daysBetween(s, addDays($0, -1))) } ?? 0
                    for (i, seg) in bandSegments(from: w, to: addDays(w, span)).enumerated() {
                        bands.append(BandEvent(id: series + suffix + (i == 0 ? "" : "s\(i)"),
                                               year: seg.year, month: seg.month, track: 0,
                                               startDay: seg.startDay, endDay: seg.endDay,
                                               title: title, color: "default"))
                    }
                } else {
                    let dur = ve.effectiveEnd.map { max(0.25, wcHourSpan(from: s, to: $0)) } ?? 1
                    events.append(TimedEvent(id: series + suffix, year: w.year, month: w.month - 1, day: w.day,
                                             startHour: hourOf(w), endHour: min(24, hourOf(w) + dur),
                                             title: title, color: "default",
                                             anchorTz: DeadlineTZ.concrete("auto")))
                }
            }
        }
        return (events, bands, rich, uids)
    }

    private static func daysBetween(_ a: WC, _ b: WC) -> Int {
        let cal = utcCalendar
        var ca = DateComponents(); ca.year = a.year; ca.month = a.month; ca.day = a.day
        var cb = DateComponents(); cb.year = b.year; cb.month = b.month; cb.day = b.day
        guard let da = cal.date(from: ca), let db = cal.date(from: cb) else { return 0 }
        return cal.dateComponents([.day], from: da, to: db).day ?? 0
    }

    private static func wcHourSpan(from a: WC, to b: WC) -> CGFloat {
        let days = CGFloat(daysBetween(a, b))
        return days * 24 + (hourOf(b) - hourOf(a))
    }

    /// RRULE subset expansion in the device wall clock. Caps at 1000 occurrences.
    private static func expandRRule(base: WC, rule: String, years: ClosedRange<Int>) -> [WC] {
        var freq = "", interval = 1, count = Int.max
        var until: (Int, Int, Int)? = nil
        var byday: [Int] = [] // 0=Sun … 6=Sat
        let dayMap = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].uppercased() {
            case "FREQ": freq = kv[1].uppercased()
            case "INTERVAL": interval = max(1, Int(kv[1]) ?? 1)
            case "COUNT": count = max(1, Int(kv[1]) ?? 1)
            case "UNTIL":
                let v = kv[1]
                if v.count >= 8, let y = Int(v.prefix(4)), let m = Int(v.dropFirst(4).prefix(2)),
                   let d = Int(v.dropFirst(6).prefix(2)) {
                    until = (y, m, d)
                }
            case "BYDAY": byday = kv[1].split(separator: ",").compactMap { dayMap[String($0.suffix(2))] }
            default: break
            }
        }
        guard ["DAILY", "WEEKLY", "YEARLY"].contains(freq) else { return [base] } // MONTHLY etc. → base only

        let cal = utcCalendar
        var c = DateComponents(); c.year = base.year; c.month = base.month; c.day = base.day
        guard var cursor = cal.date(from: c) else { return [base] }
        var out: [WC] = []
        var made = 0, guardN = 0
        func wc(_ d: Date) -> WC {
            let x = cal.dateComponents([.year, .month, .day], from: d)
            return WC(year: x.year ?? base.year, month: x.month ?? base.month, day: x.day ?? base.day,
                      hour: base.hour, minute: base.minute, allDay: base.allDay)
        }
        func pastEnd(_ d: Date) -> Bool {
            let x = cal.dateComponents([.year, .month, .day], from: d)
            if (x.year ?? 0) > years.upperBound {
                return true
            }
            if let u = until, (x.year ?? 0, x.month ?? 0, x.day ?? 0) > u {
                return true
            }
            return false
        }
        while made < min(count, 1000), guardN < 20000, !pastEnd(cursor) {
            guardN += 1
            let dow = (cal.dateComponents([.weekday], from: cursor).weekday ?? 1) - 1
            let emit: Bool = switch freq {
            case "WEEKLY" where !byday.isEmpty:
                byday.contains(dow)
            default:
                true
            }
            if emit {
                out.append(wc(cursor)); made += 1
            }
            let step: DateComponents
            switch freq {
            case "DAILY": step = DateComponents(day: interval)
            case "YEARLY": step = DateComponents(year: interval)
            case "WEEKLY" where !byday.isEmpty:
                // walk day-by-day within the week; jump (interval-1) extra weeks at each week boundary
                let next = cal.date(byAdding: .day, value: 1, to: cursor)!
                let nextDow = (cal.dateComponents([.weekday], from: next).weekday ?? 1) - 1
                step = nextDow == 0 && interval > 1 ? DateComponents(day: 1 + 7 * (interval - 1)) :
                    DateComponents(day: 1)
            default: step = DateComponents(day: 7 * interval) // plain WEEKLY
            }
            guard let n = cal.date(byAdding: step, to: cursor) else { break }
            cursor = n
        }
        return out.isEmpty ? [base] : out
    }
}
