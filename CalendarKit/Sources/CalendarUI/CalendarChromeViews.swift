// Small chrome views over the calendar canvas: the deadline quick-add "+" and the day-view
// timeline↔dashboard split handle. Split from CalendarView.swift (file diet).
// The Year›Month›Week›Day Breadcrumb moved to CalendarRender (shared with the iPhone client).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// Draggable handle on the timeline↔dashboard boundary in day view. Mirrors the drawer's resize
/// handle: a slim capsule that surfaces on hover, with a resize cursor; dragging it adjusts the
/// split (`daily.frac`). Positioned from `engine.daily.frac` each render — during a drag its own
/// `dragFrac` state drives both the position and the engine update, so the handle tracks the cursor
/// even though the engine isn't `@Observable`.
/// The deadline quick-add "+" affordance: a small circle with a plus, matching the calendar's cursor
/// accent. Purely visual (positioned by CalendarView); the click is handled by the InputCatcher.
struct DeadlineAddButton: View {
    let theme: Theme
    var hovering: Bool = false
    var body: some View {
        // Neutral cursor-colored ring at rest; on hover the edge + glyph brighten to full label color,
        // with a faint fill and glow (mirrors the web's .cc-ddl-add:hover feedback).
        Image(systemName: "plus")
            .font(.system(size: 8, weight: hovering ? .heavy : .bold))
            .foregroundStyle(hovering ? theme.text : theme.text.opacity(0.75))
            .frame(width: 15, height: 15)
            .background(Circle().fill(hovering ? theme.text.opacity(0.14) : theme.bg))
            .overlay(Circle().strokeBorder(hovering ? theme.text : theme.cursor, lineWidth: hovering ? 2 : 1.5))
            .shadow(color: theme.text.opacity(hovering ? 0.35 : 0), radius: hovering ? 4 : 0)
            .shadow(color: .black.opacity(0.3), radius: 2.5)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct DashboardSplitHandle: View {
    let engine: CalendarEngine
    let vp: Viewport // gutter-INFLATED at month/week hide (matches dashScopePanels' geometry)
    var gutterShift: CGFloat = 0 // window x = inflated scene x − gutterShift
    let height: CGFloat
    let theme: Theme
    var onFrac: (CGFloat) -> Void = { _ in } // report the live split so the dashboard re-lays-out
    @State private var inGap = false // mouse anywhere in the timeline↔dashboard gap
    @State private var onGrip = false // mouse on the capsule itself (→ brighter + resize cursor)
    @State private var dragFrac: CGFloat?
    @State private var startFrac: CGFloat = 0.45

    private let minFrac = Layout.dayFracMin, maxFrac = Layout.dayFracMax // same clamp as engine.setDailyFrac
    /// The dashboard content is inset ~25px from the boundary (see drawDashboardChrome's barX); the
    /// capsule sits centered in that empty gap, which is also the zone that reveals it on hover.
    private let gapInset: CGFloat = 25

    var body: some View {
        // Real (un-inflated) width basis: the pinned panel is PX-STABLE under the gutter hide
        // (frac × real content — see snapshot's fracEff), so both the handle position and the
        // drag's frac mapping must use the same basis or the handle drifts/oscillates mid-hide.
        let rw = vp.w - gutterShift
        let contentW = max(1, rw - Layout.labelW)
        // Two modes, one handle. DAY: drags the timeline↔dashboard split (daily.frac = TIMELINE
        // width fraction; boundary at labelW + frac·content). PINNED month/week: drags that
        // scope's PANEL width (dashMonth/WeekFrac = PANEL fraction; boundary at w − frac·content,
        // so dragging right SHRINKS the panel). Both persist.
        let pinned = engine.chrome.level < 3
        let isMonth = engine.chrome.level <= 1
        let scopeFrac = isMonth ? engine.chrome.dashMonthFrac : engine.chrome.dashWeekFrac
        let frac = dragFrac ?? (pinned ? scopeFrac : engine.daily.frac)
        // Month panel width floors at dashMonthMinW — the handle sits on the FLOORED edge.
        // Window x of the pinned boundary: padLeft + inflated right edge − panel − gutterShift
        // = padLeft + rw − panel (the inflation and the slide cancel — stable through the hide).
        let gapLeftX = pinned
            ? Layout.padLeft + rw - (isMonth ? dashMonthPanelW(Viewport(w: rw, h: vp.h), frac: frac) : frac * contentW)
            : Layout.padLeft + Layout.labelW + frac * contentW
        let centerX = gapLeftX + gapInset / 2
        let active = onGrip || dragFrac != nil
        // Two states: faint in the gap, lighter on the grip; invisible otherwise.
        let opacity: Double = active ? 0.6 : (inGap ? 0.28 : 0.0)
        Capsule()
            .fill(theme.text.opacity(opacity))
            .frame(width: 4, height: 48)
            .frame(width: 12, height: 56) // grip zone: brighten + resize cursor + drag
            .contentShape(Rectangle())
            .onHover {
                h in onGrip = h; if h {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                // GLOBAL space: the handle repositions itself as `frac` changes, so a `.local`
                // translation would be measured against a moving origin → feedback twitch.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragFrac == nil {
                            startFrac = pinned ? scopeFrac : engine.daily.frac
                        }
                        if pinned {
                            // Panel fraction grows as the boundary moves LEFT.
                            let nf = min(0.55, max(0.15, startFrac - v.translation.width / contentW))
                            dragFrac = nf
                            engine.setDashPinFrac(nf)
                        } else {
                            let nf = min(maxFrac, max(minFrac, startFrac + v.translation.width / contentW))
                            dragFrac = nf
                            engine.setDailyFrac(nf)
                            onFrac(nf)
                        }
                    }
                    .onEnded { _ in dragFrac = nil }
            )
            .frame(width: gapInset, height: height) // gap zone: reveals the capsule (faint)
            .contentShape(Rectangle())
            .onHover { inGap = $0 }
            .position(x: centerX, y: height / 2)
            .animation(.easeOut(duration: 0.12), value: opacity)
    }
}
