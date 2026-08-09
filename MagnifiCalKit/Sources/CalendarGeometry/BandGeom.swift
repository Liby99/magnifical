// Screen geometry for all-day (band) events and deadlines. Ported from geometry/bandGeom.ts
// and the deadline placement in DeadlinesLayer (xOf(day) × yOf(hour)).

import CoreGraphics
import CoreText
import Foundation

/// ── All-day band events ──────────────────────────────────────────────────────────
public struct BandEvent: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var year: Int
    public var month: Int // 0–11
    public var track: Int // 0–3 lane
    public var startDay: Int // 1..daysInMonth
    public var endDay: Int // inclusive, >= startDay
    public var title: String
    public var color: String
    public init(
        id: String,
        year: Int,
        month: Int,
        track: Int,
        startDay: Int,
        endDay: Int,
        title: String,
        color: String
    ) {
        self.id = id; self.year = year; self.month = month; self.track = track
        self.startDay = startDay; self.endDay = endDay; self.title = title; self.color = color
    }
}

public struct BandRect: Sendable {
    public var x: CGFloat; public var y: CGFloat; public var w: CGFloat; public var h: CGFloat
    public var clipStart: Bool; public var clipEnd: Bool
}

private func bandOnScreen(_ bandY: CGFloat, _ trackH: CGFloat, _ vp: Viewport) -> Bool {
    bandY <= vp.h + 10 && bandY + 4 * trackH >= -10
}

public func bandEventRect(_ ev: BandEvent, _ g: SceneInput, anim: PageAnim? = nil) -> BandRect? {
    // Week/day view shows ONE focus window with spillover days from the neighbor months. Position all
    // bands relative to the focus week frame, mapping the band's days to focus-relative indices — so an
    // adjacent-month band lands in the spillover columns (same 4-lane track index). Year/month: own frame.
    let f: Frame
    let startIdx: Int, endIdx: Int
    if g.z >= 1.5 {
        // relDomOf gates adjacency (incl. across the Dec↔Jan year boundary); an off-year, non-neighbor
        // band resolves to nil and doesn't render — so the year check is folded into this mapping.
        guard let rs = relDomOf(g.year, g.focus, ev.year, ev.month, ev.startDay),
              let re = relDomOf(g.year, g.focus, ev.year, ev.month, ev.endDay) else { return nil }
        f = frameFor(g.focus, g, anim: anim); startIdx = rs; endIdx = re
    } else {
        guard ev.year == g.year else { return nil } // month/year view is year-scoped, positioned by month
        f = frameFor(ev.month, g, anim: anim); startIdx = ev.startDay; endIdx = ev.endDay
    }
    if f.opacity < 0.02 || !bandOnScreen(f.bandY, f.trackH, g.vp) {
        return nil
    }
    let x = f.x0 + CGFloat(startIdx - 1) * f.dayW
    let w = CGFloat(endIdx - startIdx + 1) * f.dayW
    let leftRaw = x + 2 // 2px inset from the enclosing day-cell borders
    let rightRaw = x + w - 2
    let left = max(leftRaw, Layout.labelW)
    let right = min(rightRaw, g.vp.w)
    if right - left < 2 {
        return nil
    }
    return BandRect(
        x: left,
        y: f.bandY + CGFloat(ev.track) * f.trackH + 3, // 3px inset top/bottom (shorter band)
        w: max(2, right - left),
        h: max(3, f.trackH - 6),
        clipStart: leftRaw < Layout.labelW - 0.5,
        clipEnd: rightRaw > g.vp.w + 0.5
    )
}

/// Which month band / track lane / day is under the cursor (for create + move, later).
public func bandSlotAtPoint(_ px: CGFloat, _ py: CGFloat, _ g: SceneInput) -> (month: Int, track: Int, day: Int)? {
    if px < Layout.labelW {
        return nil
    }
    for m in 0 ..< 12 {
        let f = frameFor(m, g)
        if f.opacity < 0.02 || !bandOnScreen(f.bandY, f.trackH, g.vp) {
            continue
        }
        if py < f.bandY || py >= f.bandY + 4 * f.trackH {
            continue
        }
        let dim = daysInMonth(g.year, m)
        let day = Int((px - f.x0) / f.dayW) + 1
        if day < 1 || day > dim {
            continue
        }
        return (m, min(3, max(0, Int((py - f.bandY) / f.trackH))), day)
    }
    return nil
}

/// ── Deadlines ──────────────────────────────────────────────────────────────────────
public struct Deadline: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: CGFloat // 0–24 fractional — the deadline's wall-clock in `anchorTz`
    public var title: String
    public var color: String
    // LEGACY: the timezone a deadline was originally *given* in, back when `hour` was stored in the
    // main tz and this was a display-only label. Superseded by `anchorTz` (which drives positioning).
    // Kept so old stores/records decode; the load migration folds it into `anchorTz` and clears it.
    public var originTz: String?
    // The timezone this deadline is anchored to (a concrete IANA id, or "AOE"); nil = the main tz is
    // canonical. `hour` (+ year/month/day) is the wall-clock IN this zone; the absolute instant is
    // derived and the timeline converts anchorTz→mainTz for display. Never stored as "auto".
    public var anchorTz: String?
    public init(
        id: String,
        year: Int,
        month: Int,
        day: Int,
        hour: CGFloat,
        title: String,
        color: String,
        originTz: String? = nil,
        anchorTz: String? = nil
    ) {
        self.id = id; self.year = year; self.month = month; self.day = day
        self.hour = hour; self.title = title; self.color = color; self.originTz = originTz; self.anchorTz = anchorTz
    }
}

/// A deadline's line position on the day-detail timeline: a horizontal rule across the
/// day column at the deadline's hour. nil when off the focused window or scrolled out.
public func deadlinePos(_ d: Deadline, _ g: SceneInput, focus: Int? = nil,
                        anim: PageAnim? = nil) -> (x: CGFloat, y: CGFloat, w: CGFloat)? {
    let mo = focus ?? g.focus
    let tl = timelineInfo(g, focus: focus, anim: anim)
    // relDomOf gates adjacency (incl. across the year boundary) — an off-year, non-neighbor deadline
    // resolves to nil and doesn't render; a Dec↔Jan spillover deadline maps into the boundary column.
    guard tl.reveal > 0.05, tl.hourH > 0, let rd = relDomOf(g.year, mo, d.year, d.month, d.day) else { return nil }
    // Month view shows the whole month's timeline, so an adjacent month's deadline (rd outside
    // 1…dim, via relDomOf's spillover) must not leak in. Week/day view (z≥1.5) spans month edges.
    if g.z < 1.5 && (rd < 1 || rd > daysInMonth(g.year, mo)) {
        return nil
    }
    let x = tl.x0 + CGFloat(rd - 1) * tl.colW
    // Week/day view spans month edges but only a few day columns are on screen. Cull a column scrolled
    // out of the visible content strip [labelW, vp.w] — else its label pill leaks into the track-name
    // gutter on the left. Use the FULL content width even in day view (not the focus-day edge): the
    // other days of the week must fade out via dailyFade + the sliding dashboard mask as z→3, not vanish
    // the instant z crosses 2.
    if g.z >= 1.5 {
        if x + tl.colW <= Layout.labelW || x >= g.vp.w {
            return nil
        }
    }
    let y = tl.tlTop + d.hour * tl.hourH - tl.scroll
    if y < tl.tlTop || y > tl.tlBottom {
        return nil
    }
    return (x, y, tl.colW)
}

/// ── Deadline side-label placement (shared by the SwiftUI pill AND the pointer hit-test) ─────
public enum DeadlineLabel {
    public static let height: CGFloat = 36
    public static let gap: CGFloat = 12 // distance the label floats from the moment line
    public static let hPad: CGFloat = 7 // horizontal padding inside the pill (per side)
    public static let safety: CGFloat = 8 // slack so the semibold time row / SwiftUI metrics don't clip
    public static let minWidth: CGFloat = 56
    public static let maxWidth: CGFloat = 200 // cutoff — longer titles truncate
}

/// Typographic width of a string in a font (CoreText, so it works on macOS + iOS without AppKit).
/// Memoized: CTLine creation + measurement is expensive and this runs per label per FRAME
/// (deadline labels re-measure while anything animates — hot in the month-swipe profile).
/// Key = string + font point size (all callers use the same font family per size).
private nonisolated(unsafe) var ctWidthCache: [WidthKey: CGFloat] = [:]
private struct WidthKey: Hashable {
    let s: String
    let size: CGFloat
}

private func ctTextWidth(_ s: String, _ font: CTFont) -> CGFloat {
    if s.isEmpty {
        return 0
    }
    let key = WidthKey(s: s, size: CTFontGetSize(font))
    if let hit = ctWidthCache[key] {
        return hit
    }
    let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    if ctWidthCache.count > Layout.measureCacheCap {
        ctWidthCache.removeAll(keepingCapacity: true)
    }
    ctWidthCache[key] = w
    return w
}

/// A deadline's label content + placement: the two text rows, its content-flexed size, the line it
/// hangs off, and the default side. It can produce its rect for EITHER side (so the overlay may flip
/// an occluded label to the other side without re-measuring). One source of truth so the rendered
/// pill and the default clickable/hoverable rect always agree.
public struct DeadlineLabelInfo: Sendable {
    public var lineX: CGFloat // the moment line's left edge (column x)
    public var lineY: CGFloat // the moment line's y
    public var colW: CGFloat // column width
    public var width: CGFloat // content-flexed pill width
    public var height: CGFloat
    public var defaultOnLeft: Bool // the side chosen by geometry (label sits left of the column)
    public var title: String
    public var timeLine: String

    /// The pill rect on a given side: `onLeft` = label sits left of the column (caret points right).
    public func rect(onLeft: Bool) -> CGRect {
        let left = onLeft ? lineX - DeadlineLabel.gap - width : lineX + colW + DeadlineLabel.gap
        return CGRect(x: left, y: lineY - height / 2, width: width, height: height)
    }

    public var rect: CGRect {
        rect(onLeft: defaultOnLeft)
    } // the default-side rect (used by hit-test)
    public var pointsRight: Bool {
        defaultOnLeft
    }
}

public func deadlineLabelInfo(_ d: Deadline, lineX x: CGFloat, lineY y: CGFloat, colW: CGFloat,
                              _ g: SceneInput) -> DeadlineLabelInfo {
    let title = d.title
    let t = Int((d.hour * 60).rounded())
    var timeLine = String(format: "%02d:%02d", (t / 60) % 24, t % 60)
    if let origin = DeadlineTZ.originLabel(d, mainTz: g.mainTz) {
        timeLine += "  (\(origin))"
    }

    let titleFont = CTFontCreateWithName("Comic Sans MS" as CFString, 12, nil)
    let timeFont = CTFontCreateUIFontForLanguage(.system, 10, nil) ?? CTFontCreateWithName(
        "Helvetica" as CFString,
        10,
        nil
    )
    let contentW = max(ctTextWidth(title, titleFont), ctTextWidth(timeLine, timeFont))
    let W = min(
        DeadlineLabel.maxWidth,
        max(DeadlineLabel.minWidth, contentW + 2 * DeadlineLabel.hPad + DeadlineLabel.safety)
    )
    let onLeft = g.z > 2 || (x + colW / 2 >= (Layout.labelW + g.vp.w) / 2)
    return DeadlineLabelInfo(lineX: x, lineY: y, colW: colW, width: W, height: DeadlineLabel.height,
                             defaultOnLeft: onLeft, title: title, timeLine: timeLine)
}

/// OFFLINE side assignment: for each visible deadline, choose left/right so total label overlap is
/// minimal. It ONLY picks a side — never stacks or moves a label vertically; some overlap may remain.
/// The engine runs this when the month or the deadline set changes (not per frame); the runtime
/// hover-flip may still override an individual label on top of this. Time-aware: labels whose vertical
/// boxes can't overlap are solved independently (so an 8pm deadline never affects the 8am ones).
public func deadlineSideAssignment(_ deadlines: [Deadline], _ g: SceneInput) -> [String: Bool] {
    // Day view: one wide day column — labels always sit on its left, never assigned to the right.
    if g.z > 2 {
        var out: [String: Bool] = [:]
        for d in deadlines where deadlinePos(d, g) != nil {
            out[d.id] = true
        }
        return out
    }
    struct L { let id: String; let left: CGRect; let right: CGRect; let colX: CGFloat; let def: Bool }
    var ls: [L] = []
    for d in deadlines {
        guard let pos = deadlinePos(d, g) else { continue }
        let info = deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, g)
        ls.append(L(id: d.id, left: info.rect(onLeft: true), right: info.rect(onLeft: false),
                    colX: pos.x + pos.w / 2, def: info.defaultOnLeft))
    }
    // Cluster by vertical overlap: labels whose y-ranges are disjoint can never overlap, so their side
    // choices are independent — solve each cluster separately to keep the search small.
    ls.sort { $0.left.minY < $1.left.minY }
    var clusters: [[L]] = []
    var clusterMaxY = -CGFloat.infinity
    for l in ls {
        if l.left.minY < clusterMaxY, !clusters.isEmpty {
            clusters[clusters.count - 1].append(l)
        } else {
            clusters.append([l]); clusterMaxY = -.infinity
        }
        clusterMaxY = max(clusterMaxY, l.left.maxY)
    }

    func overlap(_ a: CGRect,
                 _ b: CGRect) -> CGFloat {
        let x = a.intersection(b); return x.isNull ? 0 : x.width * x.height
    }

    var out: [String: Bool] = [:]
    for cluster in clusters {
        // Sort left-to-right by column so the no-crossing test is a simple monotonicity check.
        let c = cluster.sorted { $0.colX < $1.colX }
        let n = c.count
        if n == 1 {
            out[c[0].id] = c[0].def; continue
        }
        func rect(_ i: Int, _ left: Bool) -> CGRect {
            left ? c[i].left : c[i].right
        }
        func labelX(_ i: Int, _ left: Bool) -> CGFloat {
            left ? c[i].left.midX : c[i].right.midX
        }
        // HARD CONSTRAINT — no crossing: in column order the chosen label centers must be non-decreasing.
        // A decrease means a left deadline's label sits right of a right deadline's label, so their
        // connectors cross (e.g. day-1's label on the right + day-2's label on the left). Forbidden no
        // matter how much overlap it would save; overlap is only minimized among crossing-free options.
        func crosses(_ s: [Bool]) -> Bool {
            for i in 0 ..< (n - 1) where labelX(i, s[i]) > labelX(i + 1, s[i + 1]) + 0.5 {
                return true
            }
            return false
        }
        func cost(_ s: [Bool]) -> CGFloat {
            var t: CGFloat = 0
            for i in 0 ..< n {
                for j in (i + 1) ..< n {
                    t += overlap(rect(i, s[i]), rect(j, s[j]))
                }
            }
            return t
        }
        var sides: [Bool]
        if n <= 16 { // brute force over crossing-free combinations, tie-break toward the defaults
            var best: (c: CGFloat, flips: Int)? = nil
            var bestS = [Bool](repeating: false, count: n) // all-right is always crossing-free
            for mask in 0 ..< (1 << n) {
                let s = (0 ..< n).map { (mask >> $0) & 1 == 1 }
                if crosses(s) {
                    continue
                }
                let k = cost(s)
                let flips = (0 ..< n).reduce(0) { $0 + (s[$1] != c[$1].def ? 1 : 0) }
                if best == nil || k < best!.c - 0.5 || (abs(k - best!.c) <= 0.5 && flips < best!.flips) {
                    best = (k, flips); bestS = s
                }
            }
            sides = bestS
        } else { // greedy left-to-right: pick the crossing-free side with least overlap so far
            sides = [Bool](repeating: false, count: n)
            var prevX = -CGFloat.infinity // last placed label center; the next must be ≥ this
            for i in 0 ..< n {
                var bestSide = false; var bestCost = CGFloat.infinity
                for side in [c[i].def, !c[i].def] { // try default first so ties keep it
                    if labelX(i, side) < prevX - 0.5 {
                        continue
                    } // would cross a placed label
                    var lc: CGFloat = 0
                    for j in 0 ..< i {
                        lc += overlap(rect(i, side), rect(j, sides[j]))
                    }
                    if lc < bestCost - 0.5 {
                        bestCost = lc; bestSide = side
                    }
                }
                sides[i] = bestSide; prevX = labelX(i, bestSide)
            }
        }
        for (i, l) in c.enumerated() {
            out[l.id] = sides[i]
        }
    }
    return out
}
