// Builds the flat list of positioned items to render for a given zoom state.
// All geometry comes from Frames.swift; this file decides WHICH items exist and how
// they're styled at each zoom level. Ported from geometry/scene.ts.

import CoreGraphics
import Foundation

private let HL_SOFT = Layout.hlSoft // coarse highlight (row / month span)
private let HL_STRONG = Layout.hlStrong // fine highlight (day / week column)

struct Clock { var year: Int; var month: Int; var day: Int; var hour: Int; var minute: Int }
private func clockOf(_ date: Date) -> Clock {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return Clock(
        year: c.year ?? 0,
        month: (c.month ?? 1) - 1,
        day: c.day ?? 1,
        hour: c.hour ?? 0,
        minute: c.minute ?? 0
    )
}

private func onScreen(_ f: Frame, _ vp: Viewport) -> Bool {
    f.bandY <= vp.h + 20 && f.bandY + 4 * f.trackH >= -20
}

/// A main-zone wall clock re-expressed in the alt zone: "13:45 (PST)", with a day marker when the
/// alt wall-clock lands on a different calendar day — "23:30 (JST) [+1 day]" — so a time near the
/// day boundary isn't mistaken for the same day. Public: shared by the now pill + cursor tag, and
/// unit-tested directly.
public func altClockText(minutes: Int, deltaHours: CGFloat, label: String?) -> String {
    let shifted = minutes + Int((deltaHours * 60).rounded())
    let dayShift = Int(floor(Double(shifted) / 1440))
    let wrapped = ((shifted % 1440) + 1440) % 1440
    var s = String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    if let label {
        s += " (\(label))"
    }
    if dayShift != 0 {
        s += " [\(dayShift > 0 ? "+" : "")\(dayShift) day]"
    }
    return s
}

/// True when `altClockText` for this wall clock would carry the "[±N day]" marker — the pills
/// widen to fit it (their rects are fixed-size, so the width is decided at scene-build time).
func altDayMarker(minutes: Int, deltaHours: CGFloat) -> Bool {
    let shifted = minutes + Int((deltaHours * 60).rounded())
    return Int(floor(Double(shifted) / 1440)) != 0
}

/// The current-time ("CURRENT TIME") label placements for this frame — the now-line still draws in
/// the Canvas, but the LABEL is rendered as a real SwiftUI glass view (see EventsOverlay). Derived
/// from the built scene so it inherits all the month/week/page-turn placement logic for free.
public struct NowLabelSpec: Sendable, Identifiable {
    public var id: String
    public var rect: CGRect
    public var text: String
    public var altText: String? // second line when the alt-tz column is on: "13:45 (PST)"
    public var pointsRight: Bool // caret side: true → label sits left of the column, points right
    public var opacity: CGFloat
}

public func nowLabelSpecs(_ g: SceneInput) -> [NowLabelSpec] {
    // With the alternative-timezone column on, the label gains a second line: the same instant
    // as an alt-tz wall clock, tagged with the zone's short label.
    let altText: String? = g.altDeltaHours.map { d in
        let c = clockOf(g.now)
        return altClockText(minutes: c.hour * 60 + c.minute, deltaHours: d, label: g.altLabel)
    }
    return buildScene(g).items.compactMap { it in
        guard it.kind == .nowLabel, it.opacity > 0.01 else { return nil }
        return NowLabelSpec(id: it.key, rect: it.rect, text: it.text ?? "", altText: altText,
                            pointsRight: it.align == .right, opacity: it.opacity)
    }
}

/// The mouse-cursor time tag, rendered as a SwiftUI glass pill (not in the Canvas) so it isn't clipped
/// at the gutter edge AND its left/right side can animate smoothly on a flip (e.g. week↔day). Mirrors
/// nowLabelSpecs: derived from the built scene's `cur-tag` item so it inherits all placement logic.
public struct CursorTagSpec: Sendable {
    public var rect: CGRect
    public var text: String
    public var altText: String? // second line when the alt-tz column is on: "13:45 (PST) [+1 day]"
    public var pointsRight: Bool // tag sits left of the column → caret points right (into the line)
    public var opacity: CGFloat
}

public func cursorTagSpec(_ g: SceneInput) -> CursorTagSpec? {
    guard let it = buildScene(g).items.first(where: { $0.key == "cur-tag" }), it.opacity > 0.01 else { return nil }
    // The cursor moment in the alt zone. The item's text is the tag's own "HH:MM" (built from the
    // hover hour), so parse it back rather than re-deriving the hover position here.
    let altText: String? = g.altDeltaHours.flatMap { d in
        let p = (it.text ?? "").split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return altClockText(minutes: h * 60 + m, deltaHours: d, label: g.altLabel)
    }
    return CursorTagSpec(rect: it.rect, text: it.text ?? "", altText: altText,
                         pointsRight: it.align == .right, opacity: it.opacity)
}

/// Single-frame memo: buildScene is called 3× per frame (drawBelow, drawAbove, nowLabelSpecs) with
/// the SAME input, and it's the heaviest per-frame function. Cache the last (input → scene) so those
/// calls collapse to one build; across frames the input differs (clock/scroll) and it rebuilds once.
/// Main-thread only (all rendering is on the main actor), hence nonisolated(unsafe).
private nonisolated(unsafe) var sceneMemo: (input: SceneInput, scene: Scene)?

public func buildScene(_ g: SceneInput) -> Scene {
    if let m = sceneMemo, m.input == g {
        return m.scene
    }
    let scene = buildSceneUncached(g)
    sceneMemo = (g, scene)
    return scene
}

private func buildSceneUncached(_ g: SceneInput) -> Scene {
    let clock = clockOf(g.now)
    var items: [Item] = []
    if g.monthAnim == nil {
        items += buildHover(g)
        items += buildToday(g, clock)
    }
    items += buildQuarterHeaders(g, clock)
    items += buildMonthBands(g)
    // The outgoing month's timeline fades as the page turns (nil anim → mul 1, untouched).
    let outMul = g.monthAnim.map { outgoingDetailReveal($0.p) } ?? 1
    items += buildDetail(g, clock, focus: g.focus, detailMul: outMul)
    if let anim = g.monthAnim {
        items += buildToday(g, clock, mul: outMul) // outgoing today column / now-line: slides + fades out
        let to = g.focus + anim.dir
        if to >= 0 && to <= 11 {
            items += buildDetail(g, clock, focus: to, detailMul: incomingDetailReveal(anim.p), keyTag: "~in")
            items +=
                buildToday(g, clock, mul: incomingDetailReveal(anim.p), fo: to,
                           keyTag: "~in") // incoming: slides + fades in
        }
    }
    return Scene(items: items)
}

/// ── Today markers + live current-time line ───────────────────────────────────────
private func buildToday(_ g: SceneInput, _ clock: Clock, mul: CGFloat = 1, fo: Int? = nil,
                        keyTag: String = "") -> [Item] {
    var items: [Item] = []
    let present = clock.year == g.year
    let tMonth = clock.month, tDom = clock.day
    let nowFrac = CGFloat(clock.hour) + CGFloat(clock.minute) / 60
    let timeStr = String(format: "%02d:%02d", clock.hour, clock.minute)

    // Year-aware focus-relative index of today (nil unless today is the focus month or a neighbor,
    // incl. across the Dec↔Jan year boundary) — so the boundary-week highlight tracks a neighbor-year
    // "today" too, not only same-year days.
    let relDom = relDomOf(g.year, g.focus, clock.year, tMonth, tDom)

    func nowLabel(_ key: String, _ x: CGFloat, _ colW: CGFloat, _ lineY: CGFloat, _ active: Bool,
                  gate: CGFloat = 1) -> Item {
        // With the alt-tz column on the pill grows a second time line (see nowLabelSpecs), and
        // widens further when that line carries the "[±1 day]" boundary marker.
        let alt = g.altDeltaHours != nil
        let marker = g.altDeltaHours.map { altDayMarker(minutes: clock.hour * 60 + clock.minute, deltaHours: $0) }
            ?? false
        let W: CGFloat = alt ? (marker ? 148 : 96) : 88, GAP: CGFloat = 10,
            H: CGFloat = alt ? 47 : 36 // match the deadline label pill's size
        let onLeft = g.z > 2 || x + colW / 2 >= (Layout.labelW + g.vp.w) / 2
        return Item(key: key, kind: .nowLabel, x: onLeft ? x - GAP - W : x + colW + GAP, y: lineY - H / 2, w: W, h: H,
                    opacity: active ? mul * gate : 0, text: timeStr,
                    align: onLeft ? .right : .left, instant: g.z > 2, z: g.z > 2 ? 16 : 9)
    }

    // Year: today's day column in its month band
    do {
        let f = frameFor(tMonth, g)
        let on = present && g.z < 0.5 && onScreen(f, g.vp)
        // Faint wash over the whole current-month row (gutter + band).
        let dimM = daysInMonth(g.year, tMonth)
        items.append(Item(
            key: "tm-y",
            kind: .todayMonth,
            x: f.x0,
            y: f.bandY,
            w: CGFloat(dimM) * f.dayW,
            h: 4 * f.trackH,
            opacity: on ? mul : 0,
            z: 2
        ))
        items.append(Item(
            key: "tm-yg",
            kind: .todayMonth,
            x: -Layout.padLeft,
            y: f.bandY,
            w: Layout.labelW + Layout.padLeft,
            h: 4 * f.trackH,
            opacity: on ? mul : 0,
            z: 2,
            gutter: true
        ))
        let tx = f.x0 + (CGFloat(tDom) - 1) * f.dayW
        items.append(Item(
            key: "td-y",
            kind: .today,
            x: tx,
            y: f.bandY,
            w: f.dayW,
            h: 4 * f.trackH,
            opacity: on ? mul : 0,
            z: 3
        ))
        let tagW: CGFloat = 54
        items.append(Item(
            key: "td-tag",
            kind: .todayTag,
            x: tx + f.dayW / 2 - tagW / 2,
            y: f.bandY + 4 * f.trackH + 3,
            w: tagW,
            h: 11,
            opacity: on ? mul : 0,
            text: "TODAY",
            fontSize: 8,
            align: .center,
            z: 9
        ))
    }
    // Month: today's column (band + timeline) + now line
    do {
        // `fo` overrides the month so a page-turn can draw the incoming month's today column /
        // now-line (sliding in) as well as the outgoing month's (sliding out).
        let mo = fo ?? g.focus
        let active = present && g.z >= 0.5 && g.z < 1.5 && mo == tMonth
        let f = frameFor(mo, g, anim: g.monthAnim) // slide the now-line with a month page-turn
        let colW = f.dayW
        let tlTop = f.bandY + 4 * f.trackH + 18
        let tlBottom = Layout.tlBottomY(g.vp.h)
        let detail = g.z >= Layout.detailZ
        let x = f.x0 + (CGFloat(tDom) - 1) * colW
        items.append(Item(
            key: "td-m",
            kind: .today,
            x: x,
            y: f.bandY,
            w: colW,
            h: (detail ? tlBottom : f.bandY + 4 * f.trackH) - f.bandY,
            opacity: active ? mul : 0,
            z: 3
        ))
        let m = hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH)
        let lineY = tlTop + nowFrac * m.hourH - m.scroll
        let lineOn = active && detail && m.hourH > 0 && lineY >= tlTop && lineY <= tlBottom
        items.append(Item(key: "now-m", kind: .now, x: x, y: lineY, w: colW, h: 2, opacity: lineOn ? mul : 0, z: 6))
        items.append(nowLabel("nl-m", x, colW, lineY, lineOn))
    }
    // Week: today's column when in the visible 7-day window
    do {
        // Use the window's FRACTIONAL left edge (matches weekFrame's startDOM) so the highlight
        // tracks live while scrolling, instead of snapping in only once `week` lands on an integer.
        let winStart = 1 - CGFloat(firstDOW(g.year, g.focus)) + g.week * 7
        let inWeek = relDom.map { CGFloat($0) - winStart > -1 && CGFloat($0) - winStart < 7 } ?? false
        // `relDom` is already year-aware (non-nil only if today is in the visible window, incl. the
        // neighbor year at a boundary), so `inWeek` alone gates — no same-year `present` requirement.
        let active = g.z >= 1.5 && inWeek
        let f = frameFor(g.focus, g)
        let colW = f.dayW
        let tlTop = f.bandY + 4 * f.trackH + 18
        let tlBottom = Layout.tlBottomY(g.vp.h)
        let x = f.x0 + (CGFloat(relDom ?? 1) - 1) * colW
        // The today-column red wash fades OUT as the week view opens (z 1.5→2) and stays gone in week
        // and day view — today there is marked by the now-line + the highlighted date/weekday labels.
        let tintMul = 1 - clamp((g.z - 1.5) / 0.5, 0, 1)
        items.append(Item(
            key: "td-w",
            kind: .today,
            x: x,
            y: f.bandY,
            w: colW,
            h: tlBottom - f.bandY,
            opacity: active ? mul * tintMul : 0,
            z: 3
        ))
        let m = hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH)
        let lineY = tlTop + nowFrac * m.hourH - m.scroll
        let lineOn = active && m.hourH > 0 && lineY >= tlTop && lineY <= tlBottom
        let dgate = dailyFade(relDom ?? -999, g)
        items.append(Item(
            key: "now-w",
            kind: .now,
            x: x,
            y: lineY,
            w: colW,
            h: 2,
            opacity: (lineOn ? mul : 0) * dgate,
            instant: g.z > 2,
            z: g.z > 2 ? 16 : 6
        ))
        items.append(nowLabel("nl-w", x, colW, lineY, lineOn, gate: dgate))
    }

    if !keyTag.isEmpty {
        items = items.map { var it = $0; it.key += keyTag; return it }
    }
    return items
}

/// ── Hierarchical hover highlight ─────────────────────────────────────────────────
private func buildHover(_ g: SceneInput) -> [Item] {
    var items: [Item] = []
    let h = g.hover

    // Year: hovered month band (soft) + day column (strong) + name strip
    do {
        let m = h.month ?? g.focus
        let f = frameFor(m, g)
        let dim = daysInMonth(g.year, m)
        let bandH = 4 * f.trackH
        let monthOn = g.z < 0.5 && h.month != nil && onScreen(f, g.vp)
        items.append(Item(
            key: "hl-ym",
            kind: .hl,
            x: f.x0,
            y: f.bandY,
            w: CGFloat(dim) * f.dayW,
            h: bandH,
            opacity: monthOn ? HL_SOFT : 0,
            z: 3
        ))
        // Extend the gutter hover left over the padding so the row highlight reaches
        // the window's left border (like a native list-row selection).
        items.append(Item(
            key: "hl-yg",
            kind: .hl,
            x: -Layout.padLeft,
            y: f.bandY,
            w: Layout.labelW + Layout.padLeft,
            h: bandH,
            opacity: monthOn ? HL_SOFT : 0,
            z: 6,
            gutter: true
        ))
        let dcol = h.dom ?? 1
        let dayOn = monthOn && h.dom != nil && h.dom! >= 1 && h.dom! <= dim
        items.append(Item(
            key: "hl-yd",
            kind: .hl,
            x: f.x0 + (CGFloat(dcol) - 1) * f.dayW,
            y: f.bandY,
            w: f.dayW,
            h: bandH,
            opacity: dayOn ? HL_STRONG : 0,
            z: 3
        ))
        // NOTE: the "Thu"/"Fri" weekday marker above the hovered day is rendered as a
        // Liquid Glass capsule in EventsOverlay (Canvas can't draw glass) — see
        // weekdayMarker(). Its visibility mirrors `dayOn` here.
    }
    // Month: crosshair — hovered track lane (row) + hovered day column (band + timeline).
    do {
        let active = g.z >= 0.5 && g.z < 1.5
        let f = frameFor(g.focus, g)
        let dim = daysInMonth(g.year, g.focus)
        let colW = f.dayW
        let bandTop = f.bandY
        let bandBottom = f.bandY + 4 * f.trackH
        let colBottom = g.z >= Layout.detailZ ? Layout
            .tlBottomY(g.vp.h) : bandBottom // day column runs through the timeline
        // Track lane row (hovering a track name OR a band cell) — gutter + content.
        if active, let tr = h.track {
            let ly = bandTop + CGFloat(tr) * f.trackH
            items.append(Item(
                key: "hl-mtg",
                kind: .hl,
                x: -Layout.padLeft,
                y: ly,
                w: Layout.labelW + Layout.padLeft,
                h: f.trackH,
                opacity: HL_SOFT,
                z: 6,
                gutter: true
            ))
            items.append(Item(
                key: "hl-mtd",
                kind: .hl,
                x: f.x0,
                y: ly,
                w: CGFloat(dim) * colW,
                h: f.trackH,
                opacity: HL_SOFT,
                z: 3
            ))
        }
        // Day column (hovering a band cell OR the timeline) — band cells + daily timeline.
        if active, let d = h.dom, d >= 1, d <= dim {
            items.append(Item(
                key: "hl-mday",
                kind: .hl,
                x: f.x0 + (CGFloat(d) - 1) * colW,
                y: bandTop,
                w: colW,
                h: colBottom - bandTop,
                opacity: HL_SOFT,
                z: 3
            ))
        }
    }
    // Week: hovered day column (soft) + hour cell (strong) + cursor line/tag
    do {
        let active = g.z >= 1.5
        let f = frameFor(g.focus, g)
        let colW = f.dayW
        let tlTop = f.bandY + 4 * f.trackH + 18
        let tlBottom = Layout.tlBottomY(g.vp.h)
        let m = hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH)
        let dcol = h.dom ?? 1
        let x = f.x0 + (CGFloat(dcol) - 1) * colW
        items.append(Item(
            key: "hl-wd",
            kind: .hl,
            x: x,
            y: f.bandY,
            w: colW,
            h: tlBottom - f.bandY,
            opacity: active && h.dom != nil ? HL_SOFT * (1 - clamp(g.z - 2, 0, 1)) : 0,
            z: 3
        ))
        let rawHy = h.hour != nil ? tlTop + CGFloat(h.hour!) * m.hourH - m.scroll : tlTop
        let cellTop = max(tlTop, rawHy), cellBot = min(tlBottom, rawHy + m.hourH)
        let hourOn = active && h.dom != nil && h.hour != nil && m.hourH > 0 && cellBot > cellTop
        items.append(Item(
            key: "hl-wh",
            kind: .hl,
            x: x,
            y: cellTop,
            w: colW,
            h: max(0, cellBot - cellTop),
            opacity: hourOn ? HL_STRONG : 0,
            z: 3
        ))

        let hf = h.hourFrac ?? 0
        let cy = tlTop + hf * m.hourH - m.scroll
        let curOn = active && h.dom != nil && h.hourFrac != nil && m.hourH > 0 && cy >= tlTop && cy <= tlBottom
        // Over a deadline: hide the whole cursor. Over a timed event: keep the end dots + tag but
        // drop the connecting line (hollow) so it doesn't slice across the event block.
        let lineOn = curOn && !h.overDeadline
        let tagOn = curOn && !h.overDeadline
        items.append(Item(
            key: "cur-line",
            kind: .cursor,
            x: x,
            y: cy,
            w: colW,
            h: 2,
            opacity: lineOn ? 1 : 0,
            z: g.z > 2 ? 16 : 7,
            hollow: h.overTimed
        ))
        let total = Int((hf * 60).rounded())
        let tStr = String(format: "%02d:%02d", (total / 60) % 24, total % 60)
        let tagLeft = g.z > 2 || x + colW / 2 >= (Layout.labelW + g.vp.w) / 2
        // Alt-tz column on → the tag grows a second line (the cursor moment in the alt zone, see
        // cursorTagSpec), and widens further when that line carries the "[±1 day]" marker.
        let alt = g.altDeltaHours != nil
        let marker = g.altDeltaHours.map { altDayMarker(minutes: total % 1440, deltaHours: $0) } ?? false
        // Absolute widths with real headroom: 44 was exactly the metric width of "19:35" at
        // 11pt semibold + padding, so the pill could ellipsize ("19:…"). The view also renders
        // its text un-truncatable (fixedSize) as belt-and-braces.
        let TW: CGFloat = alt ? (marker ? 160 : 108) : 58, GAP: CGFloat = 10, TH: CGFloat = alt ? 33 : 20
        // Nudge the tag down ~2px so it reads as hanging just under the cursor moment, and align its
        // side to the dot it points at (a caret is drawn on the near edge — see drawCursorTag).
        items.append(Item(
            key: "cur-tag",
            kind: .timeTag,
            x: tagLeft ? x - GAP - TW : x + colW + GAP,
            y: cy - TH / 2 + 1,
            w: TW,
            h: TH,
            opacity: tagOn ? 1 : 0,
            text: tStr,
            align: tagLeft ? .right : .left,
            z: g.z > 2 ? 16 : 9
        ))
    }
    return items
}

/// ── Quarter day-number headers (year view only) ──────────────────────────────────
private func buildQuarterHeaders(_ g: SceneInput, _ clock: Clock) -> [Item] {
    let yearVis = clamp(1 - g.z / 0.4, 0, 1)
    if yearVis <= 0.02 {
        return []
    }
    var items: [Item] = []
    for q in 0 ..< 4 {
        // The quarter frame carries the (possibly scrolled) x0 and min-width dayW, so the
        // day-number header shifts with its quarter's horizontal scroll like the grid does.
        let f = frameFor(q * 3, g)
        let dayW = f.dayW
        let hy = f.bandY - Layout.qHeaderH
        if hy < -Layout.qHeaderH || hy > g.vp.h {
            continue
        }
        let todayQuarter = g.year == clock.year && q == clock.month / 3
        for d in 1 ... 31 {
            let isToday = todayQuarter && d == clock.day
            items.append(Item(
                key: "qh-\(q)-\(d)",
                kind: .dayLabel,
                x: f.x0 + CGFloat(d - 1) * dayW,
                y: hy + 5,
                w: dayW,
                h: 14,
                // Ordinary day numbers are muted; today's accent capsule draws at FULL opacity so
                // it matches the month view's date-row pill (same drawDayLabel + theme.nowLine).
                opacity: yearVis * (isToday ? 1 : 0.7),
                text: String(d),
                fontSize: 10,
                align: .center,
                today: isToday,
                z: 4
            ))
        }
        let topY = hy + Layout.qHeaderH - 1
        // Quarter top border — emphasized (full opacity + 1.5× width) vs the internal
        // month dividers (0.6 opacity, 1× width).
        items.append(Item(
            key: "qhsepg-\(q)",
            kind: .gridline,
            x: 0,
            y: topY,
            w: Layout.isCompactGutter ? Layout.labelW : Layout.labelW - Layout.rightPad,
            h: 1,
            opacity: yearVis * Layout.bandEdgeOpacity,
            z: 11,
            gutter: true,
            lineW: Layout.bandEdgeWidth
        ))
        items.append(Item(
            key: "qhsepd-\(q)",
            kind: .gridline,
            x: f.x0,
            y: topY,
            w: 31 * dayW,
            h: 1,
            opacity: yearVis * Layout.bandEdgeOpacity,
            z: 11,
            lineW: Layout.bandEdgeWidth
        ))
    }
    return items
}

/// ── The 12 month bands: name, 4 lanes, end-of-month dim, divider ─────────────────
private func buildMonthBands(_ g: SceneInput) -> [Item] {
    var items: [Item] = []
    let dimFade = 1 - clamp(g.z - 1, 0, 1)
    let detailReveal = clamp((g.z - Layout.detailZ) / Layout.detailRamp, 0, 1)
    for m in 0 ..< 12 {
        let f = frameFor(m, g, anim: g.monthAnim)
        if f.opacity < 0.02 || !onScreen(f, g.vp) {
            continue
        }
        let dim = daysInMonth(g.year, m)
        let fullW = 31 * f.dayW
        // Week view: the visible 7-day window can include spillover columns beyond the month's own
        // 31 cells. Extend the lane grid (dotted verticals + separators) + bottom border to span the
        // whole content area so spillover days get the same grid as focus days (day-aligned).
        let rowX: CGFloat, rowW: CGFloat, rowCols: Int
        if g.z >= 1.5 && g.z <= 2.5 {
            let iLeft = Int(((Layout.labelW - f.x0) / f.dayW).rounded(.down))
            let iRight = Int(((g.vp.w - f.x0) / f.dayW).rounded(.up))
            rowCols = max(1, iRight - iLeft)
            rowX = f.x0 + CGFloat(iLeft) * f.dayW
            rowW = CGFloat(rowCols) * f.dayW
        } else {
            rowX = f.x0; rowW = fullW; rowCols = g.z > 2.5 ? 1 : 31
        }

        items.append(Item(
            key: "ml-\(m)",
            kind: .monthLabel,
            x: 0,
            y: f.bandY,
            w: Layout.mnameW,
            h: f.trackH * 4,
            opacity: f.opacity,
            text: MONTH_NAMES[m],
            fontSize: 13,
            align: .center,
            z: 8,
            gutter: true
        ))

        let isFocusBand = m == g.focus || (g.monthAnim != nil && m == g.focus + g.monthAnim!.dir)
        if detailReveal > 0.02 && isFocusBand { // emphasized top border for the focused month band
            let top = f.opacity * detailReveal * Layout.bandEdgeOpacity
            items.append(Item(
                key: "ftopg-\(m)",
                kind: .gridline,
                x: 0,
                y: f.bandY - 1,
                w: Layout.isCompactGutter ? Layout.labelW : Layout.labelW - Layout.rightPad,
                h: 1,
                opacity: top,
                z: 11,
                gutter: true,
                lineW: Layout.bandEdgeWidth
            ))
            items.append(Item(
                key: "ftopd-\(m)",
                kind: .gridline,
                x: Layout.labelW,
                y: f.bandY - 1,
                w: g.vp.w - Layout.labelW,
                h: 1,
                opacity: top,
                z: 11,
                lineW: Layout.bandEdgeWidth
            ))
        }

        for t in 0 ..< 4 {
            items.append(Item(
                key: "row-\(m)-\(t)",
                kind: .row,
                x: rowX,
                y: f.bandY + CGFloat(t) * f.trackH,
                w: rowW,
                h: f.trackH,
                opacity: f.opacity,
                color: TRACKS[t].color,
                cols: rowCols,
                inner: t > 0,
                z: 1
            ))
        }
        if dim < 31 && dimFade > 0.02 {
            items.append(Item(
                key: "dim-\(m)",
                kind: .dim,
                x: f.x0 + CGFloat(dim) * f.dayW,
                y: f.bandY,
                w: CGFloat(31 - dim) * f.dayW,
                h: 4 * f.trackH,
                opacity: f.opacity * dimFade,
                z: 3
            ))
        }
        // Bottom border emphasized for a quarter's bottom month (year) OR the focused band
        // (month) — same shared edge style, blended in as we zoom into the focus.
        let quarterBottom = m % 3 == 2
        let edge = max(quarterBottom ? 1 : 0, isFocusBand ? detailReveal : 0)
        items.append(Item(key: "msep-\(m)", kind: .gridline, x: rowX, y: f.bandY + 4 * f.trackH - 1, w: rowW, h: 1,
                          opacity: f.opacity * lerp(Layout.bandInnerOpacity, Layout.bandEdgeOpacity, edge), z: 1,
                          lineW: lerp(Layout.bandInnerWidth, Layout.bandEdgeWidth, edge)))
        // Compact gutter (phone): the month-name cell gets its own full-width bottom rule
        // in the GUTTER region (content rules clip at labelW), so every name reads as a
        // bounded cell — its top rule is the previous month's bottom / the quarter header's.
        if Layout.isCompactGutter {
            items.append(Item(key: "msepg-\(m)", kind: .gridline, x: 0, y: f.bandY + 4 * f.trackH - 1,
                              w: Layout.labelW, h: 1,
                              opacity: f.opacity * lerp(Layout.bandInnerOpacity, Layout.bandEdgeOpacity, edge),
                              z: 11, gutter: true,
                              lineW: lerp(Layout.bandInnerWidth, Layout.bandEdgeWidth, edge)))
        }
    }
    return items
}

/// Short 12-hour label for the compact (phone) timeline gutter: 12AM, 9AM, 12PM, 4PM…
private func fmt12Hour(_ hr: Int) -> String {
    let h = ((hr % 24) + 24) % 24
    if h == 0 {
        return "12AM"
    }
    if h == 12 {
        return "12PM"
    }
    return h < 12 ? "\(h)AM" : "\(h - 12)PM"
}

/// ── Focused month's headers + timeline + week boundaries + spillover ─────────────
private func buildDetail(_ g: SceneInput, _ clock: Clock, focus: Int, detailMul: CGFloat = 1,
                         keyTag: String = "") -> [Item] {
    let reveal = (g.z < Layout.detailZ ? 0 : clamp((g.z - Layout.detailZ) / Layout.detailRamp, 0, 1)) * detailMul
    if reveal <= 0.02 {
        return []
    }
    var items: [Item] = []

    // build with `focus` (may be the incoming month during a page-turn). The FRAME keeps the
    // original pivot (g.focus) so a month page-turn slides this detail in/out via monthSwipeFrame.
    var gf = g; gf.focus = focus
    let f = frameFor(focus, g, anim: g.monthAnim)
    let dim = daysInMonth(g.year, focus)
    let colW = f.dayW
    let bandBottom = f.bandY + 4 * f.trackH
    let wide = colW > 60
    let dailyOut = 1 - clamp(g.z - 2, 0, 1)
    let weekZoom = clamp(g.z - 1, 0, 1)

    let tlTop = bandBottom + 18
    let tlBottom = Layout.tlBottomY(g.vp.h)
    let hasTL = tlBottom > tlTop
    let hm = hasTL ? hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH) : HourMetrics(
        viewH: 0,
        hourH: 0,
        maxScroll: 0,
        zoomable: false,
        scroll: 0
    )
    let hourH = hm.hourH, scroll = hm.scroll

    let altOn = g.altDeltaHours != nil
    if hasTL {
        // Compact gutter (phone): the tall month timeline fits hourly gridlines and 2-hour
        // labels; the labels use the short 12-hour form ("9AM") RIGHT-ALIGNED inside the
        // narrow gutter (the desktop's "HH:00" at labelW-46 would hang off the screen edge).
        let compact = Layout.isCompactGutter
        var hr = 0
        let step = wide ? 1 : (compact && hourH >= 14 ? 1 : 6)
        let labelEvery = wide ? 2 : (compact && hourH >= 14 ? 2 : 6)
        while hr <= 24 {
            let y = tlTop + CGFloat(hr) * hourH - scroll
            if y < tlTop - 0.5 || y > tlBottom + 0.5 {
                hr += step; continue
            }
            let even = hr % 2 == 0
            items.append(Item(
                key: "hl-\(hr)",
                kind: .gridline,
                x: Layout.labelW,
                y: y,
                w: g.vp.w - Layout.labelW,
                h: 1,
                opacity: reveal * (even ? 0.22 : 0.12),
                lineStyle: even ? .dashed : .dotted,
                z: 0
            ))
            if hr % labelEvery == 0 {
                items.append(Item(
                    key: "ht-\(hr)",
                    kind: .dayLabel,
                    x: compact ? 2 : Layout.labelW - 46,
                    y: y - 7,
                    w: compact ? Layout.labelW - 8 : 42,
                    h: 14,
                    opacity: reveal * 0.7,
                    text: compact ? fmt12Hour(hr) : String(format: "%02d:00", hr),
                    fontSize: 9,
                    align: compact ? .right : .center,
                    z: 9,
                    gutter: true
                ))
                if altOn {
                    let t = (((Int(((CGFloat(hr) + g.altDeltaHours!) * 60).rounded()) % 1440) + 1440) % 1440)
                    let txt = String(format: "%02d:%02d", t / 60, t % 60)
                    items.append(Item(
                        key: "hta-\(hr)",
                        kind: .dayLabel,
                        x: Layout.labelW - 92,
                        y: y - 7,
                        w: 42,
                        h: 14,
                        opacity: reveal * 0.7,
                        text: txt,
                        fontSize: 9,
                        align: .center,
                        z: 9,
                        gutter: true
                    ))
                }
            }
            hr += step
        }
        if altOn {
            items.append(Item(
                key: "tzaxis",
                kind: .gridline,
                x: Layout.labelW - 50,
                y: tlTop,
                w: 1,
                h: tlBottom - tlTop,
                opacity: reveal * 0.35,
                z: 9,
                gutter: true
            ))
            if let al = g.altLabel {
                items.append(Item(
                    key: "tzhdr",
                    kind: .dayLabel,
                    x: Layout.labelW - 92,
                    y: tlTop - 16,
                    w: 42,
                    h: 12,
                    opacity: reveal * 0.85,
                    text: al,
                    fontSize: 9,
                    align: .center,
                    z: 9,
                    gutter: true
                ))
            }
        }
    }

    func pushDay(_ dom: Int, _ opIn: CGFloat) {
        let op = opIn * dailyFade(dom, gf)
        if op <= 0.002 {
            return
        }
        guard let r = resolveDate(g.year, focus, dom) else { return }
        let x = f.x0 + (CGFloat(dom) - 1) * colW
        if x + colW < -40 || x > g.vp.w + 40 {
            return
        }
        let dow = dayOfWeek(r.year, r.month, r.day)
        if (dow == 0 || dow == 6) && op * dailyOut > 0.002 {
            let bottom = hasTL ? tlBottom : bandBottom
            items.append(Item(
                key: "wke-\(dom)",
                kind: .weekend,
                x: x,
                y: f.bandY,
                w: colW,
                h: bottom - f.bandY,
                opacity: op * dailyOut,
                z: 2
            ))
        }
        let nwOp = op * clamp(g.z - 2, 0, 1)
        if hasTL && nwOp > 0.002 {
            for (h0, h1) in [(0, 6), (18, 24)] {
                let y0 = max(tlTop, tlTop + CGFloat(h0) * hourH - scroll)
                let y1 = min(tlBottom, tlTop + CGFloat(h1) * hourH - scroll)
                if y1 > y0 + 0.5 {
                    items.append(Item(
                        key: "nwh-\(dom)-\(h0)",
                        kind: .weekend,
                        x: x,
                        y: y0,
                        w: colW,
                        h: y1 - y0,
                        opacity: nwOp,
                        z: 2
                    ))
                }
            }
        }
        let dateText = (r.year == g.year && r.month == focus) ? String(r.day) : "\(MONTH_NAMES[r.month]) \(r.day)"
        let isToday = r.year == clock.year && r.month == clock.month && r.day == clock.day
        items.append(Item(
            key: "date-\(dom)",
            kind: .dayLabel,
            x: x,
            y: f.bandY - 20,
            w: colW,
            h: 16,
            opacity: op,
            text: dateText,
            fontSize: wide ? 13 : 10,
            align: .center,
            today: isToday,
            z: 4
        ))
        items.append(Item(
            key: "wd-\(dom)",
            kind: .dayLabel,
            x: x,
            y: bandBottom + 2,
            w: colW,
            h: 14,
            opacity: op * 0.9,
            text: wide ? WD3[dow] : WD[dow],
            fontSize: wide ? 11 : 9,
            align: .center,
            today: isToday,
            z: 4
        ))
        if !hasTL {
            return
        }
        let isWeekStart = ((((firstDOW(g.year, focus) + dom - 1) % 7) + 7) % 7) == 0
        if !isWeekStart {
            items.append(Item(
                key: "tdv-\(dom)",
                kind: .gridline,
                x: x,
                y: tlTop,
                w: 1,
                h: tlBottom - tlTop,
                opacity: op * 0.4 * dailyOut,
                lineStyle: .dotted,
                z: 0
            ))
        }
    }

    for d in 1 ... dim {
        pushDay(d, reveal)
    }

    let bottom = hasTL ? tlBottom : bandBottom
    for w in 0 ... weeksInMonth(g.year, focus) {
        let x = f.x0 + (CGFloat(weekStartDOM(g.year, focus, w)) - 1) * colW
        if x < Layout.labelW - 2 || x > g.vp.w + 2 {
            continue
        }
        items.append(Item(
            key: "wkb-\(w)",
            kind: .gridline,
            x: x - 1,
            y: f.bandY,
            w: 1,
            h: bottom - f.bandY,
            opacity: reveal * 0.4 * dailyOut,
            lineStyle: .dashed,
            z: 1
        ))
    }

    if weekZoom > 0.01 {
        let lead = weekStartDOM(g.year, focus, 0)
        let tail = weekStartDOM(g.year, focus, weeksInMonth(g.year, focus) - 1) + 6
        if lead <= 0 {
            for dom in lead ... 0 {
                pushDay(dom, weekZoom * 0.5)
            }
        }
        if tail >= dim + 1 {
            for dom in (dim + 1) ... tail {
                pushDay(dom, weekZoom * 0.5)
            }
        }
        for bx in [1, dim + 1] {
            let x = f.x0 + CGFloat(bx - 1) * colW
            if x < Layout.labelW || x > g.vp.w + 2 {
                continue
            }
            items.append(Item(
                key: "mb-\(bx)-b",
                kind: .gridline,
                x: x - 0.5,
                y: f.bandY,
                w: 1,
                h: bandBottom - f.bandY,
                opacity: weekZoom * 0.7 * dailyOut,
                z: 5
            ))
            if hasTL {
                items.append(Item(
                    key: "mb-\(bx)-t",
                    kind: .gridline,
                    x: x - 0.5,
                    y: tlTop,
                    w: 1,
                    h: tlBottom - tlTop,
                    opacity: weekZoom * 0.7 * dailyOut,
                    z: 5
                ))
            }
        }
    }

    if !keyTag.isEmpty {
        items = items.map { var it = $0; it.key += keyTag; return it }
    }
    return items
}
