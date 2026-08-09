// Cursor → calendar-element hit-tests, per zoom phase. Ported from geometry/hittest.ts.
// All take the SceneInput `g` so they read the same live geometry the scene renders.

import CoreGraphics

private let ADD_EDGE_THRESHOLD: CGFloat = 26

/// Year: which month's NAME (left gutter zone) is under the cursor.
public func monthNameAtPoint(_ px: CGFloat, _ py: CGFloat, _ g: SceneInput) -> Int? {
    if px < 0 || px > Layout.mnameW {
        return nil
    }
    for m in 0 ..< 12 {
        let f = yearFrame(m, g.vp, g.scrollY, qx: g.qx(m))
        if py >= f.bandY && py <= f.bandY + 4 * f.trackH {
            return m
        }
    }
    return nil
}

/// Year: which month is under the cursor (anywhere in its band).
public func monthAtPoint(_ px: CGFloat, _ py: CGFloat, _ g: SceneInput) -> Int? {
    for m in 0 ..< 12 {
        let f = yearFrame(m, g.vp, g.scrollY, qx: g.qx(m))
        let dim = daysInMonth(g.year, m)
        if py >= f.bandY && py <= f.bandY + 4 * f.trackH && px >= f.x0 && px <= f.x0 + CGFloat(dim) * f
            .dayW {
            return m
        }
    }
    return nil
}

/// Month: which (Sunday-aligned) week of the focused month is under the cursor.
public func weekAtPointInMonth(_ px: CGFloat, _ g: SceneInput) -> Int? {
    let geo = focusGeom(g.vp, mx: g.monthQX, pin: g.dashPin, monthFrac: g.dashMonthFrac)
    let dim = daysInMonth(g.year, g.focus)
    if px < geo.x0 || px > geo.x0 + CGFloat(dim) * geo.dayW {
        return nil
    }
    let d = Int((px - geo.x0) / geo.dayW) + 1
    let w = (firstDOW(g.year, g.focus) + d - 1) / 7
    return min(max(w, 0), weeksInMonth(g.year, g.focus) - 1)
}

/// Year (hover): which month's full band ROW is under the cursor (incl. left gutter).
public func monthRowAtPoint(_ px: CGFloat, _ py: CGFloat, _ g: SceneInput) -> Int? {
    if px < 0 {
        return nil
    }
    for m in 0 ..< 12 {
        let f = yearFrame(m, g.vp, g.scrollY, qx: g.qx(m))
        let dim = daysInMonth(g.year, m)
        if py >= f.bandY && py <= f.bandY + 4 * f.trackH && px <= f.x0 + CGFloat(dim) * f.dayW {
            return m
        }
    }
    return nil
}

/// Year (hover): day-of-month under the cursor within month m's band.
public func domInMonthBand(_ px: CGFloat, _ m: Int, _ g: SceneInput) -> Int? {
    let f = yearFrame(m, g.vp, g.scrollY, qx: g.qx(m))
    let dim = daysInMonth(g.year, m)
    if px < f.x0 || px > f.x0 + CGFloat(dim) * f.dayW {
        return nil
    }
    return min(max(Int((px - f.x0) / f.dayW) + 1, 1), dim)
}

/// Month (hover): day-of-month under the cursor in the focused month.
public func domInFocus(_ px: CGFloat, _ g: SceneInput) -> Int? {
    let geo = focusGeom(g.vp, mx: g.monthQX, pin: g.dashPin, monthFrac: g.dashMonthFrac)
    let dim = daysInMonth(g.year, g.focus)
    if px < geo.x0 || px > geo.x0 + CGFloat(dim) * geo.dayW {
        return nil
    }
    return min(max(Int((px - geo.x0) / geo.dayW) + 1, 1), dim)
}

public struct WeekCell: Sendable {
    public var dom: Int?; public var hour: Int?; public var hourFrac: CGFloat?; public var nearLeft: Bool
}

/// Week (hover): day column + hour row under the cursor. Mirrors the scene timeline geometry.
public func cellInWeek(_ px: CGFloat, _ py: CGFloat, _ g: SceneInput) -> WeekCell {
    let tl = timelineInfo(g)
    let (dom, hourFrac) = pointToSlot(px, py, tl)
    let inTL = tl.hourH > 0 && py >= tl.tlTop && py <= tl.tlBottom
    let edgePx = dom != nil ? px - (tl.x0 + (CGFloat(dom!) - 1) * tl.colW) : .greatestFiniteMagnitude
    return WeekCell(
        dom: dom,
        hour: inTL ? min(23, max(0, Int(hourFrac))) : nil,
        hourFrac: inTL ? (hourFrac * 60).rounded() / 60 : nil,
        nearLeft: inTL && edgePx >= 0 && edgePx < ADD_EDGE_THRESHOLD
    )
}

/// Week: which day column is under the cursor (may be a spillover day, incl. across the year edge).
public func dayAtPointInWeek(_ px: CGFloat, _ g: SceneInput) -> (year: Int, month: Int, day: Int, week: Int)? {
    if px < Layout.labelW {
        return nil
    }
    let f = frameFor(g.focus, g)
    if f.dayW <= 0 {
        return nil
    }
    let dom = Int(((px - f.x0) / f.dayW).rounded(.down)) + 1 // floor → leading spillover days map right
    guard let r = resolveDate(g.year, g.focus, dom) else { return nil }
    return (r.year, r.month, r.day, weekOfDate(r.year, r.month, r.day))
}
