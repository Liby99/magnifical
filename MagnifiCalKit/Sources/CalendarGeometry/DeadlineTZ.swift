// Deadline origin-timezone display — a port of the web's tz helpers (lib/calendar/api.ts).
//
// A deadline's `hour` is stored in the user's MAIN timezone; a CfP is often *given* in another
// zone ("AOE 23:59"). We keep that origin zone on the deadline and derive the origin-tz time for
// display: "AOE 23:59" alongside the main-tz "18:59". Conversion is DST-aware via Foundation's
// TimeZone. Two pseudo-ids: "AOE" (Anywhere on Earth = UTC-12 → Etc/GMT+12) and "auto" (the main
// tz sentinel → the device's current zone).

import Foundation

public enum DeadlineTZ {
    /// Resolve a stored tz id to a concrete IANA zone. "auto" → device zone; "AOE" → Etc/GMT+12.
    public static func iana(_ tz: String) -> String {
        if tz == "auto" {
            return TimeZone.current.identifier
        }
        if tz == "AOE" {
            return "Etc/GMT+12"
        }
        return tz
    }

    /// Short abbreviation shown in the "(ABBR HH:MM)" part; "AOE" keeps its own label.
    public static func shortLabel(_ tz: String, at date: Date) -> String {
        if tz == "AOE" {
            return "AOE"
        }
        let z = TimeZone(identifier: iana(tz)) ?? .gmt
        return z.abbreviation(for: date) ?? tz
    }

    private static func offset(_ tz: String, at date: Date) -> Int {
        (TimeZone(identifier: iana(tz)) ?? .gmt).secondsFromGMT(for: date)
    }

    /// Resolve "auto" to the concrete device zone id; pass everything else through (incl. "AOE").
    /// Used to stamp a FIXED anchor at create/migration time — a stored anchor must never be "auto"
    /// (that would drift as the device zone changes).
    public static func concrete(_ tz: String) -> String {
        tz == "auto" ? TimeZone.current.identifier : tz
    }

    /// True when two zone ids denote the same UTC offset at `date` — so no display shift or secondary
    /// label is needed. Resolves "auto"/"AOE" first, so e.g. "auto"==device and equal-offset zones match.
    public static func sameOffset(_ a: String, _ b: String, at date: Date) -> Bool {
        offset(a, at: date) == offset(b, at: date)
    }

    /// A floating wall-clock (y, 0-based month, d, fractional hour) as its UTC-encoded instant. Public
    /// so callers can pick the DST-correct moment; `hour` may exceed 24 (a cross-midnight event's end).
    public static func instant(_ y: Int, _ m0: Int, _ d: Int, _ hour: CGFloat) -> Date {
        utcInstant(y, m0, d, hour)
    }

    /// Re-express a wall-clock from zone `from` into zone `to`, DST-aware, normalizing across midnight so
    /// the returned year/month/day are correct (e.g. 01:00 ET → 22:00 the PREVIOUS day PT). Identity when
    /// the two zones share an offset. This is the single converter used by both display (anchor→main) and
    /// write-back (main→anchor).
    public static func convertWall(_ y: Int, _ m0: Int, _ d: Int, _ hour: CGFloat,
                                   from: String, to: String) -> (year: Int, month: Int, day: Int, hour: CGFloat) {
        let base = utcInstant(y, m0, d, hour) // the wall-clock as a UTC-encoded instant
        let delta = Double(offset(to, at: base) - offset(from, at: base))
        let shifted = base.addingTimeInterval(delta) // same instant, expressed in `to`
        let c = utcCal.dateComponents([.year, .month, .day, .hour, .minute], from: shifted)
        let hr = CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60
        return (c.year ?? y, (c.month ?? 1) - 1, c.day ?? d, hr)
    }

    /// Fractional-hour shift to add to a `mainTz` wall-clock hour to get the same instant's `altTz`
    /// wall-clock hour (e.g. ET→Tokyo ≈ +13/+14, ET→India = +9.5/+10.5). DST-aware at `date`. Used to
    /// label the alternative-timezone hour column on the timeline.
    public static func hourShift(from mainTz: String, to altTz: String, at date: Date) -> Double {
        Double(offset(altTz, at: date) - offset(mainTz, at: date)) / 3600
    }

    private static let utcCal = utcCalendar // canonical UTC calendar (Dates.swift)
    /// The floating wall-clock (y, m0, d, fractional hour) as a UTC-encoded instant — matching the
    /// web's parseWallClock: the string is treated as if it were UTC so only y/m/d/h/m are meaningful.
    private static func utcInstant(_ y: Int, _ m0: Int, _ d: Int, _ hour: CGFloat) -> Date {
        let h = Int(hour), mi = Int((hour - CGFloat(h)) * 60 + 0.5)
        return utcCal
            .date(from: DateComponents(year: y, month: m0 + 1, day: d, hour: h, minute: mi)) ??
            Date(timeIntervalSince1970: 0)
    }

    /// The deadline's time re-expressed in its origin timezone, as "ABBR HH:MM" (e.g. "AOE 23:59").
    /// nil when the deadline has no distinct origin tz. `mainTz` is where `hour` is expressed.
    public static func originLabel(_ d: Deadline, mainTz: String) -> String? {
        guard let otz = d.originTz, otz != mainTz else { return nil }
        let base = utcInstant(d.year, d.month, d.day, d.hour) // main-tz wall clock, UTC-encoded
        // Same instant, re-expressed in the origin zone: shift by the offset delta (same trick the web uses).
        let shifted = base.addingTimeInterval(Double(offset(otz, at: base) - offset(mainTz, at: base)))
        let c = utcCal.dateComponents([.hour, .minute], from: shifted)
        return String(format: "%@ %02d:%02d", shortLabel(otz, at: base), c.hour ?? 0, c.minute ?? 0)
    }
}
