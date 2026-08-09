// Curated timezone catalog for the View ▸ Timezone pickers and the drawer's anchor picker.
// Labels are SYSTEMATIC and generated live: "UTC−7 · PDT · Los Angeles / San Francisco" —
// offset first, then the abbreviation when the system has a lettered one (redundant "GMT+8"
// styles are skipped), then key places. Offsets/abbreviations are DST-aware (computed at
// access time), so Los Angeles truthfully reads UTC−8 · PST in winter and UTC−7 · PDT in
// summer. Lists are sorted by current offset, west → east. "auto" tracks the device zone.

import Foundation

public enum CalendarTimezones {
    public static let autoId = "auto"

    public struct Zone: Identifiable, Sendable, Hashable {
        public let id: String // IANA identifier, "auto", or "AOE"
        public let label: String
    }

    /// The curated zones, their key places (mirrors the web app's MAIN_TZS coverage), and a
    /// (standard, daylight) abbreviation fallback for zones Foundation only names "GMT+9"-style.
    /// nil abbr → rely on Foundation (the US zones resolve to PST/PDT etc. by themselves).
    private static let catalog: [(id: String, places: String, abbr: (std: String, dst: String)?)] = [
        ("America/Los_Angeles", "Los Angeles / San Francisco", nil),
        ("America/Denver", "Denver", nil),
        ("America/Chicago", "Chicago", nil),
        ("America/New_York", "New York / Boston", nil),
        ("America/Sao_Paulo", "São Paulo", ("BRT", "BRT")),
        ("Europe/London", "London", ("GMT", "BST")),
        ("Europe/Paris", "Paris / Berlin", ("CET", "CEST")),
        ("Europe/Athens", "Athens / Helsinki", ("EET", "EEST")),
        ("Asia/Dubai", "Dubai", ("GST", "GST")),
        ("Asia/Kolkata", "Mumbai / New Delhi", ("IST", "IST")),
        ("Asia/Shanghai", "Beijing / Shanghai", nil), // "CST" here would read as US Central — omit
        ("Asia/Tokyo", "Tokyo", ("JST", "JST")),
        ("Australia/Sydney", "Sydney", ("AEST", "AEDT")),
        ("Pacific/Auckland", "Auckland", ("NZST", "NZDT")),
        ("UTC", "", nil),
    ]

    /// "UTC", "UTC−7", "UTC+5:30" — minutes only when the zone actually has them.
    private static func offsetString(_ seconds: Int) -> String {
        if seconds == 0 {
            return "UTC"
        }
        let sign = seconds < 0 ? "−" : "+"
        let a = abs(seconds)
        let h = a / 3600, m = (a % 3600) / 60
        return m == 0 ? "UTC\(sign)\(h)" : "UTC\(sign)\(h):\(String(format: "%02d", m))"
    }

    /// One systematic entry: offset · abbreviation (lettered ones only) · places. DST-aware "now".
    private static func entry(_ id: String, _ places: String, _ abbr: (std: String, dst: String)?,
                              at now: Date) -> (offset: Int, zone: Zone) {
        guard let tz = TimeZone(identifier: id) else {
            return (0, Zone(id: id, label: places.isEmpty ? id : places))
        }
        let off = tz.secondsFromGMT(for: now)
        var parts = [offsetString(off)]
        if let ab = tz.abbreviation(for: now), ab.allSatisfy(\.isLetter), ab != "GMT", ab != "UTC" {
            parts.append(ab) // Foundation knows a real lettered name (the US zones)
        } else if let abbr {
            parts.append(tz.isDaylightSavingTime(for: now) ? abbr.dst : abbr.std)
        }
        if !places.isEmpty {
            parts.append(places)
        }
        return (off, Zone(id: id, label: parts.joined(separator: " · ")))
    }

    /// The view (main/alt) picker list: Automatic first, then the concrete zones west → east.
    public static var all: [Zone] {
        let now = Date()
        let sorted = catalog.enumerated()
            .map { i, c in (i, entry(c.id, c.places, c.abbr, at: now)) }
            .sorted { ($0.1.offset, $0.0) < ($1.1.offset, $1.0) } // offset, catalog order tie-break
            .map(\.1.zone)
        return [Zone(id: autoId, label: "Automatic (Device)")] + sorted
    }

    /// "AOE" (Anywhere on Earth = UTC−12, the CfP-deadline convention). A pseudo-zone: offered as
    /// an item ANCHOR (the drawer's timezone picker) but not as a view zone — the grid's main/alt
    /// pickers stay concrete-IANA-only. DeadlineTZ resolves it to Etc/GMT+12 everywhere.
    public static let aoe = Zone(id: "AOE", label: "UTC−12 · AOE · Anywhere on Earth")

    /// The drawer's anchor-zone choices: AOE + every concrete zone, west → east (AOE's −12 puts it
    /// first). No "auto" — a stored anchor must never drift with the device.
    public static var anchorZones: [Zone] {
        [aoe] + all.filter { $0.id != autoId }
    }

    public static func label(for id: String) -> String {
        (all + [aoe]).first { $0.id == id }?.label ?? id
    }
}
