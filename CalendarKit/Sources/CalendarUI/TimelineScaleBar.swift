// Video-editor-style scale bar on the week/day timeline, ported from the web's
// TimelineScrollbar.tsx. It lives on the leftmost day's left border: a thin thumb line whose
// position/length mirror the scroll window, with a hollow circle at each end. Dragging the body
// scrolls the timeline; dragging an end RESIZES the visible window — i.e. changes the per-hour
// height (longer thumb = more hours visible = shorter hours), anchoring the opposite end.
// Per the design decision, only the THUMB renders (no dotted full-height track).
//
// Overlay pattern mirrors DashboardSplitHandle: a SwiftUI view above the input catcher that
// reads the engine's per-frame geometry and writes back through engine setters.

import CalendarEngine
import CalendarGeometry
import SwiftUI

struct TimelineScaleBar: View {
    let engine: CalendarEngine
    let theme: Theme
    /// The per-frame TimelineView's date. Not used directly — but as a changing property it
    /// defeats SwiftUI's equal-inputs diffing, which would otherwise SKIP re-evaluating this body
    /// each frame (the geometry reads engine fields that are deliberately observation-ignored).
    let tick: Date

    /// Captured at drag start: (scroll, thumbTop, thumbBottom) in track px — the anchor math
    /// works off these, exactly like the web version's y0/topY/botY.
    @State private var base: (scroll: CGFloat, topY: CGFloat, botY: CGFloat)?
    @State private var hovering = false
    @State private var dragging = false

    private static let minThumb: CGFloat = 26 // keep it grabbable when fully zoomed in
    private static let endD: CGFloat = 9 // end-circle diameter
    private static let hitW: CGFloat = 10 // transparent grab strip width

    var body: some View {
        let tl = timelineInfo(engine.snapshotInput())
        if tl.zoomable, tl.reveal > 0.5, tl.viewH > 60 {
            let totalH = 24 * tl.hourH
            let thumbLen = max(Self.minThumb, tl.viewH / totalH * tl.viewH)
            let maxTop = max(0, tl.viewH - thumbLen)
            let thumbTop = min(maxTop, max(0, max(0, min(tl.maxScroll, tl.scroll)) / totalH * tl.viewH))
            let active = hovering || dragging
            let lineColor = active ? theme.accentDark : theme.accentGrey
            // Proximity reveal: hidden until the cursor approaches the timeline's left border
            // (engine.nearTlEdge, fed by the catcher's mouse tracking); stays up while dragging.
            let visible = engine.nearTlEdge || hovering || dragging

            ZStack(alignment: .topLeading) {
                // ── Thumb: line + end circles, one grab strip ──────────────────────────
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: thumbLen)
                    endCircle(lineColor)
                        .offset(y: -Self.endD / 2)
                        .gesture(endDrag(edge: .top, tl: tl, thumbTop: thumbTop, thumbLen: thumbLen))
                    endCircle(lineColor)
                        .offset(y: thumbLen - Self.endD / 2)
                        .gesture(endDrag(edge: .bottom, tl: tl, thumbTop: thumbTop, thumbLen: thumbLen))
                }
                .frame(width: Self.hitW, height: thumbLen, alignment: .top)
                .contentShape(Rectangle().inset(by: -3))
                // Hover only over the thumb itself — NOT the full-screen overlay container.
                .onHover { hovering = $0 }
                .gesture(bodyDrag(tl: tl, totalH: totalH))
                // Centered on the timeline's visible LEFT BORDER. Scene x=0 renders padLeft px
                // from the window edge (the canvas translates by padLeft), and the visible border
                // sits at labelW in scene space — NOT tl.x0, which is the month's day-1 origin and
                // goes far off-screen once the week pager has scrolled.
                .offset(x: Layout.padLeft + Layout.labelW - engine.gutterShift - Self.hitW / 2, y: tl.tlTop + thumbTop)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible) // an invisible bar must not swallow canvas clicks
            .animation(.easeOut(duration: 0.15), value: visible)
            .animation(.easeOut(duration: 0.12), value: active)
        }
    }

    private func endCircle(_ color: Color) -> some View {
        Circle()
            .fill(theme.bg)
            .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
            .frame(width: Self.endD, height: Self.endD)
            .contentShape(Circle().inset(by: -4))
    }

    /// ── Body drag → scroll ──────────────────────────────────────────────────────────
    /// Gestures measure in .global space: the thumb (and its end circles) MOVE while dragging,
    /// so local-space translation would be measured against a moving origin — a feedback loop
    /// that makes the handle twitch.
    private func bodyDrag(tl: TimelineInfo, totalH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if base == nil {
                    base = (tl.scroll, 0, 0)
                    dragging = true
                    NSCursor.closedHand.push()
                }
                guard let base else { return }
                let s = base.scroll + v.translation.height * totalH / tl.viewH
                engine.setTlScroll(max(0, min(tl.maxScroll, s)))
            }
            .onEnded { _ in endDragCommon() }
    }

    /// ── End drag → resize the visible window (change hour height), anchor the other end ──
    private enum Edge { case top, bottom }

    private func endDrag(edge: Edge, tl: TimelineInfo, thumbTop: CGFloat, thumbLen: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if base == nil {
                    base = (tl.scroll, thumbTop, thumbTop + thumbLen)
                    dragging = true
                    NSCursor.resizeUpDown.push()
                }
                guard let base else { return }
                // The dragged end's live position in track coordinates.
                let startY = edge == .top ? base.topY : base.botY
                let y = max(0, min(tl.viewH, startY + v.translation.height))
                let len = max(Self.minThumb, min(tl.viewH, edge == .bottom ? y - base.topY : base.botY - y))
                let newHourH = clampHourH(tl.viewH * tl.viewH / len / 24)
                let newTotal = 24 * newHourH
                // Keep the anchored end fixed → recompute scroll for the new scale.
                let newScroll = edge == .bottom
                    ? base.topY * newTotal / tl.viewH
                    : base.botY * newTotal / tl.viewH - tl.viewH
                engine.setWeekHourH(newHourH)
                engine.setTlScroll(max(0, min(newTotal - tl.viewH, newScroll)))
            }
            .onEnded { _ in endDragCommon() }
    }

    private func endDragCommon() {
        base = nil
        dragging = false
        NSCursor.pop()
    }
}
