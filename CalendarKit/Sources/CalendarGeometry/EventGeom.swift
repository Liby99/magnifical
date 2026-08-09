// Timed-event data ↔ screen geometry, mirroring scene.ts buildDetail so events line
// up exactly with the rendered day columns / hour timeline. Ported from geometry/eventGeom.ts.

import CoreGraphics

public let MIN_HOUR_H: CGFloat = 35
public let MAX_HOUR_H: CGFloat = 90

public func clampHourH(_ h: CGFloat) -> CGFloat {
    min(MAX_HOUR_H, max(MIN_HOUR_H, h))
}

public struct HourMetrics: Sendable {
    public var viewH: CGFloat
    public var hourH: CGFloat
    public var maxScroll: CGFloat
    public var zoomable: Bool
    public var scroll: CGFloat
}

/// Hour height + scroll for a timeline window. month (z≤1) fits the viewport; week
/// (z≥2) uses the slider height. `weekHourH` was a module global in the TS.
public func hourMetrics(_ tlTop: CGFloat, _ tlBottom: CGFloat, _ z: CGFloat, _ tlScroll: CGFloat,
                        _ weekHourH: CGFloat) -> HourMetrics {
    let viewH = max(0, tlBottom - tlTop)
    let fitH = viewH > 0 ? viewH / 24 : 0
    let weekMin = max(MIN_HOUR_H, fitH)
    let weekMax = max(weekMin, MAX_HOUR_H)
    let weekH = min(weekMax, max(weekMin, weekHourH))
    let hourH = fitH + (weekH - fitH) * min(1, max(0, z - 1))
    let maxScroll = max(0, 24 * hourH - viewH)
    let zoomable = fitH < MAX_HOUR_H
    // Allow a bounded overscroll past the ends (the engine rubber-bands + springs `tlScroll`), so
    // the elastic bounce is visible; clamp only to a safe margin against stale/extreme values.
    let over: CGFloat = 220
    return HourMetrics(viewH: viewH, hourH: hourH, maxScroll: maxScroll, zoomable: zoomable,
                       scroll: min(max(-over, tlScroll), maxScroll + over))
}

public func incomingDetailReveal(_ p: CGFloat) -> CGFloat {
    min(1, max(0, (p - 0.45) / 0.4))
}

/// The outgoing month's daily timeline dissolves early in the page-turn, handing off to the
/// incoming month's timeline (which reveals from p≈0.45) — so the two cross-fade in the middle.
public func outgoingDetailReveal(_ p: CGFloat) -> CGFloat {
    1 - min(1, max(0, p / 0.55))
}

public struct TimelineInfo: Sendable {
    public var x0: CGFloat
    public var colW: CGFloat
    public var tlTop: CGFloat
    public var tlBottom: CGFloat
    public var viewH: CGFloat
    public var hourH: CGFloat
    public var scroll: CGFloat
    public var maxScroll: CGFloat
    public var zoomable: Bool
    public var reveal: CGFloat
    public var wide: Bool
}

/// Single source of truth for the day-detail timeline geometry. `focus`/`anim` override the
/// month + page-turn frame so a page-turn can lay out the incoming month's timeline (sliding
/// in) as well as the outgoing one (sliding out) — both cross-fade with their events.
public func timelineInfo(_ g: SceneInput, focus: Int? = nil, anim: PageAnim? = nil,
                         detailMul: CGFloat = 1) -> TimelineInfo {
    let f = frameFor(focus ?? g.focus, g, anim: anim)
    let tlTop = f.bandY + 4 * f.trackH + 18
    let tlBottom = Layout.tlBottomY(g.vp.h)
    let m = hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH)
    let reveal = (g.z < Layout.detailZ ? 0 : min(1, max(0, (g.z - Layout.detailZ) / Layout.detailRamp))) * detailMul
    return TimelineInfo(x0: f.x0, colW: f.dayW, tlTop: tlTop, tlBottom: tlBottom, viewH: m.viewH,
                        hourH: m.hourH, scroll: m.scroll, maxScroll: m.maxScroll, zoomable: m.zoomable,
                        reveal: reveal, wide: f.dayW > 60)
}

/// An absolute date `(evYear, month, day)` expressed in `focus`'s day-of-month numbering (≤0 / >dim
/// for spillover), or nil if it isn't the focus month or one of its immediate neighbors. The neighbor
/// months wrap across the year boundary (Dec's next = Jan of `focusYear+1`; Jan's prev = Dec of
/// `focusYear-1`), and `evYear` disambiguates those from a same-year month 11 months away.
public func relDomOf(_ focusYear: Int, _ focus: Int, _ evYear: Int, _ month: Int, _ day: Int) -> Int? {
    if evYear == focusYear && month == focus {
        return day
    }
    let pm = (focus + 11) % 12, py = focus == 0 ? focusYear - 1 : focusYear // previous month
    if evYear == py && month == pm {
        return day - daysInMonth(py, pm)
    }
    let nm = (focus + 1) % 12, ny = focus == 11 ? focusYear + 1 : focusYear // next month
    if evYear == ny && month == nm {
        return daysInMonth(focusYear, focus) + day
    }
    return nil
}

// ── A minimal timed event for seed/display + its overlap layout ──────────────────

public let EVENT_COLORS = [
    "default",
    "blue",
    "indigo",
    "cyan",
    "green",
    "darkgreen",
    "yellow",
    "orange",
    "red",
    "purple",
]
/// The right-click menu's quick palette — the web app's MENU_COLORS subset of EVENT_COLORS.
public let MENU_COLORS = ["default", "blue", "green", "yellow", "red", "purple"]

public struct TimedEvent: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var year: Int // absolute year — the view is year-scoped, so this must be stored
    public var month: Int
    public var day: Int
    public var startHour: CGFloat
    public var endHour: CGFloat
    public var title: String
    public var color: String
    // The timezone this event is anchored to (a concrete IANA id, or "AOE"); nil = the main tz is
    // canonical. year/month/day/startHour/endHour are the wall-clock IN this zone; the absolute instant
    // is derived, and the timeline converts anchorTz→mainTz for display. Never stored as "auto" (a fixed
    // anchor must not drift with the device). Optional so older stores/records decode unchanged.
    public var anchorTz: String?
    public init(
        id: String,
        year: Int,
        month: Int,
        day: Int,
        startHour: CGFloat,
        endHour: CGFloat,
        title: String,
        color: String,
        anchorTz: String? = nil
    ) {
        self.id = id; self.year = year; self.month = month; self.day = day; self.startHour = startHour
        self.endHour = endHour; self.title = title; self.color = color; self.anchorTz = anchorTz
    }
}

public struct EventLayout: Sendable {
    public var col: Int; public var nCols: Int; public var level: Int; public var maxLevel: Int
}

private let TITLE_H: CGFloat = 1
private let INDENT_PX: CGFloat = 9
private let MIN_W: CGFloat = 26

/// Side-by-side + cascade overlap packing within a day column. Ported from layoutDay().
public func layoutDay(_ events: [TimedEvent]) -> [String: EventLayout] {
    var out: [String: EventLayout] = [:]
    let sorted = events
        .sorted { a, b in a.startHour != b.startHour ? a.startHour < b.startHour : a.endHour > b.endHour }
    var level: [String: Int] = [:]
    struct PackCol { var events: [TimedEvent]; var maxTitleEnd: CGFloat }
    var cols: [PackCol] = []
    var clusterEnd: CGFloat = -.greatestFiniteMagnitude

    func flush() {
        if cols.isEmpty {
            return
        }
        let nCols = cols.count
        for (ci, c) in cols.enumerated() {
            var maxLevel = 0
            for e in c.events {
                maxLevel = max(maxLevel, level[e.id] ?? 0)
            }
            for e in c.events {
                out[e.id] = EventLayout(
                    col: ci,
                    nCols: nCols,
                    level: level[e.id] ?? 0,
                    maxLevel: maxLevel
                )
            }
        }
        cols = []
    }

    for ev in sorted {
        if ev.startHour >= clusterEnd {
            flush(); clusterEnd = -.greatestFiniteMagnitude
        }
        let titleEnd = min(ev.startHour + TITLE_H, ev.endHour)
        var idx = cols.firstIndex { $0.maxTitleEnd <= ev.startHour }
        if idx == nil {
            cols.append(PackCol(events: [], maxTitleEnd: -.greatestFiniteMagnitude)); idx = cols.count - 1
        }
        var lvl = 0
        for p in cols[idx!].events where p.endHour > ev.startHour {
            lvl = max(lvl, (level[p.id] ?? 0) + 1)
        }
        level[ev.id] = lvl
        cols[idx!].events.append(ev)
        cols[idx!].maxTitleEnd = max(cols[idx!].maxTitleEnd, titleEnd)
        clusterEnd = max(clusterEnd, ev.endHour)
    }
    flush()
    return out
}

/// Placement of an event within the day-detail timeline. Ported from eventRect().
public func eventRect(
    _ ev: TimedEvent,
    _ year: Int,
    _ focus: Int,
    _ tl: TimelineInfo,
    _ vp: Viewport,
    _ layout: EventLayout? = nil
) -> CGRect? {
    guard let dom = relDomOf(year, focus, ev.year, ev.month, ev.day), tl.hourH > 0 else { return nil }
    let colX = tl.x0 + (CGFloat(dom) - 1) * tl.colW
    if colX + tl.colW < -40 || colX > vp.w + 40 {
        return nil
    }
    let col = layout?.col ?? 0
    let nCols = layout?.nCols ?? 1
    let level = layout?.level ?? 0
    let maxLevel = layout?.maxLevel ?? 0
    let subW = tl.colW / CGFloat(nCols)
    let indent = maxLevel > 0 ? min(INDENT_PX, max(0, (subW - MIN_W) / CGFloat(maxLevel))) : 0
    return CGRect(
        x: colX + CGFloat(col) * subW + CGFloat(level) * indent + 2,
        y: ev.startHour * tl.hourH + 1,
        width: max(3, subW - CGFloat(maxLevel) * indent - 4),
        height: max(3, (ev.endHour - ev.startHour) * tl.hourH - 2)
    )
}

/// ── Cross-midnight segmentation ──────────────────────────────────────────────────
/// One render slice of a timed event within a single day column. A same-day event yields one segment
/// (both clip flags false). An event whose span crosses midnight — `endHour > 24`, whether a red-eye
/// authored that way or a tz conversion that straddles the view's midnight — yields one segment per day
/// it touches, each clipped on the edge where it continues over the daily border (square corner + the
/// accent bar running to that edge), mirroring how a band reads as "continued" across a month boundary.
public struct TimedSegment: Sendable, Equatable {
    public let event: TimedEvent // a copy clamped to THIS day's [startHour, endHour]; shares the id/title/color
    public let clipTop: Bool // continues up from the previous day → square TOP, bar to the top edge
    public let clipBottom: Bool // continues down into the next day → square BOTTOM, bar to the bottom edge
    public let fullStart: CGFloat // the whole event's start/end (for the time label — every slice shows the
    public let fullEnd: CGFloat // real span, e.g. "23:00 – 06:00", not just the clamped slice)
    public init(event: TimedEvent, clipTop: Bool, clipBottom: Bool, fullStart: CGFloat, fullEnd: CGFloat) {
        self.event = event; self.clipTop = clipTop; self.clipBottom = clipBottom
        self.fullStart = fullStart; self.fullEnd = fullEnd
    }
}

/// The calendar day after (year, 0-based month, day), rolling month/year.
public func nextDay(_ y: Int, _ m: Int, _ d: Int) -> (Int, Int, Int) {
    if d < daysInMonth(y, m) {
        return (y, m, d + 1)
    }
    if m < 11 {
        return (y, m + 1, 1)
    }
    return (y + 1, 0, 1)
}

/// Split a display-space timed event into per-day segments. `startHour ∈ [0,24)`, `endHour > startHour`
/// (may exceed 24 for a span crossing one or more midnights). Dates roll over month/year correctly.
public func timedSegments(_ e: TimedEvent) -> [TimedSegment] {
    guard e.endHour > 24 else { return [TimedSegment(
        event: e,
        clipTop: false,
        clipBottom: false,
        fullStart: e.startHour,
        fullEnd: e.endHour
    )] }
    var segs: [TimedSegment] = []
    var (y, m, d) = (e.year, e.month, e.day)
    var lo = e.startHour
    var remainingEnd = e.endHour // measured from THIS day's midnight; drops by 24 each day
    var first = true
    while true {
        let hi = min(remainingEnd, 24)
        let continues = remainingEnd > 24
        var seg = e; seg.year = y; seg.month = m; seg.day = d; seg.startHour = lo; seg.endHour = hi
        segs.append(TimedSegment(
            event: seg,
            clipTop: !first,
            clipBottom: continues,
            fullStart: e.startHour,
            fullEnd: e.endHour
        ))
        if !continues {
            break
        }
        (y, m, d) = nextDay(y, m, d)
        lo = 0; remainingEnd -= 24; first = false
    }
    return segs
}

/// Height-driven text scheme for an hourly event block (ported from eventTextLayout).
public struct EventText: Sendable {
    public var tiny: Bool; public var short: Bool; public var subLine: Bool; public var titleLines: Int
}

/// `hasSubline` = a secondary detail line (the anchor-tz time) wants to show. Because the timeline zooms,
/// block height is dynamic — the secondary line only appears on a tall-enough block, and when it does its
/// ~11pt is reserved so the title lines don't overlap it.
public func eventTextLayout(_ h: CGFloat, hasSubline: Bool = false) -> EventText {
    let tiny = h < 26 // ~15 min
    let short = h < 40 // ~≤30 min: hide the time
    let subLine = hasSubline && !short && !tiny && h >= 52 // room for title + time + a second line
    let lineH: CGFloat = tiny ? 11 : 14
    let avail = h - (tiny ? 2 : 10) - (short ? 0 : 13) - (subLine ? 11 : 0)
    return EventText(tiny: tiny, short: short, subLine: subLine, titleLines: max(1, Int(avail / lineH)))
}

/// "HH:MM – HH:MM" for an event's decimal-hour range (ported from fmtRange).
public func fmtHourRange(_ s: CGFloat, _ e: CGFloat) -> String {
    func hhmm(_ h: CGFloat) -> String {
        let t = Int((h * 60).rounded()); return String(
            format: "%02d:%02d",
            (t / 60) % 24,
            t % 60
        )
    }
    return "\(hhmm(s)) – \(hhmm(e))"
}

/// The whole event's range re-expressed in its ANCHOR zone, as "HH:MM – HH:MM (ABBR)" — the secondary
/// line shown on an event whose anchor differs from the current view (main) tz. `e` is a DISPLAY event
/// (main-tz wall-clock); we convert back to the anchor zone. nil when the anchor matches the view.
public func anchorRangeLabel(_ e: TimedEvent, mainTz: String) -> String? {
    guard let anchor = e.anchorTz else { return nil }
    let base = DeadlineTZ.instant(e.year, e.month, e.day, e.startHour)
    guard !DeadlineTZ.sameOffset(anchor, mainTz, at: base) else { return nil }
    let w = DeadlineTZ.convertWall(e.year, e.month, e.day, e.startHour, from: mainTz, to: anchor)
    return "\(fmtHourRange(w.hour, w.hour + (e.endHour - e.startHour))) (\(DeadlineTZ.shortLabel(anchor, at: base)))"
}

/// Pointer → focus-relative day column + fractional hour, accounting for scroll.
public func pointToSlot(_ px: CGFloat, _ py: CGFloat, _ tl: TimelineInfo) -> (dom: Int?, hourFrac: CGFloat) {
    // floor (not Int-truncation, which rounds toward zero) so leading spillover days (negative
    // focus-relative index, px < x0) map correctly instead of shifting one column right.
    let dom = (px >= Layout.labelW && tl.colW > 0) ? Int(((px - tl.x0) / tl.colW).rounded(.down)) + 1 : nil
    let hourFrac = tl.hourH > 0 ? max(0, min(24, (py - tl.tlTop + tl.scroll) / tl.hourH)) : 0
    return (dom, hourFrac)
}
