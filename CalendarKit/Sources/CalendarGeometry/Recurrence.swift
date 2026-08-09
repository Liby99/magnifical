// Recurrence expansion — a faithful port of the web's model/occurrences.ts (the ground truth).
// Expands a base date + repeat config into the occurrence dates that fall within a displayed
// year (the base itself is rendered by the event; these are the extra "ghost" copies). A base
// from another year still yields its in-year occurrences, so recurrence crosses years.
//
// All date math is done in a fixed UTC gregorian calendar so it's deterministic and DST-free —
// only y/m/d are ever read out, matching the web's wall-clock treatment.

import Foundation

public struct YMD: Sendable, Equatable, Hashable {
    public var year: Int
    public var month: Int // 0-based, matching the web
    public var day: Int
    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year; self.month = month; self.day = day
    }
}

/// Recurrence config, mirroring the web `Repeat` (kind + optional n/until/days/exdates).
public struct Repeat: Sendable, Equatable, Codable {
    public var kind: String // "none" | "daily" | "weekly" | "weekdays" | "yearly"
    public var n: Int? // every n weeks/years (default 1)
    public var until: String? // "YYYY-MM-DD" inclusive end, or nil
    public var days: [Int]? // weekdays 0=Sun..6=Sat (weekdays kind)
    public var exdates: [String]? // excluded occurrence dates "YYYY-MM-DD" — the "holes"

    public init(kind: String, n: Int? = nil, until: String? = nil, days: [Int]? = nil, exdates: [String]? = nil) {
        self.kind = kind; self.n = n; self.until = until; self.days = days; self.exdates = exdates
    }

    /// Parse the serialized repeat carried in RichFields.repeatJSON; nil / "none" → nil.
    public static func parse(_ json: String?) -> Repeat? {
        guard let json, let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(Repeat.self, from: data), r.kind != "none" else { return nil }
        return r
    }
}

public func occDate(_ p: YMD) -> String {
    String(format: "%04d-%02d-%02d", p.year, p.month + 1, p.day)
}

public func occKey(_ id: String, _ p: YMD) -> String {
    "\(id)@\(p.year)-\(p.month)-\(p.day)"
}

/// The real item id behind a display-box id: an occurrence "ghost" carries `realId@Y-M-D` (see occKey),
/// optionally with a promoted (`~p`) or month-segment (`#segN`) marker after it; a base box carries the
/// real id verbatim. Used to highlight a whole series when any one of its boxes is selected.
///
/// The occurrence suffix is only ever appended at the END, so we strip a *trailing* `@Y-M-D[marker]` —
/// NOT the first `@`. An imported id bakes the vendor uid in (`apple-<uid>-<datestamp>`), and Google /
/// Exchange uids routinely contain `@` (e.g. `…@google.com`); splitting on the first `@` truncated those
/// so the item couldn't be found and its drawer immediately closed.
public func sourceId(of boxId: String) -> String {
    // Manual parse of the trailing `@Y-M-D(~p|#segN)?` — equivalent to matching
    // `@[0-9]+-[0-9]+-[0-9]+(~p|#seg[0-9]+)?$`. This runs per box on every display-cache rebuild;
    // an uncached `.regularExpression` search here re-prepared its pattern each call and dominated
    // the week-swipe frame profile (62% of the main thread).
    var s = boxId[...]
    if s.hasSuffix(PROMOTED_SUFFIX) {
        s = s.dropLast(PROMOTED_SUFFIX.count)
    } else if let t = dropTrailingDigits(s), t.hasSuffix(SEGMENT_MARKER) {
        s = t.dropLast(SEGMENT_MARKER.count)
    }
    guard let d = dropTrailingDigits(s), d.last == "-",
          let m = dropTrailingDigits(d.dropLast()), m.last == "-",
          let y = dropTrailingDigits(m.dropLast()), y.last == "@"
    else { return boxId } // no full `@Y-M-D` suffix → a base box: the id IS the source id
    return String(y.dropLast())
}

/// The substring left after removing a trailing run of ASCII digits, or nil when there is none.
private func dropTrailingDigits(_ s: Substring) -> Substring? {
    var t = s
    while let c = t.last, ("0" ... "9").contains(c) {
        t = t.dropLast()
    }
    return t.endIndex == s.endIndex ? nil : t
}

/// Marker appended to a PROMOTED band box id so it's a DISTINCT box from the timeline occurrence it
/// mirrors (which shares the same `id@Y-M-D` occKey). `sourceId` ignores it (it lives after the `@`),
/// so both still map to the source. Navigation/selection treat the two as independent items.
public let PROMOTED_SUFFIX = "~p"
/// Marker appended to the TAIL bars of a band occurrence that crosses a month boundary (rendered as one
/// bar per month). Like `PROMOTED_SUFFIX` it lives after the `@`, so `sourceId` ignores it and every
/// segment maps to the source; `occurrenceKey` strips it so all segments share one occurrence key.
public let SEGMENT_MARKER = "#seg"
/// The occurrence-DATE key for a box (strips the promoted + segment markers) — so a promoted bar, a
/// month-crossing tail segment, and the timeline occurrence all resolve to the same per-occurrence date.
public func occurrenceKey(of boxId: String) -> String {
    var s = boxId[...]
    if let t = dropTrailingDigits(s), t.hasSuffix(SEGMENT_MARKER) { // `#segN$`, sans regex (hot path)
        s = t.dropLast(SEGMENT_MARKER.count)
    }
    if s.hasSuffix(PROMOTED_SUFFIX) {
        s = s.dropLast(PROMOTED_SUFFIX.count)
    }
    return s.endIndex == boxId.endIndex ? boxId : String(s)
}

/// Provenance/kind markers shown as tiny glyphs on an event box (see the overlay). Derived per box
/// from the source item's rich fields + the box's nature (ghost = recurrent, promoted-band = promoted).
public struct EventBadges: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let recurrent = EventBadges(rawValue: 1 << 0)
    public static let promoted = EventBadges(rawValue: 1 << 1)
    public static let ai = EventBadges(rawValue: 1 << 2)
    public static let imported = EventBadges(rawValue: 1 << 3)
    public static let hidden =
        EventBadges(rawValue: 1 << 4) // user-hidden imported, revealed by "Show Hidden" → dotted bar
}

// ── Date helpers (UTC, calendar-based add so no DST drift) ────────────────────────────
private let utcCal = utcCalendar // canonical UTC calendar (Dates.swift)
private func date(_ y: Int, _ m0: Int, _ d: Int) -> Date {
    utcCal.date(from: DateComponents(year: y, month: m0 + 1, day: d)) ?? Date(timeIntervalSince1970: 0)
}

private func addDays(_ d: Date, _ n: Int) -> Date {
    utcCal.date(byAdding: .day, value: n, to: d) ?? d
}

private func daysBetween(_ a: Date, _ b: Date) -> Int {
    utcCal.dateComponents([.day], from: a, to: b).day ?? 0
}

private func ymdOf(_ d: Date) -> YMD {
    let c = utcCal.dateComponents([.year, .month, .day], from: d)
    return YMD(c.year ?? 0, (c.month ?? 1) - 1, c.day ?? 1)
}

private func weekday0(_ d: Date) -> Int {
    utcCal.component(.weekday, from: d) - 1
} // 0=Sun..6=Sat
private func parseDate(_ s: String) -> Date? {
    let p = s.split(separator: "-").map { Int($0) ?? -1 }
    guard p.count == 3, !p.contains(-1) else { return nil }
    return date(p[0], p[1] - 1, p[2])
}

private let MAX = 400 // safety cap per displayed year

/// First base + k·stepDays (k ≥ 1) that is ≥ winStart — jumps whole spans instead of stepping
/// day-by-day from a far-back base.
private func firstStepIn(_ base: Date, _ step: Int, _ winStart: Date) -> Date {
    let gapDays = daysBetween(base, winStart)
    let k = gapDays > step ? gapDays / step : 1
    var d = addDays(base, step * k)
    while d < winStart {
        d = addDays(d, step)
    }
    return d
}

/// Largest in-phase week-start ≤ winStart (so boundary-week days aren't skipped); base week if later.
private func firstWeekIn(_ baseWeek: Date, _ step: Int, _ winStart: Date) -> Date {
    if baseWeek >= winStart {
        return baseWeek
    }
    let k = daysBetween(baseWeek, winStart) / step
    return addDays(baseWeek, step * k)
}

/// The occurrence dates of `repeat` (excluding the base itself) that land in `year`, with
/// exdates and `until` applied. Empty for a non-recurring or out-of-window series.
public func occurrenceDates(_ base: YMD, _ rep: Repeat?, _ year: Int) -> [YMD] {
    guard let rep, rep.kind != "none" else { return [] }
    let baseDate = date(base.year, base.month, base.day)
    let winStart = date(year, 0, 1)
    let yearEnd = date(year, 11, 31)
    let until = rep.until.flatMap(parseDate)
    let winEnd = (until != nil && until! < yearEnd) ? until! : yearEnd
    if winEnd < winStart {
        return []
    }
    let ex = Set(rep.exdates ?? [])
    let n = max(1, rep.n ?? 1)
    var out: [YMD] = []

    func add(_ d: Date) {
        if d <= baseDate || d < winStart || d > winEnd {
            return
        }
        let p = ymdOf(d)
        if !ex.contains(occDate(p)) {
            out.append(p)
        }
    }

    switch rep.kind {
    case "daily":
        var d = baseDate >= winStart ? addDays(baseDate, 1) : winStart
        while d <= winEnd && out.count < MAX {
            add(d); d = addDays(d, 1)
        }
    case "weekly":
        let step = 7 * n
        var d = firstStepIn(baseDate, step, winStart)
        while d <= winEnd && out.count < MAX {
            add(d); d = addDays(d, step)
        }
    case "yearly":
        if year > base.year && (year - base.year) % n == 0 {
            add(date(year, base.month, base.day))
        }
    default: // "weekdays": selected weekdays, every n weeks (phase anchored to the base week)
        let days = (rep.days?.isEmpty == false) ? rep.days! : [weekday0(baseDate)]
        let baseWeek = addDays(baseDate, -weekday0(baseDate)) // Sunday of the base week
        let step = 7 * n
        var ws = firstWeekIn(baseWeek, step, winStart)
        while ws <= winEnd && out.count < MAX {
            for dow in days {
                add(addDays(ws, dow))
            }
            ws = addDays(ws, step)
        }
    }
    return out
}

/// The base occurrence renders directly, so it must independently honor the same exclusions:
/// its own date being an exdate ("delete just this") or past `until` ("delete this & following").
public func baseHidden(_ dateStr: String, _ rep: Repeat?) -> Bool {
    guard let rep, rep.kind != "none" else { return false }
    if (rep.exdates ?? []).contains(dateStr) {
        return true
    }
    if let until = rep.until, dateStr > until {
        return true
    } // "YYYY-MM-DD" compares chronologically
    return false
}
