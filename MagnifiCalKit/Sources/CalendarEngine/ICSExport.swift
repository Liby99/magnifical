// Single-event .ics export (RFC 5545 subset) — the event menu's "Export .ics" / "Email Event".
// Timed events/deadlines carry their anchor timezone as TZID wall-clock times; bands are
// all-day DATE spans (DTEND exclusive). Recurrence maps the app's Repeat subset to RRULE.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// A one-VEVENT VCALENDAR for the box's SOURCE item, or nil if the id resolves to nothing.
    public func icsText(for boxId: String) -> String? {
        let src = sourceId(of: boxId)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//MagnifiCal//EN", "BEGIN:VEVENT",
                     "UID:\(src)@magical", "DTSTAMP:\(Self.icsUTCStamp(Date()))"]
        let notes: String? = {
            let n = self.notes(src)
            return n.isEmpty ? nil : n
        }()

        if let e = event(src) {
            let tz = e.anchorTz ?? DeadlineTZ.concrete(mainTz)
            lines.append("SUMMARY:\(Self.icsEscape(e.title))")
            lines.append("DTSTART;TZID=\(tz):\(Self.icsLocal(e.year, e.month, e.day, e.startHour))")
            lines.append("DTEND;TZID=\(tz):\(Self.icsLocal(e.year, e.month, e.day, min(e.endHour, 24)))")
        } else if let b = band(src) {
            lines.append("SUMMARY:\(Self.icsEscape(b.title))")
            lines.append("DTSTART;VALUE=DATE:\(Self.icsDate(YMD(b.year, b.month, b.startDay)))")
            // DTEND is EXCLUSIVE for all-day events → the day after the last day.
            lines.append("DTEND;VALUE=DATE:\(Self.icsDate(Self.addDaysYMD(YMD(b.year, b.month, b.endDay), 1)))")
        } else if let d = deadline(src) {
            let tz = d.anchorTz ?? DeadlineTZ.concrete(mainTz)
            lines.append("SUMMARY:\(Self.icsEscape(d.title))")
            lines.append("DTSTART;TZID=\(tz):\(Self.icsLocal(d.year, d.month, d.day, d.hour))")
        } else {
            return nil
        }

        if let n = notes {
            lines.append("DESCRIPTION:\(Self.icsEscape(n))")
        }
        if let rep = repeatConfig(src), let rrule = Self.icsRRule(rep) {
            lines.append(rrule)
            for ex in rep.exdates ?? [] where ex.count == 10 { // "YYYY-MM-DD"
                lines.append("EXDATE;VALUE=DATE:\(ex.replacingOccurrences(of: "-", with: ""))")
            }
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The app's Repeat subset → RRULE (nil for "none"/unknown kinds).
    static func icsRRule(_ rep: Repeat) -> String? {
        let interval = max(1, rep.n ?? 1)
        var parts: [String]
        switch rep.kind {
        case "daily": parts = ["FREQ=DAILY"]
        case "weekly": parts = ["FREQ=WEEKLY"]
        case "yearly": parts = ["FREQ=YEARLY"]
        case "weekdays":
            let names = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            let days = (rep.days?.isEmpty == false ? rep.days! : [1, 2, 3, 4, 5])
            parts = [
                "FREQ=WEEKLY",
                "BYDAY=" + days.compactMap { $0 >= 0 && $0 < 7 ? names[$0] : nil }.joined(separator: ","),
            ]
        default: return nil
        }
        if interval > 1 {
            parts.append("INTERVAL=\(interval)")
        }
        if let until = rep.until, until.count == 10 {
            parts.append("UNTIL=\(until.replacingOccurrences(of: "-", with: ""))")
        }
        return "RRULE:" + parts.joined(separator: ";")
    }

    /// ── Formatting helpers ──
    static func icsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func icsDate(_ d: YMD) -> String {
        String(format: "%04d%02d%02d", d.year, d.month + 1, d.day)
    }

    static func icsLocal(_ year: Int, _ month0: Int, _ day: Int, _ hour: CGFloat) -> String {
        let mins = max(0, min(24 * 60, Int((hour * 60).rounded())))
        // 24:00 → 00:00 next day would need a date bump; clamp to 23:59:59 instead (rare edge).
        let m = min(mins, 24 * 60 - 1)
        return String(format: "%04d%02d%02dT%02d%02d00", year, month0 + 1, day, m / 60, m % 60)
    }

    static func icsUTCStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = utcTimeZone
        return f.string(from: date)
    }
}
