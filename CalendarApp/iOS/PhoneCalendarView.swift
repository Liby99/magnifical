// The iPhone read-only calendar surface — the same scene the Mac renders, minus editing.
//
// Layer stack (bottom → top):
//   PhoneDriverLayer  — invisible per-level ScrollView drivers (touch physics → engine state)
//   render layers     — Canvas passes + glass overlays, allowsHitTesting(false), exactly the
//                       Mac's CalendarView.calendarScene reduced to its read-only layers
//   chrome            — Breadcrumb + calendar switcher (top), sync status (bottom)
// Pinch (semantic zoom) and taps ride as simultaneous gestures over the drivers. A single
// tap selects an event (empty space clears); a double tap opens the event's bottom sheet —
// or, on empty YEAR-view space, drills into the tapped month. Otherwise the two-finger
// pinch is the way between zoom levels (year ⇄ month ⇄ week, like the Mac's trackpad
// pinch — the breadcrumb also zooms back out).

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

struct PhoneCalendarView: View {
    let engine: CalendarEngine
    let bench: PhoneBenchRunner
    @Environment(\.colorScheme) private var scheme
    @AppStorage("cc.fpsHUD") private var hudPref = false // same key as the Mac's Developer toggle
    @State private var sheetItem: SheetItem?
    @State private var showMenu = false
    @State private var showAI = false
    /// While the event sheet is up, the calendar canvas lifts by this much so the selected
    /// event sits highlighted in the sheet-free TOP part of the screen (the medium detent
    /// covers the bottom half). Animated in on open, back to 0 on dismiss.
    @State private var canvasLift: CGFloat = 0

    private struct SheetItem: Identifiable {
        let id: String
    }

    var body: some View {
        let theme = Theme(dark: scheme == .dark)
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                let vp = Viewport(w: geo.size.width - Layout.padLeft - Layout.padRight, h: geo.size.height)
                // Reading `awake` here re-evaluates the body the instant the engine wakes (any
                // navigation/animation), and drops to a single static frame when idle — same
                // idle-CPU pattern as the Mac's calendarSurface.
                let awake = engine.renderClock.awake
                ZStack {
                    PhoneDriverLayer(engine: engine, vp: vp, frozen: pinchActive)
                    TimelineView(.animation(paused: !awake)) { tl in
                        // One evaluation = one rendered frame — the bench/HUD frame feed
                        // (cheap no-op unless a scene records or the HUD is on).
                        let _ = bench.benchTick(tl.date)
                        calendarScene(engine.sceneInput(at: tl.date, viewport: vp), vp: vp, theme: theme)
                    }
                    .allowsHitTesting(false) // presentational; touch goes to the drivers below
                }
                // Sheet-reveal lift: the canvas (drivers included, so touch stays aligned)
                // slides up to put the selected event in the sheet-free top region.
                .offset(y: -canvasLift)
                .simultaneousGesture(taps)
                .simultaneousGesture(pinch)
                // Fires on fingers-up AND system cancellation (the @GestureState reset covers
                // both) — close the engine's pinch so z always gets its settle-to-level tween.
                .onChange(of: pinchActive) { _, active in
                    if !active, pinchPrev != nil {
                        pinchPrev = nil
                        engine.onMagnify(delta: 0, at: .zero, began: false, ended: true)
                    }
                }
                .onAppear {
                    engine.setViewport(geo.size)
                    // Land on today: month row vertically centered, today's day column
                    // horizontally centered in its quarter (goToCurrent seeds yearQX).
                    engine.goToCurrent("year")
                    // Prewarm the first zoom-in's caches while the year view idles: the
                    // per-event anchor-label timezone pass + the focus/neighbor months'
                    // packing otherwise land inside the FIRST zoom's opening frames.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        EventsOverlay.prewarmTimedCaches(
                            events: engine.viewEvents(), year: engine.year,
                            months: [max(0, engine.focus - 1), engine.focus, min(11, engine.focus + 1)],
                            editGen: engine.displayGen, mainTz: engine.mainTz
                        )
                    }
                    // CC_DEMO=bench-* (MagnifiCalPhoneBench scheme): run the scripted scene now
                    // that the viewport is set and the initial navigation has landed.
                    bench.startIfDemo(engine: engine, size: geo.size)
                }
                .onChange(of: geo.size) { _, s in engine.setViewport(s) }
            }
            // Full-bleed canvas: extend under the status bar AND the home-indicator inset so
            // the grid runs edge to edge — content scrolls beneath the Dynamic Island and the
            // floating capsules instead of stopping at solid safe-area strips. The content's
            // own top insets (Layout.yearTop/topPad, set from the measured island height in
            // PhoneCalendarRoot) keep the resting labels clear of the island.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // The toolbar capsules stay INSIDE the safe area (above the home indicator).
            bottomBar
        }
        // Live frame-rate readout (CC_FPS_HUD=1 or the menu's Developer toggle). Top-leading —
        // the bottom belongs to the glass toolbar. Thresholds scale with the display's budget.
        .overlay(alignment: .topLeading) {
            if PhoneBenchRunner.hudEnabled || hudPref {
                FPSHUDView(stats: { bench.hudStats() }, budgetMs: bench.budgetMs)
                    .padding(.top, 40) // clear the Dynamic Island
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .sheet(item: $sheetItem, onDismiss: {
            engine.select(nil)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                canvasLift = 0
            }
        }) { item in
            PhoneEventSheet(engine: engine, boxId: item.id, theme: theme)
        }
        .fullScreenCover(isPresented: $showMenu) {
            PhoneMenuView(engine: engine)
        }
        .sheet(isPresented: $showAI) {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("The assistant is coming to iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .presentationDetents([.fraction(0.25)])
            .presentationDragIndicator(.visible)
        }
    }

    // ── Gestures ─────────────────────────────────────────────────────────────────────

    /// Taps, double-first (the exclusive pairing makes SwiftUI hold a single tap just long
    /// enough to rule out a second one):
    ///   • DOUBLE tap an event → select it AND open its bottom sheet (the Mac's double-click-
    ///     opens-drawer, translated).
    ///   • DOUBLE tap empty space → drill one level in: year → the tapped month, month → the
    ///     week window centered on the tapped day, week → the tapped day's daily view.
    ///   • SINGLE tap an event → just select it (highlight, no sheet).
    ///   • SINGLE tap empty space → clear the selection.
    private var taps: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { v in
                let p = geomPoint(v.location)
                if let id = engine.itemId(at: p) {
                    engine.select(id)
                    sheetItem = SheetItem(id: id)
                    // Lift the canvas so the event sits centered in the sheet-free top part
                    // (the medium detent covers the bottom half; aim its middle at ~22%).
                    if let r = engine.selectedBoxRect() {
                        let h = engine.viewport.h
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            canvasLift = min(max(r.midY - h * 0.22, 0), h * 0.6)
                        }
                    }
                } else if !engine.isDayLevel {
                    engine.navigate(at: p) // day level: nothing deeper to drill into
                }
            }
            .exclusively(before: SpatialTapGesture()
                .onEnded { v in
                    engine.select(engine.itemId(at: geomPoint(v.location)))
                })
    }

    /// Two-finger pinch = semantic zoom (year ⇄ month ⇄ week ⇄ day), the Mac trackpad pinch's
    /// touch twin: per-event magnification deltas feed the engine's REAL pinch path
    /// (`onMagnify`) — captureFocus anchors the target and seeds the zoom-out carries — and
    /// fingers-up snaps to the nearest level.
    /// `pinchPrev` turns SwiftUI's cumulative magnification into the per-event deltas the
    /// engine accumulates; the @GestureState reset (fires on END and CANCEL alike) closes the
    /// engine gesture, so a cancelled pinch can't strand z mid-zoom without its settle tween.
    @GestureState private var pinchActive = false
    @State private var pinchPrev: CGFloat?

    /// Finger-spread RATIO that crosses one zoom level: growing the spread 3× zooms exactly one
    /// level in; shrinking to a third zooms one out. Fed through `engine.pinchDelta`, which takes
    /// the LOG of the ratio — symmetric for in/out, unlike the raw linear deltas (doubling adds
    /// +1.0 but halving only −0.5, which made zoom-in feel twitchier than zoom-out could ever
    /// be). Fingers-up snaps past half a level, so the commit point is √3 ≈ 1.7× of travel.
    /// Lower = a level needs less travel; this is THE touch-sensitivity knob.
    private static let pinchLevelSpread: CGFloat = 3.0

    private var pinch: some Gesture {
        MagnifyGesture()
            .updating($pinchActive) { _, s, _ in s = true }
            .onChanged { v in
                let p = geomPoint(v.startLocation)
                if pinchPrev == nil {
                    engine.onMagnify(delta: 0, at: p, began: true, ended: false)
                    pinchPrev = 1
                }
                engine.onMagnify(delta: engine.pinchDelta(ratio: v.magnification / (pinchPrev ?? 1),
                                                          spreadPerLevel: Self.pinchLevelSpread),
                                 at: p, began: false, ended: false)
                pinchPrev = v.magnification
            }
    }

    /// View-space → geometry-space (the render layers draw offset by padLeft; the sheet-reveal
    /// lift shifts the canvas up, so gesture y compensates by +canvasLift).
    private func geomPoint(_ loc: CGPoint) -> CGPoint {
        CGPoint(x: loc.x - Layout.padLeft, y: loc.y + canvasLift)
    }

    // ── Chrome ───────────────────────────────────────────────────────────────────────

    /// Floating Liquid Glass toolbar (Music/Safari style, iOS 26): two capsules resting
    /// ABOVE the calendar canvas — Breadcrumb on the left; AI + Menu on the right. The
    /// canvas runs full-height beneath them. Menu opens the full-screen configuration view.
    private var bottomBar: some View {
        HStack {
            HStack(spacing: 0) {
                Breadcrumb(engine: engine)
            }
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            Spacer()
            HStack(spacing: 2) {
                Button { showAI = true } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Button { showMenu = true } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .offset(y: 8) // nudge into the home-indicator area a touch (visual, not layout)
    }

    // ── Scene ────────────────────────────────────────────────────────────────────────

    /// The Mac's calendarScene, reduced to the read-only layers (no marquee, no keyboard cursor
    /// rings, no drawer lift/blur, no dashboard driver).
    private func calendarScene(_ input: SceneInput, vp: Viewport, theme: Theme) -> some View {
        ZStack {
            // 1. scene below events — grid, washes, today, day labels
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                // CC_PROF=1: same keys as the Mac (CalendarView) so layers_ms and the
                // Instruments Points-of-Interest lanes read identically across platforms.
                RenderProf.measure("drawBelow", "1_drawBelow") {
                    SceneRenderer.drawBelow(input: input, in: &c, theme: theme)
                }
            }
            // 2. events (bands + timed) — perfMode on the phone: flat tinted fills instead of
            // Liquid Glass (a year of glass stickers is too costly on mobile GPU budgets).
            EventsOverlay(input: input, events: engine.viewEvents(), bands: engine.viewBands(),
                          bandBadges: engine.viewBandBadges(), eventBadges: engine.viewEventBadges(),
                          selected: engine.selectedId, hovered: nil,
                          drawerOpen: sheetItem != nil, editingId: nil,
                          perfMode: true,
                          editGen: engine.displayGen,
                          theme: theme)
                .offset(x: Layout.padLeft)
            // 3. deadlines: moment line + dots in the Canvas, labels as glass pills above it
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                RenderProf.measure("drawMid", "3_drawMid") {
                    SceneRenderer.drawMid(input: input, deadlines: engine.viewDeadlines(),
                                          selected: engine.selectedId, in: &c, theme: theme)
                }
            }
            DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(),
                             sides: engine.deadlineSides(),
                             selected: engine.selectedId, hovered: nil,
                             drawerOpen: false, theme: theme)
                .offset(x: Layout.padLeft)
            // 4. chrome on top of the glass: gutter labels/borders, track names, now-line
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                RenderProf.measure("drawAbove", "5_drawAbove") {
                    SceneRenderer.drawAbove(input: input, tracks: engine.items.trackNames, in: &c, theme: theme)
                }
            }
        }
        .opacity(input.flipFade) // whole-calendar fade during a year flip
    }
}
