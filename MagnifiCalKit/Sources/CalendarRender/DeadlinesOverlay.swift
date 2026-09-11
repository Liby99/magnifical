// Deadline labels: the DeadlinesOverlay glass pills and their private leaf views
// (DeadlinePill, SideBorder, Caret). Split from EventsOverlay.swift (audit round, 2026-08-02).

import CalendarGeometry
import SwiftUI

/// The deadline moment-lines + end-dots Canvas (SceneRenderer.drawMid), EQUATABLE-wrapped.
///
/// Why the wrapper exists (regression 2026-09): the old inline `Canvas { … drawMid(…) }` read
/// `engine.viewDeadlines()` INSIDE the closure, so the view had no data-bearing fields — and a
/// SwiftUI Canvas only re-records when ITS inputs change. While a deadline label is dragged the
/// rest of the scene is static (no scroll/zoom/hover churn ⇒ `input` identical every frame), so
/// the canvas never re-recorded: the pill (DeadlinesOverlay, which takes the deadlines as a
/// VALUE) followed the drag while the line stayed frozen at the mouse-down position. Keying ==
/// on everything the draw reads makes the line re-record exactly when a deadline (or activation)
/// changes — verified by MidDeadlinesCanvasTests + the ddl-drag recording.
public struct MidDeadlinesCanvas: View, Equatable {
    let input: SceneInput
    let deadlines: [Deadline]
    let selected: String?
    let drawerOpen: Bool
    let hovered: String?
    let only: String? // drawer lift: draw ONLY this deadline (sharp, above the scrim)
    let hide: String? // main scene while lifted: skip it
    let sceneDX: CGFloat
    let theme: Theme

    public init(input: SceneInput, deadlines: [Deadline], selected: String?, drawerOpen: Bool,
                hovered: String?, only: String? = nil, hide: String? = nil,
                sceneDX: CGFloat, theme: Theme) {
        self.input = input
        self.deadlines = deadlines
        self.selected = selected
        self.drawerOpen = drawerOpen
        self.hovered = hovered
        self.only = only
        self.hide = hide
        self.sceneDX = sceneDX
        self.theme = theme
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.input == b.input && a.deadlines == b.deadlines && a.selected == b.selected
            && a.drawerOpen == b.drawerOpen && a.hovered == b.hovered && a.only == b.only
            && a.hide == b.hide && a.sceneDX == b.sceneDX
            && a.theme.dark == b.theme.dark && a.theme.accentDark == b.theme.accentDark
    }

    public var body: some View {
        Canvas { ctx, _ in
            var c = ctx
            c.translateBy(x: sceneDX, y: 0)
            RenderProf.measure("drawMid", "3_drawMid") {
                SceneRenderer.drawMid(input: input, deadlines: deadlines, selected: selected,
                                      drawerOpen: drawerOpen, hovered: hovered, only: only,
                                      hide: hide, in: &c, theme: theme)
            }
        }
    }
}

// ── Deadline labels: SwiftUI glass pills above the Canvas moment-line ─────────────────
// The horizontal moment line + end dots are drawn in the Canvas (SceneRenderer.drawMid); this
// renders the LABEL as a glass pill with the SAME five activation levels as events (tint by level;
// border: none for plain/hover, solid focus-main, dashed accompanied, thick selected). The line
// itself never dashes — selection styling lives entirely on the pill.
public struct DeadlinesOverlay: View {
    let input: SceneInput
    let deadlines: [Deadline]
    var sides: [String: Bool] = [:] // offline side assignment (id → onLeft); base for each label
    let selected: String?
    var selectedIds: Set<String> = [] // the FULL multi-selection (each member gets a focus ring)
    let hovered: String?
    let drawerOpen: Bool
    var only: String? // lifted copy → render ONLY this deadline's tag (sharp, above the scrim)
    var hide: String? // blurred main scene → SKIP this tag (it's drawn sharp in the lift)
    let theme: Theme

    public init(input: SceneInput, deadlines: [Deadline], sides: [String: Bool] = [:],
                selected: String?, selectedIds: Set<String> = [], hovered: String?,
                drawerOpen: Bool, only: String? = nil, hide: String? = nil, theme: Theme) {
        self.input = input
        self.deadlines = deadlines
        self.sides = sides
        self.selected = selected
        self.selectedIds = selectedIds
        self.hovered = hovered
        self.drawerOpen = drawerOpen
        self.only = only
        self.hide = hide
        self.theme = theme
    }

    private func activation(_ id: String) -> EventActivation {
        // Every box is independent — only the EXACT selected box is highlighted (no series-wide
        // "accompanied" highlight), so selecting a promoted band / one occurrence doesn't light up its
        // siblings or its source event. Multi-select gives every member a focus ring.
        if selectedIds.contains(id) {
            return (selectedIds.count == 1 && drawerOpen) ? .selected : .focusMain
        }
        if id == selected {
            return drawerOpen ? .selected : .focusMain
        }
        if id == hovered {
            return .hover
        }
        return .plain
    }

    /// Per-label content + geometry (both possible sides). The base side comes from `sides`; the
    /// rendered pill matches the hit-test because both use the same base + flip rule.
    private struct Spec: Identifiable {
        let id: String; let info: DeadlineLabelInfo; let color: String; let fade: Double
    }

    private func specs(focus: Int, anim: PageAnim?, fadeMul: CGFloat) -> [Spec] {
        let tl = timelineInfo(input, focus: focus, anim: anim)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return [] }
        var gf = input; gf.focus = focus
        var out: [Spec] = []
        for d in deadlines {
            if let only, d.id != only {
                continue
            }
            if let hide, d.id == hide {
                continue
            }
            guard let pos = deadlinePos(d, input, focus: focus, anim: anim) else { continue }
            let rd = relDomOf(input.year, focus, d.year, d.month, d.day) ?? -999
            let spill = (input.z >= 1.5) ? spillFactor(d.month, gf, dim: EventsOverlay.spilloverDim) : 1
            let fade = dailyFade(rd, gf) * tl.reveal * fadeMul * spill
            if fade <= 0.02 {
                continue
            }
            out.append(Spec(
                id: d.id,
                info: deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, input),
                color: d.color,
                fade: Double(fade)
            ))
        }
        return out
    }

    /// Off-viewport deadlines' edge indicators: an EMPTY mini pill (fixed size, no text) beside
    /// the edge-hugging line the Canvas draws — the same caret-toward-the-line shape, shrunken.
    private struct EdgeSpec: Identifiable {
        let id: String; let rect: CGRect; let onLeft: Bool; let color: String; let fade: Double
    }

    private func edgeSpecs(focus: Int, anim: PageAnim?, fadeMul: CGFloat) -> [EdgeSpec] {
        let tl = timelineInfo(input, focus: focus, anim: anim)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return [] }
        var gf = input; gf.focus = focus
        var out: [EdgeSpec] = []
        for d in deadlines {
            if let only, d.id != only {
                continue
            }
            if let hide, d.id == hide {
                continue
            }
            guard let lab = deadlineEdgeLabel(d, input, focus: focus, anim: anim) else { continue }
            let rd = relDomOf(input.year, focus, d.year, d.month, d.day) ?? -999
            let spill = (input.z >= 1.5) ? spillFactor(d.month, gf, dim: EventsOverlay.spilloverDim) : 1
            let fade = dailyFade(rd, gf) * tl.reveal * fadeMul * spill
            if fade <= 0.02 {
                continue
            }
            out.append(EdgeSpec(id: d.id, rect: lab.rect, onLeft: lab.onLeft,
                                color: d.color, fade: Double(fade)))
        }
        return out
    }

    public var body: some View {
        let anim = input.monthAnim
        let clipRight = dashboardLeftAnimated(input) // day-view dashboard mask (slides in from the right)
        let outMul = anim.map { outgoingDetailReveal($0.p) } ?? 1
        ZStack(alignment: .topLeading) {
            pillLayer(focus: input.focus, anim: anim, fadeMul: outMul, clipRight: clipRight)
            if let anim {
                let to = input.focus + anim.dir
                if to >= 0, to <= 11 {
                    pillLayer(
                        focus: to,
                        anim: anim,
                        fadeMul: incomingDetailReveal(anim.p),
                        clipRight: clipRight
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func pillLayer(focus: Int, anim: PageAnim?, fadeMul: CGFloat,
                                        clipRight: CGFloat) -> some View {
        let tl = timelineInfo(input, focus: focus, anim: anim)
        let H = DeadlineLabel.height
        let all = specs(focus: focus, anim: anim, fadeMul: fadeMul)
        // The raised label (hovered / selected); neighbours only yield when its cursor LINE would cross
        // them. Pure label-label overlap is fine — the raised label just occludes the other.
        let topSpec = all.max { activation($0.id).z < activation($1.id).z }
        let topLine: CGRect? = topSpec.flatMap { t in
            activation(t.id).z > 0 ? CGRect(
                x: t.info.lineX - 4,
                y: t.info.lineY - 5,
                width: t.info.colW + 8,
                height: 10
            ) : nil
        }
        let topId = topSpec?.id
        // Horizontal clip limit: generous past the viewport when no panel is up, hard at the live
        // dashboard mask edge when one is (pills must be occluded by the panel like Canvas content).
        let rightEdge = clipRight >= input.vp.w - 0.5 ? input.vp.w + Layout.labelW : clipRight
        ZStack(alignment: .topLeading) {
            ForEach(edgeSpecs(focus: focus, anim: anim, fadeMul: fadeMul)) { s in
                MiniDeadlinePill(color: theme.eventBorder(s.color), onLeft: s.onLeft,
                                 hovering: s.id == hovered, theme: theme)
                    .frame(width: s.rect.width, height: s.rect.height)
                    .opacity(s.fade)
                    .position(x: s.rect.midX, y: s.rect.midY)
            }
            ForEach(all) { s in
                let a = activation(s.id)
                let base = sides[s.id] ?? s.info.defaultOnLeft // offline assignment (fallback: default)
                // Flip to the other side only when the raised deadline's LINE would cross this label —
                // but never in day view, where labels always stay on the left of the single day column.
                let flip = input.z <= 2 && topId != nil && topId != s.id && topLine
                    .map { s.info.rect(onLeft: base).intersects($0) } == true
                let onLeft = flip ? !base : base
                let rect = s.info.rect(onLeft: onLeft)
                DeadlinePill(title: s.info.title, timeLine: s.info.timeLine, color: theme.eventBorder(s.color),
                             activation: a, onLeft: onLeft, width: rect.width, height: rect.height, theme: theme)
                    .opacity(s.fade)
                    .position(x: rect.midX, y: rect.midY)
                    .zIndex(a.z) // hovered/selected label rises above overlapping neighbors
                    .animation(.easeInOut(duration: 0.2), value: onLeft) // slide + caret-swap on flip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Clip vertically to the timeline (so a deadline scrolled out of view hides its label);
        // horizontally generous on the left (a side-placed pill/caret isn't cut), hard at
        // `rightEdge` (see above) so pills never float over the dashboard panel.
        .clipShape(RectClip(rect: CGRect(
            x: -Layout.labelW,
            y: tl.tlTop - H,
            width: rightEdge + Layout.labelW,
            height: (tl.tlBottom - tl.tlTop) + 2 * H
        )))
    }
}

/// One deadline label: a two-line glass pill (title over time+timezone) sized like a band event,
/// tinted + bordered by its activation level, with a caret pointing into the moment line.
private struct DeadlinePill: View {
    let title: String
    let timeLine: String
    let color: Color
    let activation: EventActivation
    let onLeft: Bool // pill sits left of the column → caret/border on its RIGHT edge (points in)
    let width: CGFloat
    let height: CGFloat
    let theme: Theme
    var body: some View {
        let r: CGFloat = 10
        let shape = RoundedRectangle(cornerRadius: r)
        VStack(alignment: .leading, spacing: -1) {
            Text(title).font(.custom(BandStyle.titleFontName, size: 12)).foregroundStyle(theme.text).lineLimit(1)
            Text(timeLine).font(.system(size: 10, weight: .semibold)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .frame(width: width, height: height, alignment: .leading)
        // Opaque base UNDER the frosted glass (like the event stickers) so the label reads as a solid
        // frosted pill in front of the timeline, not a translucent tint you can see through.
        .background {
            ZStack {
                shape.fill(theme.bg) // occludes the timeline behind → the frost reads solid
                Color.clear.glassEffectCompat(.regular.tint(color.opacity(activation.tint * theme.eventTintScale)), in: shape)
            }
        }
        // Edge accent (border + caret) on the line-facing side; the other side stays collapsed. On a
        // flip the old caret retracts into the pill edge while the new one grows from the opposite side.
        .overlay { sideEdge(pointsRight: true, shown: onLeft, r: r) }
        .overlay { sideEdge(pointsRight: false, shown: !onLeft, r: r) }
        .overlay { activationBorder(activation, color: color, in: RoundedRectangle(cornerRadius: r)) }
        .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }

    private func sideEdge(pointsRight: Bool, shown: Bool, r: CGFloat) -> some View {
        ZStack {
            SideBorder(pointsRight: pointsRight, radius: r).strokeBorder(color, lineWidth: 1)
            Caret(pointsRight: pointsRight).fill(color)
                .frame(width: 6, height: 11)
                .scaleEffect(x: shown ? 1 : 0, anchor: pointsRight ? .leading : .trailing) // grow/retract at the edge
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointsRight ? .trailing : .leading)
                .offset(x: pointsRight ? 6 : -6)
        }
        .opacity(shown ? 1 : 0)
    }
}

/// The edge indicator's EMPTY label: the deadline pill's exact chrome (glass base, rounded
/// corners, side border + caret pointing into the line) at a fixed mini size — no title, no
/// time, no activation styling (the indicator is render-only).
private struct MiniDeadlinePill: View {
    let color: Color
    let onLeft: Bool // pill sits left of the column → caret on its RIGHT edge (points in)
    var hovering: Bool = false // click target (scroll-to-center) → mild hover styling
    let theme: Theme
    var body: some View {
        let r = DeadlineEdgeLabel.radius
        let shape = RoundedRectangle(cornerRadius: r)
        // Hover = the hover activation's tint bump + a slightly stronger edge and small scale-up
        // (the pointing-hand cursor comes from the engine's cursorHint, like the edge stacks).
        let tint = (hovering ? EventActivation.hover.tint : EventActivation.plain.tint) * theme.eventTintScale
        ZStack {
            shape.fill(theme.bg) // occlude the timeline behind, like the full pill
            Color.clear.glassEffectCompat(.regular.tint(color.opacity(tint)), in: shape)
        }
        .overlay {
            SideBorder(pointsRight: onLeft, radius: r).strokeBorder(color, lineWidth: hovering ? 1.5 : 1)
        }
        .overlay {
            Caret(pointsRight: onLeft).fill(color)
                .frame(width: 4, height: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: onLeft ? .trailing : .leading)
                .offset(x: onLeft ? 4 : -4)
        }
        .scaleEffect(hovering ? 1.07 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One rounded side of a pill — the vertical edge plus its two corner arcs — for a colored border
/// that hugs the caret's side (covering the corners, unlike a straight bar).
private struct SideBorder: InsettableShape {
    let pointsRight: Bool
    let radius: CGFloat
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> SideBorder {
        var s = self; s.inset += amount; return s
    }

    func path(in rectIn: CGRect) -> Path {
        var p = Path()
        let rect = rectIn.insetBy(dx: inset, dy: inset)
        let r = radius - inset // keep the arcs riding the (inset) rounded corner
        // Just 45° of each corner (the half nearest the vertical edge), so the border only nudges
        // into the corners rather than wrapping them fully.
        if pointsRight {
            p.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                radius: r,
                startAngle: .degrees(-45),
                endAngle: .degrees(0),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(45),
                clockwise: false
            )
        } else {
            p.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(135),
                endAngle: .degrees(180),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(225),
                clockwise: false
            )
        }
        return p
    }
}

/// A small triangular caret pointing toward a line (deadline moment line / now-line).
struct Caret: Shape { // internal: read by EventsOverlay.swift (TimeTagsOverlay)
    let pointsRight: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsRight {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}
