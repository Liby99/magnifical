// Viewport-overflow indicators for the week/day hour timelines: a timed event scrolled fully past
// the timeline's top/bottom edge leaves a small sliver of its color pinned at that edge, Apple-
// Calendar-style. PURE math, evaluated per frame from (event rects, viewport): every clamp/stack/
// indent value is a continuous piecewise-linear function of each event's overshoot past the edge,
// so smooth scroll-driven transitions fall out of the arithmetic — no discrete animations anywhere.
//
// Model (per day column, per edge; S = Layout.edgeIndicatorH, T = Layout.edgeIndicatorMorph):
//  • v = the rect's remaining visible extent toward the edge (top: maxY − tlTop; bottom mirrored).
//    An event CLAMPS once v < its DESTINATION card height H = S·(1 + min(clamped mass outward of
//    it, max − 1)) — swept farthest-out first, so a card joining a settled n-stack stops
//    scrolling with (n+1)·S px (≤ max·S) still showing and HOLDS there; it never shrinks below
//    its final indicator height and regrows (which read as a disappear/reappear). While v ≥ H
//    the event renders normally (the viewport clip shrinks it).
//  • p = clamp((H − v)/T, 0, 1) is the event's morph progress: how far past its clamp point it
//    has scrolled, normalized over T px of travel. Each indicator's rect lerps from its own
//    clamped strip (own x/width, H tall — identical to the just-clipped sticker it replaces) into
//    its stack slot by p — so a newcomer's arrival IS the interpolation toward the next stack
//    layout, driven only by scroll.
//  • Rank = nearness-in-time to the visible window (top edge: larger maxY = nearer). Rank 0 is
//    the INNERMOST slot — largest indent, drawn on top — matching Apple Calendar's order.
//  • vis(r) = clamp(max − Σ p of nearer members, 0, 1): the stack holds at most
//    Layout.edgeIndicatorMax slivers, and as a newcomer crosses, the pushed-out outermost fades
//    by exactly the newcomer's progress. total = Σ p·vis is the CONTINUOUS member count:
//      width     = base − S·(clamp(total, 1, max) − 1)
//      indent(r) = S·min(Σ outward p·vis, max − 1)
//      height(r) = S + indent(r) — height and indent ride the SAME mass term
//    reproduce the integer layouts exactly (1 → full width, S tall; 2 → full−S, indents S/0,
//    heights 2S/S; 3 → full−2S, indents 2S/S/0, heights 3S/2S/S) and linearly interpolate every
//    transition between them — including the 4th-event handoff, where each survivor's indent AND
//    height relax a step together while the outermost fades out at the S-tall un-indented slot.
//  • The heights make the stack a CARD STAIRCASE, not co-located bands: every sliver's top is
//    pinned at the edge (bottom edge mirrored), the innermost/nearest is the TALLEST (up to 3S),
//    most indented, and drawn on top; each outward card is S shorter and S less indented, so it
//    peeks out as an S×S step up-and-outward from the card in front of it — the farthest event
//    ends up shortest and flush left.

import CoreGraphics

/// One pinned sliver at a timeline edge.
public struct EdgeIndicator: Sendable, Equatable {
    public var index: Int // into the rects array handed to dayEdgeIndicators
    public var rect: CGRect // the card (viewport space), edge-pinned; settled height = edgeIndicatorH + indent
    public var opacity: CGFloat // 1 shown … → 0 as the pushed-out outermost exits
    public var rank: Int // 0 = nearest-in-time / innermost — draw ABOVE higher ranks
    public var progress: CGFloat // 0 just clamped … 1 settled into its stack slot
}

/// One day column's overflow-indicator layout against the timeline viewport.
public struct DayEdgeIndicators: Sendable, Equatable {
    public var top: [EdgeIndicator] = [] // rank-ascending (innermost first)
    public var bottom: [EdgeIndicator] = []
    /// Per input index: true → this rect is an edge candidate this frame (render its
    /// EdgeIndicator, NOT the normal sticker). EMPTY ⇔ no indicators at all (all normal).
    public var isIndicator: [Bool] = []
    /// The stack's single click target — one full-event-width band at the edge per stack
    /// (clicking anywhere on it targets the nearest event, whichever sliver is under the cursor).
    public var topHit: CGRect?
    public var bottomHit: CGRect?
    /// Input index of the NEAREST off-viewport event per edge — what a stack click scrolls to.
    public var topNearest: Int?
    public var bottomNearest: Int?

    public init() {}
}

/// Compute one day column's edge indicators. `rects` are the day's timed-segment rects in
/// VIEWPORT space (timeline scroll already applied; may extend past tlTop/tlBottom); `colX`/
/// `colW` describe the day column — the full event width derives from them with the same ±2px
/// horizontal insets `eventRect` applies. Pure and allocation-light: the no-overflow frame
/// returns an empty layout without building any per-rect state.
public func dayEdgeIndicators(rects: [CGRect], tlTop: CGFloat, tlBottom: CGFloat,
                              colX: CGFloat, colW: CGFloat) -> DayEdgeIndicators {
    let S = Layout.edgeIndicatorH
    var out = DayEdgeIndicators()
    guard tlBottom - tlTop > 2 * S + 1, colW > 0, !rects.isEmpty else { return out }
    let baseX = colX + 2
    let baseW = max(3, colW - 4) // mirror eventRect's horizontal insets
    let top = edgeStack(rects, edgeY: tlTop, topEdge: true, baseX: baseX, baseW: baseW)
    let bottom = edgeStack(rects, edgeY: tlBottom, topEdge: false, baseX: baseX, baseW: baseW)
    guard !(top.isEmpty && bottom.isEmpty) else { return out }
    out.top = top
    out.bottom = bottom
    var flags = [Bool](repeating: false, count: rects.count)
    for e in top {
        flags[e.index] = true
    }
    for e in bottom {
        flags[e.index] = true
    }
    out.isIndicator = flags
    // The click band spans the whole staircase (its tallest card), one target per stack.
    if let inner = top.first {
        out.topNearest = inner.index
        let maxH = top.reduce(S) { max($0, $1.rect.height) }
        out.topHit = CGRect(x: baseX, y: tlTop, width: baseW, height: maxH)
    }
    if let inner = bottom.first {
        out.bottomNearest = inner.index
        let maxH = bottom.reduce(S) { max($0, $1.rect.height) }
        out.bottomHit = CGRect(x: baseX, y: tlBottom - maxH, width: baseW, height: maxH)
    }
    return out
}

/// The continuous stack layout for ONE edge (see the file header for the model). Returns the
/// shown slivers rank-ascending (innermost first); fully pushed-out members are omitted.
private func edgeStack(_ rects: [CGRect], edgeY: CGFloat, topEdge: Bool,
                       baseX: CGFloat, baseW: CGFloat) -> [EdgeIndicator] {
    let S = Layout.edgeIndicatorH
    let T = Layout.edgeIndicatorMorph
    let maxN = CGFloat(Layout.edgeIndicatorMax)
    // Candidacy sweep, farthest-out → nearest: an event clamps once its remnant v drops below its
    // DESTINATION card height (S + one S-step per morph mass already clamped outward of it,
    // capped) — so it stops at its final distance from the edge and holds, and at p = 0 the card
    // IS the event's remaining clipped strip (seamless takeover). Once one event fails the test,
    // every nearer one fails too (larger v, same threshold — no mass was added).
    var all: [(i: Int, v: CGFloat)] = []
    all.reserveCapacity(rects.count)
    for (i, r) in rects.enumerated() {
        all.append((i, topEdge ? r.maxY - edgeY : edgeY - r.minY))
    }
    // Ascending v; ties by DESCENDING input order, so the reversed (rank) order breaks ties by
    // input order as before.
    all.sort { $0.v != $1.v ? $0.v < $1.v : $0.i > $1.i }
    var cand: [(i: Int, v: CGFloat, p: CGFloat, clampH: CGFloat)] = []
    var clampedMass: CGFloat = 0
    for e in all {
        let clampH = S * (1 + min(clampedMass, maxN - 1))
        if e.v >= clampH {
            break
        }
        let p = clamp((clampH - e.v) / T, 0, 1)
        cand.append((e.i, e.v, p, clampH))
        clampedMass += p
    }
    if cand.isEmpty {
        return []
    }
    cand.reverse() // rank 0 = nearest-in-time to the visible window (largest remaining v) first
    let p = cand.map(\.p)
    // Visibility: each member sees the morph mass INWARD of it; past maxN members it fades out
    // by exactly the newcomers' progress (the 4th-event handoff).
    var vis = [CGFloat](repeating: 0, count: cand.count)
    var inward: CGFloat = 0
    for r in cand.indices {
        vis[r] = clamp(maxN - inward, 0, 1)
        inward += p[r]
    }
    var total: CGFloat = 0
    for r in cand.indices {
        total += p[r] * vis[r]
    }
    let slotW = max(3, baseW - S * (clamp(total, 1, maxN) - 1))
    // Walk outermost → innermost accumulating the vis-weighted mass OUTWARD of each rank — that
    // mass (× S) is the rank's indent AND its extra height (settled height = S + indent: the
    // nearest/innermost card is the tallest and most indented), so both relax together
    // continuously as members enter/exit — the fading outermost sits at the S-tall flush slot.
    var outward: CGFloat = 0
    var out: [EdgeIndicator] = []
    for r in stride(from: cand.count - 1, through: 0, by: -1) {
        if vis[r] > 0.001 {
            let step = S * min(outward, maxN - 1)
            let slotX = baseX + step
            let own = rects[cand[r].i]
            // p lerps the card from its own clamped strip (own x/width, clampH tall — continuous
            // with the just-clipped sticker it replaces) into its stack slot — x, width, AND
            // height. clampH normally equals the slot height (the card holds its distance from
            // the edge while sliding sideways into place); they differ only transiently while the
            // outward mass is itself still morphing.
            let h = lerp(cand[r].clampH, S + step, p[r])
            let rect = CGRect(x: lerp(own.minX, slotX, p[r]), y: topEdge ? edgeY : edgeY - h,
                              width: lerp(own.width, slotW, p[r]), height: h)
            out.append(EdgeIndicator(index: cand[r].i, rect: rect, opacity: vis[r],
                                     rank: r, progress: p[r]))
        }
        outward += p[r] * vis[r]
    }
    return Array(out.reversed())
}
