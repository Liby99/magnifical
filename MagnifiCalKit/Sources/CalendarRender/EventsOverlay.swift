// Timed + band events as real SwiftUI views layered over the Canvas — each sticker
// is Liquid Glass (.glassEffect), so overlapping events are genuinely translucent
// and blur what's behind them (the native analogue of the web's translucent fill +
// backdrop-filter). Visual only; gestures are handled by the platform input layer
// (AppKit bridge on macOS, touch gestures on iOS).

import CalendarGeometry
import SwiftUI
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

public struct EventsOverlay: View {
    var input: SceneInput // var: the year layer cache renders a copy with the scroll-free input
    let events: [TimedEvent]
    var bands: [BandEvent] // var: per-month rigid layers render a month-sliced copy
    var bandBadges: [String: EventBadges] = [:] // provenance/kind markers per band box id
    var eventBadges: [String: EventBadges] = [:] // …and per timed-event box id
    var selected: String? // the PRIMARY selected BOX id (a ghost carries occKey); series-matched below
    var selectedIds: Set<String> = [] // the FULL multi-selection (each member gets a focus ring)
    var hovered: String? // the hovered BOX id (exact box gets hover feedback)
    let drawerOpen: Bool // the detail drawer is open → the focused box gets the thick border
    var editingId: String?
    var editingRect: CGRect? // the inline title editor's rect → hide the title on THAT segment only
    var draggingId: String? // event being moved/resized → floats full-width above the day,
    // and is excluded from the others' overlap packing (no reflow)
    var perfMode: Bool = false // flat tinted fills instead of Liquid Glass (global toggle)
    var monthLive = false // month gesture/turn in progress → pre-mount the neighbor months' stickers
    var editGen: UInt64 = 0 // data-edit generation (keys the cached per-month packing)
    var onlyBox: String? // when set, PACK everything as usual but DRAW only this box (the
    // sharp "lifted" copy above the drawer's blur scrim — see CalendarView)
    var hideBox: String? // …and the inverse: the blurred main render SKIPS this box (it's drawn
    // sharp by the lifted copy), so there's no blurry halo behind it
    var yearG0: SceneInput? // rest-year layer cache: the scroll-free input (see yearCacheInput);
    // non-nil → plain bands render in a record-once rigid canvas translated by -scrollY
    let theme: Theme

    public init(input: SceneInput, events: [TimedEvent], bands: [BandEvent],
                bandBadges: [String: EventBadges] = [:], eventBadges: [String: EventBadges] = [:],
                selected: String?, selectedIds: Set<String> = [], hovered: String?,
                drawerOpen: Bool, editingId: String?, editingRect: CGRect? = nil,
                draggingId: String? = nil, perfMode: Bool = false, monthLive: Bool = false,
                editGen: UInt64 = 0, onlyBox: String? = nil, hideBox: String? = nil,
                yearG0: SceneInput? = nil, theme: Theme) {
        self.input = input
        self.events = events
        self.bands = bands
        self.bandBadges = bandBadges
        self.eventBadges = eventBadges
        self.selected = selected
        self.selectedIds = selectedIds
        self.hovered = hovered
        self.drawerOpen = drawerOpen
        self.editingId = editingId
        self.editingRect = editingRect
        self.draggingId = draggingId
        self.perfMode = perfMode
        self.monthLive = monthLive
        self.editGen = editGen
        self.onlyBox = onlyBox
        self.hideBox = hideBox
        self.yearG0 = yearG0
        self.theme = theme
    }

    public static let spilloverDim: CGFloat = 0.45 // opacity of neighbor-month (spillover-day) events

    /// Below this zoom (year view) all 12 months are on screen at once, so EVERY band in the year is a
    /// live sticker — up to ~145 of them. Liquid Glass there is one backdrop-blur pass per sticker, which
    /// the profiler showed drops the year-scroll fling from ~120fps to ~80fps (main thread ~65% busy
    /// building glass descriptors + laying out the stickers, the rest blocked on GPU compositing) with NO
    /// change to the Canvas layers. Flat fills render the same 145 bands at a full 120fps, so force the
    /// cheap path in year view regardless of the Performance-Mode preference. Glass returns at month zoom,
    /// where off-screen months are culled and only a handful of bars are live. Rest (year) ≈ z<0.5; the 0.6
    /// cutoff also covers the first sliver of the year→month zoom, before culling thins the sticker count.
    static let glassZoomFloor: CGFloat = 0.6
    private var plainEff: Bool {
        perfMode || input.z < Self.glassZoomFloor
    }

    /// Canvas fast path (see CanvasStickers.swift): at year/month zoom, PLAIN flat stickers draw in one
    /// Canvas instead of being SwiftUI views — the flamegraph put ~66% of swipe frame time in the view
    /// graph's per-sticker layout/diffing. Views remain for: active stickers (hover/selection/editing —
    /// glass, borders, animations), week/day zoom (rich text, few boxes), and the lifted-copy overlay
    /// (onlyBox). CC_CANVAS_OFF=1 disables the fast path for A/B benchmarking.
    private static let canvasKill = ProcessInfo.processInfo.environment["CC_CANVAS_OFF"] != nil

    /// A zoom/scroll transition is in flight: mid-pinch (fractional z) or any settle tween. While
    /// true, plain stickers stay CANVAS-drawn at EVERY zoom (including week/day, with text) so the
    /// view-mount storm lands on the settled frame instead of mid-gesture — with the dense payload
    /// (3000 events) that storm was 10 hitches of ≤66.7ms per pinch cycle. On settle this flips
    /// false and the views mount on a static frame (the neighbor pre-mount trick, generalized).
    /// CC_ZOOMCANVAS_OFF=1 restores the settled-zoom-only fast path for same-binary A/B.
    private static let zoomCanvasKill = ProcessInfo.processInfo.environment["CC_ZOOMCANVAS_OFF"] != nil
    private var zoomTransient: Bool {
        !Self.zoomCanvasKill && (input.animating || input.z != input.z.rounded())
    }

    private var canvasFastOn: Bool {
        plainEff && onlyBox == nil && !Self.canvasKill && (input.z < 1.5 || zoomTransient)
    }

    /// CC_EDGEIND_OFF=1 disables the viewport-overflow edge indicators (scrolled-off events'
    /// pinned slivers) for same-binary A/B benchmarking, restoring the plain edge cull.
    private static let edgeIndKill = ProcessInfo.processInfo.environment["CC_EDGEIND_OFF"] != nil

    /// A box belongs to the clicked event's series (same source: recurrence occurrence / promoted
    /// bar / original), so it shares the accompanied style.
    /// The activation level for a box (see EventActivation). Only the EXACT selected box is focused
    /// (single click) or selected (drawer open) — each box is independent, so siblings/source are NOT
    /// accompanied. An unrelated box under the pointer is hover; everything else is plain.
    private func activation(_ id: String) -> EventActivation {
        // Multi-select: every member gets a focus ring. A lone selection with the drawer open gets the
        // thick "selected" border. (The lifted-copy overlay passes only `selected` — the id check keeps it.)
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

    /// True when this box is the one the inline title editor sits over. `editingRect` is a specific
    /// segment's rect (same coord space as the box rects); nil means match by id alone (e.g. a band).
    private static func editingThisBox(_ boxRect: CGRect, _ editingRect: CGRect?) -> Bool {
        guard let e = editingRect else { return true }
        return abs(boxRect.minX - e.minX) < 2 && abs(boxRect.minY - e.minY) < 2
    }

    /// One mounted timed-sticker layer: its items + clip rect, with a stable ForEach key.
    private struct TimedLayer: Identifiable {
        let id: String; let items: [Item2]; let clip: CGRect
    }

    /// The mounted timed layers this frame: the focus month, plus (at month rest / mid-turn) the
    /// pre-mounted neighbor months. Extracted from `body` so the Canvas fast path and the view
    /// stickers iterate the SAME layer list (identical clips, fades, and pre-mount policy).
    ///
    /// Neighbor months' stickers are mounted the whole time month view is AT REST (plus any
    /// in-flight turn): creating a dense month's sticker views is a measured ~50ms hitch,
    /// and doing it lazily put that hitch INSIDE the page-turn animation (bench-month-swipe:
    /// p95 16.7ms, 6-8 hitches; with pre-mounted neighbors p95 8.3ms). Mounted at arrival,
    /// the churn lands on the settled frame — where a slow frame is invisible — and every
    /// swipe finds both neighbors ready. The z-window keeps the mount off the animated
    /// zoom-in (it lands once the zoom settles); non-matching neighbors sit at progress 0
    /// (one page off-screen) with fade 0.
    private func timedLayers(_ anim: PageAnim?, _ tlOut: TimelineInfo, _ outMul: CGFloat,
                             _ clipRight: CGFloat) -> [TimedLayer] {
        var layers: [TimedLayer] = []
        if tlOut.reveal > 0.05 && tlOut.hourH > 0 {
            layers.append(TimedLayer(id: "out",
                                     items: timedItems(tlOut, focus: input.focus, fadeMul: outMul),
                                     clip: tlClip(tlOut, clipRight)))
        }
        if abs(input.z - 1) < 0.01 || anim != nil || monthLive {
            for m in [input.focus - 1, input.focus + 1] where m >= 0 && m <= 11 {
                let dir = m > input.focus ? 1 : -1
                let matching = anim?.dir == dir
                let p: CGFloat = matching ? (anim?.p ?? 0) : 0
                let tlIn = timelineInfo(input, focus: m, anim: PageAnim(dir: dir, p: p))
                if tlIn.reveal > 0.05 && tlIn.hourH > 0 {
                    layers.append(TimedLayer(
                        id: "n\(m)",
                        items: timedItems(tlIn, focus: m, fadeMul: matching ? incomingDetailReveal(p) : 0,
                                          keyTag: "~n\(m)"),
                        clip: tlClip(tlIn, clipRight)
                    ))
                }
            }
        }
        return layers
    }

    public var body: some View {
        let anim = input.monthAnim
        // Outgoing (current) month — slides + fades out during a page-turn (anim==nil → resting, mul 1).
        let tlOut = timelineInfo(input, anim: anim)
        let outMul = anim.map { outgoingDetailReveal($0.p) } ?? 1
        let clipRight = dashboardLeftAnimated(input) // day-view dashboard mask (slides in from the right)
        let bandClip = CGRect(x: Layout.labelW, y: 0, width: max(0, clipRight - Layout.labelW), height: input.vp.h)
        let bandAll = bandItems()
        let layers = timedLayers(anim, tlOut, outMul, clipRight)

        ZStack(alignment: .topLeading) {
            // Rest-year layer cache: plain bands render into rigid canvases that CoreAnimation
            // translates by -scrollY — no per-frame re-record. PER-MONTH granularity: hovering a
            // band (or editing one) invalidates only ITS month's small layer (~40 bands, ~0.4ms),
            // not the whole year — with the dense payload (496 bands) the whole-year layer cost
            // 4.6ms per hover change and produced 50ms re-record bursts during flings. Year-zoom
            // band packing is per-(month,track) lane, so a copy holding one month's bands packs
            // identically. CC_BANDGRAIN_OFF=1 restores the single whole-year layer for A/B.
            if let g0 = yearG0 {
                Color.clear.overlay(alignment: .top) {
                    ZStack(alignment: .topLeading) {
                        if Self.bandGrainKill {
                            rigidBandsView(g0)
                        } else {
                            ForEach(0 ..< 12, id: \.self) { m in
                                rigidMonthBandsView(g0, month: m)
                            }
                        }
                    }
                    .offset(y: -input.scrollY)
                }
            }
            // Canvas fast path: ALL plain flat stickers in ONE canvas (bands, then each timed layer,
            // each clipped to its own region — same clips as the view layers below). Sits under the
            // view stickers; active stickers (z ≥ 950) always render above plain ones anyway.
            // Under the year layer cache the bands are in the rigid canvas instead (timed layers are
            // empty at year zoom — the timeline isn't revealed).
            Canvas { ctx, _ in
                RenderProf.measure("stickerCanvas", "2b_stickerCanvas") {
                    if yearG0 == nil {
                        var b = ctx
                        b.clip(to: Path(bandClip))
                        StickerCanvas.draw(canvasList(bandAll), in: &b, theme: theme)
                    }
                    for l in layers {
                        var t = ctx
                        t.clip(to: Path(l.clip))
                        StickerCanvas.draw(canvasList(l.items), in: &t, theme: theme)
                    }
                }
            }
            stickers(bandAll).clipShape(RectClip(rect: bandClip))
            ForEach(layers) { l in
                stickers(l.items).clipShape(RectClip(rect: l.clip))
            }
            // Year-view weekday marker ("Thu") floating above the hovered day — a small
            // Liquid Glass capsule, centered on the day column.
            if let wm = weekdayMarker() {
                Text(wm.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .glassEffectCompat(.regular, in: .capsule)
                    .fixedSize()
                    .position(wm.center)
            }
            // NOTE: the CURRENT TIME pill + cursor time tag used to render here, but the gutter
            // chrome (hour labels, borders, the now-line) draws in a LATER Canvas — the labels sat
            // crisp on top of the glass. They now live in TimeTagsOverlay, mounted ABOVE the chrome
            // (see calendarScene), so the glass genuinely frosts the hour labels beneath.
        }
        .allowsHitTesting(false)
    }
}

/// The CURRENT TIME pill + the cursor time tag, in their own layer ABOVE the chrome Canvas
/// (which draws the gutter hour labels, borders, and the now/cursor lines themselves). Layered
/// there, the pills' frosted glass blurs the hour labels under them — in day view the tags hug
/// the left gutter and used to collide with "10:00"-style labels drawn crisp on top.
public struct TimeTagsOverlay: View {
    let input: SceneInput
    let theme: Theme

    public init(input: SceneInput, theme: Theme) {
        self.input = input
        self.theme = theme
    }

    public var body: some View {
        // Clip to the content region (right edge = the dashboard's animated left edge): the SwiftUI
        // glass pill would otherwise composite ABOVE the dashboard WebView — unlike the Canvas
        // now-line, which is clipped there — so in week view a right-side day's label leaked over
        // the panel while the line sat under it. Clipping here keeps the two layered the same.
        let clipRight = dashboardLeftAnimated(input)
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(nowLabelSpecs(input)) { spec in
                    nowLabelView(spec)
                }
            }
            .clipShape(RectClip(rect: CGRect(
                x: -Layout.labelW,
                y: 0,
                width: clipRight + Layout.labelW,
                height: input.vp.h
            )))
            // Mouse-cursor time tag: SwiftUI (not Canvas) so it isn't clipped at the gutter and its
            // side animates smoothly on a flip (e.g. the week↔day transition) instead of jumping.
            if let tag = cursorTagSpec(input) {
                cursorTagView(tag)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func cursorTagView(_ spec: CursorTagSpec) -> some View {
        let c = theme.cursor
        let shape = RoundedRectangle(cornerRadius: 5)
        // Frosted glass like the CURRENT TIME pill: a translucent base so the frost reads clean,
        // glass tinted with the cursor color (strong in dark mode, faint in light).
        let baseFill: Color = (theme.dark ? Color.black : Color.white).opacity(theme.dark ? 0.55 : 0.62)
        let glassTint = c.opacity(theme.dark ? 0.5 : 0.14)
        // Lines hug the caret (line-facing) side, like the CURRENT TIME pill: tag left of the
        // column → trailing-aligned, tag right of the column → leading-aligned.
        VStack(alignment: spec.pointsRight ? .trailing : .leading, spacing: -1) {
            // fixedSize: the time must NEVER ellipsize — if a metric ever exceeds the pill's
            // absolute width (Scene.swift TW), the text wins and the pill is what's undersized.
            Text(spec.text)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(c)
                .fixedSize()
            if let alt = spec.altText { // alt-tz wall clock, e.g. "13:45 (PST) [+1 day]"
                Text(alt)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(c.opacity(0.75))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .frame(width: spec.rect.width, height: spec.rect.height,
               alignment: spec.pointsRight ? .trailing : .leading)
        .background(shape.fill(baseFill))
        .glassEffectCompat(.regular.tint(glassTint), in: shape)
        .overlay(shape.strokeBorder(c, lineWidth: 1))
        // Caret on the line-facing edge; on a side flip the old one retracts and the new one grows.
        .overlay { flipCaret(pointsRight: true, shown: spec.pointsRight, color: c, h: 8) }
        .overlay { flipCaret(pointsRight: false, shown: !spec.pointsRight, color: c, h: 8) }
        .opacity(spec.opacity)
        .position(x: spec.rect.midX, y: spec.rect.midY)
        .animation(.easeInOut(duration: 0.2), value: spec.pointsRight) // slide + caret-swap on flip
        .allowsHitTesting(false)
    }

    /// A caret on one edge that grows in / retracts out as `shown` toggles — so a left↔right flip
    /// reads as one caret sliding out while the other slides in, instead of instantly swapping sides.
    private func flipCaret(pointsRight: Bool, shown: Bool, color: Color, h: CGFloat) -> some View {
        Caret(pointsRight: pointsRight).fill(color)
            .frame(width: 5, height: h)
            .scaleEffect(x: shown ? 1 : 0, anchor: pointsRight ? .leading : .trailing) // grow/retract at the edge
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointsRight ? .trailing : .leading)
            .offset(x: pointsRight ? 5 : -5)
            .opacity(shown ? 1 : 0)
    }

    @ViewBuilder private func nowLabelView(_ spec: NowLabelSpec) -> some View {
        let red = theme.nowLine
        let shape = RoundedRectangle(cornerRadius: 10) // match the deadline pill's radius
        // Dark mode: dark base + strong red glass, white label. Light mode: a bright frosted
        // base with only a faint red tint, and a dark label — the time stays red in both.
        let labelColor: Color = theme.dark ? .white.opacity(0.7) : theme.text.opacity(0.7)
        let baseFill: Color = (theme.dark ? Color.black : Color.white).opacity(theme.dark ? 0.55 : 0.62)
        let glassTint = red.opacity(theme.dark ? 0.5 : 0.14)
        VStack(alignment: spec.pointsRight ? .trailing : .leading, spacing: -1) {
            Text("CURRENT TIME").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(labelColor)
            Text(spec.text).font(.system(size: 13, weight: .bold)).foregroundStyle(red) // time in the accent color
            if let alt = spec.altText { // alt-tz wall clock, e.g. "13:45 (PST)"
                Text(alt).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(labelColor).padding(.top, 1.5)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3) // match the deadline pill's padding
        .frame(width: spec.rect.width, height: spec.rect.height, alignment: spec.pointsRight ? .trailing : .leading)
        .background(shape.fill(baseFill)) // solid base so the frost reads clean
        .glassEffectCompat(.regular.tint(glassTint), in: shape)
        .overlay(shape.strokeBorder(red, lineWidth: 1)) // fully wrapped border
        // Caret on the line-facing edge; on a side flip (e.g. week↔day) the old one retracts and the
        // new one grows, so the label slides across smoothly instead of jumping.
        .overlay { flipCaret(pointsRight: true, shown: spec.pointsRight, color: red, h: 9) }
        .overlay { flipCaret(pointsRight: false, shown: !spec.pointsRight, color: red, h: 9) }
        .opacity(spec.opacity)
        .position(x: spec.rect.midX, y: spec.rect.midY + 1) // nudge the whole label + caret down 1px
        .animation(.easeInOut(duration: 0.2), value: spec.pointsRight) // slide + caret-swap on flip
        .allowsHitTesting(false)
    }
}

extension EventsOverlay {
    /// Clip a timeline layer to its own (possibly sliding) day-detail region.
    private func tlClip(_ tl: TimelineInfo, _ clipRight: CGFloat) -> CGRect {
        CGRect(x: Layout.labelW, y: tl.tlTop, width: max(0, clipRight - Layout.labelW),
               height: max(0, tl.tlBottom - tl.tlTop))
    }

    /// The floating weekday chip for year-view day hover. Mirrors buildHover's `dayOn`:
    /// year zoom, a hovered month on screen, and a valid day-of-month.
    private func weekdayMarker() -> (center: CGPoint, text: String)? {
        guard input.z < 0.5, let m = input.hover.month, let dom = input.hover.dom else { return nil }
        guard dom >= 1 && dom <= daysInMonth(input.year, m) else { return nil }
        let f = frameFor(m, input)
        guard f.bandY <= input.vp.h + 20, f.bandY + 4 * f.trackH >= -20 else { return nil } // on screen
        let cx = f.x0 + (CGFloat(dom) - 0.5) * f.dayW // center of the day column
        let cy = f.bandY - 15 // floated above the band top
        return (CGPoint(x: cx, y: cy), WD3[dayOfWeek(input.year, m, dom)])
    }

    private struct Item2: Identifiable {
        let id: String; let rect: CGRect; let fade: Double; let z: Double
        /// Lazily-built view sticker — only called for items the Canvas fast path doesn't take
        /// (so canvased items never pay AnyView construction).
        let makeView: () -> AnyView
        /// Non-nil → this item is flat/plain and the Canvas fast path draws it instead of `makeView`.
        var canvas: StickerDraw?
    }

    /// The Canvas fast path's draw list for one clip group (bands, or one timed layer): the items that
    /// carry a flat payload, minus the hideBox filter the view path also applies.
    private func canvasList(_ items: [Item2]) -> [CanvasSticker] {
        drawn(items).compactMap { it in
            it.canvas.map { CanvasSticker(rect: it.rect, fade: it.fade, z: it.z, draw: $0) }
        }
    }

    /// Does an item belong to the selected/hidden event `box`? Bands use the plain event id; a TIMED event
    /// uses a per-segment key ("id#MMDD", plus a "~in" transition twin), so a plain `== box` misses it —
    /// which left timed events neither skipped from the blur (`hideBox`) nor drawn in the lifted-above-scrim
    /// copy (`onlyBox`), so they no longer floated above the drawer scrim. Match the segment prefix too (this
    /// also lifts BOTH halves of a cross-midnight event, and every segment of a recurring band, together).
    private func matches(_ itemId: String, _ box: String) -> Bool {
        itemId == box || itemId == box + "~in" || itemId.hasPrefix(box + "#")
    }

    private func drawn(_ items: [Item2]) -> [Item2] {
        if let box = onlyBox {
            return items.filter { matches($0.id, box) }
        }
        if let box = hideBox {
            return items.filter { !matches($0.id, box) }
        }
        return items
    }

    private func stickers(_ items: [Item2]) -> some View {
        ZStack(alignment: .topLeading) {
            // Stable identity (event id) so a z-order re-sort keeps the view alive and its
            // hover/select transitions can animate rather than snapping. Draw order is the
            // explicit per-item z (band: 10+startDay baseline, raised on hover/select).
            // Items with a canvas payload are drawn by the Canvas fast path — only the rest mount views.
            ForEach(drawn(items).filter { $0.canvas == nil }) { it in
                it.makeView()
                    .frame(width: it.rect.width, height: it.rect.height)
                    .position(x: it.rect.midX, y: it.rect.midY)
                    .opacity(it.fade)
                    .zIndex(it.z)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A rect is worth rendering only if it (nearly) intersects the viewport. Culls the ~11
    /// months that sit off-screen in month view, and anything scrolled out of view elsewhere —
    /// each survivor is a real Liquid Glass sticker, so skipping them is the big per-frame win.
    private func onScreen(_ rect: CGRect) -> Bool {
        let M: CGFloat = 40
        return rect.maxY > -M && rect.minY < input.vp.h + M && rect.maxX > -M && rect.minX < input.vp.w + M
    }

    private func bandItems() -> [Item2] {
        RenderProf.measure("bandItems", "2a_bandItems") { bandItemsUncached() }
    }

    private func bandItemsUncached() -> [Item2] {
        var placed: [(ev: BandEvent, rect: CGRect, fade: Double, clipStart: Bool, clipEnd: Bool)] = []
        let weekish = input.z >= 1.5
        for b in bands {
            // Month/year layout positions a band by its month alone (frameFor(b.month)), so a
            // neighbor-year band would land in the CURRENT year's same-month row. Only the week/day
            // (weekish) path is year-safe (bandEventRect gates via relDomOf), so skip cross-year
            // bands outside it — they show only as week-view boundary spillover.
            if !weekish && b.year != input.year {
                continue
            }
            guard let r = bandEventRect(b, input, anim: input.monthAnim) else { continue }
            // Opacity comes from the FOCUS frame in week/day view (the adjacent month's own frame is
            // off-screen there); a neighbor-month band shown in the spillover columns is dimmed.
            let f = frameFor(weekish ? input.focus : b.month, input, anim: input.monthAnim)
            let spill: Double = weekish ? Double(spillFactor(b.month, input, dim: Self.spilloverDim)) : 1
            let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            guard f.opacity > 0.004, onScreen(rect) else { continue } // skip invisible / off-screen months
            placed.append((b, rect, Double(f.opacity) * spill, r.clipStart, r.clipEnd))
        }
        // Fully-overlapping (same month/track/startDay/endDay): collapse to ONE (highest id),
        // hide the rest, and flag the kept one with a warning sign.
        var hidden = Set<String>(), warn = Set<String>()
        var full: [String: [Int]] = [:]
        for (i, p) in placed.enumerated() {
            full[
                "\(p.ev.month)-\(p.ev.track)-\(p.ev.startDay)-\(p.ev.endDay)",
                default: []
            ].append(i)
        }
        for (_, idxs) in full where idxs.count > 1 {
            let keep = idxs.max { placed[$0].ev.id < placed[$1].ev.id }!
            warn.insert(placed[keep].ev.id)
            for i in idxs where i != keep {
                hidden.insert(placed[i].ev.id)
            }
        }
        // Per lane (visible bars): gap = px to the nearest LATER-starting bar (title clips
        // before it; unbounded if none). Same-start stacks: shorter on top (z), longer
        // simply behind — its title runs full and is covered by the shorter bar.
        var gapBy: [String: CGFloat] = [:]
        var zBy: [String: Double] = [:]
        var clipBox = Set<String>() // non-longest same-start bars clip to their own box
        var byLane: [String: [Int]] = [:]
        // Week view shows both months on the same 4 lanes, so group by track alone — a spillover
        // (neighbor-month) bar must "see" the focus bars on its lane so its title clips before them.
        for (i, p) in placed.enumerated() where !hidden.contains(p.ev.id) {
            byLane[weekish ? "\(p.ev.track)" : "\(p.ev.month)-\(p.ev.track)", default: []].append(i)
        }
        for (_, idxs) in byLane {
            for i in idxs {
                // Compare by rendered X (startDay isn't comparable across months in the shared lane).
                let later = idxs.filter { placed[$0].rect.minX > placed[i].rect.minX + 1 }
                if let nearest = later.min(by: { placed[$0].rect.minX < placed[$1].rect.minX }) {
                    gapBy[placed[i].ev.id] = placed[nearest].rect.minX - placed[i].rect.minX
                }
            }
            var byDay: [Int: [Int]] = [:]
            for i in idxs {
                byDay[placed[i].ev.startDay, default: []].append(i)
            }
            for (start, stackIdxs) in byDay where stackIdxs.count >= 2 {
                func len(_ i: Int) -> Int {
                    placed[i].ev.endDay - placed[i].ev.startDay
                }
                let stack = stackIdxs.sorted { len($0) > len($1) } // longest first (bottom)
                for si in stack.indices {
                    zBy[placed[stack[si]].ev.id] = Double(10 + start + si * 2) // shorter → higher → on top
                    if si > 0 {
                        clipBox.insert(placed[stack[si]].ev.id)
                    } // all but the longest
                }
            }
        }
        // Hover promotion: bars the hovered band overlaps (same-start stacks) become glass views
        // too (forceGlass), so the hovered glass frosts real content — the glass-on-glass overlap
        // look of the pre-Performance-Mode rendering, paid only under the pointer.
        let hoverRects = hovered.map { h in placed.filter { $0.ev.id == h }.map(\.rect) } ?? []
        return placed.compactMap { p in
            let id = p.ev.id
            if hidden.contains(id) {
                return nil
            }
            let a = activation(id)
            let z: Double = a.isActive ? a.z : (zBy[id] ?? Double(10 + p.ev.startDay))
            let isEditing = id == editingId
            let promoted = a == .plain && hoverRects.contains { $0.intersects(p.rect) }
            // Plain + not-editing at year/month zoom → the Canvas fast path draws it (flat payload);
            // active/editing/hover-overlapped bands stay views (glass, borders, spill scrim, editor).
            let fast: StickerDraw? = (canvasFastOn && a == .plain && !isEditing && !promoted)
                ? .band(BandDraw(ev: p.ev, gap: gapBy[id], clipBox: clipBox.contains(id),
                                 clipStart: p.clipStart, clipEnd: p.clipEnd,
                                 warn: warn.contains(id), badges: bandBadges[id] ?? []))
                : nil
            let (gap, cb, warned, badges, plain) =
                (gapBy[id], clipBox.contains(id), warn.contains(id), bandBadges[id] ?? [], plainEff)
            return Item2(id: id, rect: p.rect, fade: p.fade, z: z, makeView: {
                AnyView(BandSticker(ev: p.ev, activation: a, editing: isEditing,
                                    gap: gap, clipBox: cb,
                                    clipStart: p.clipStart, clipEnd: p.clipEnd,
                                    warn: warned, box: p.rect.size,
                                    badges: badges,
                                    plain: plain, forceGlass: promoted,
                                    theme: theme))
            }, canvas: fast)
        }
    }

    /// Timed stickers for one month `focus`, placed against its timeline `tl`. `fadeMul` scales
    /// the whole layer (a page-turn fades the outgoing set out / incoming set in); `keyTag` keeps
    /// the incoming set's ForEach ids distinct from the outgoing set's during the cross-fade.
    private func timedItems(_ tl: TimelineInfo, focus: Int, fadeMul: CGFloat = 1, keyTag: String = "") -> [Item2] {
        // `subLabels` carries the anchor-zone time (e.g. "12:00 – 14:00 (PST)") for events whose anchor
        // differs from the view zone. Cached: anchorRangeLabel does real timezone math, and it ran for
        // EVERY event on EVERY frame (×3 with neighbor months mounted) — hot in the swipe profile.
        var subLabels: [String: String] = [:]
        for e in events {
            let key = SubLabelKey(id: e.id, start: e.startHour, end: e.endHour,
                                  anchorTz: e.anchorTz ?? "", mainTz: input.mainTz)
            let lbl: String?
            if let hit = subLabelCache[key] {
                lbl = hit
            } else {
                lbl = anchorRangeLabel(e, mainTz: input.mainTz)
                if subLabelCache.count > 2048 {
                    subLabelCache.removeAll(keepingCapacity: true)
                }
                subLabelCache[key] = lbl
            }
            if let lbl {
                subLabels[e.id] = lbl
            }
        }
        // Segment grouping + per-day overlap packing, cached per (year, focus, editGen, dragging):
        // none of it depends on the per-frame timeline geometry (see timedLayoutCache).
        let layoutKey = TimedLayoutKey(year: input.year, focus: focus, editGen: editGen, dragging: draggingId)
        let days: [TimedDayLayout]
        if let hit = timedLayoutCache[layoutKey] {
            days = hit
        } else {
            // `relDomOf` gates adjacency (returns nil for non-neighbor months), so iterating all years
            // lets Dec↔Jan spillover events cross the year boundary while far-off months are excluded.
            // A cross-midnight event splits into per-day segments; each lands in its own day column.
            var byDay: [Int: [TimedSegment]] = [:]
            for e in events {
                for s in timedSegments(e) {
                    if let rd = relDomOf(input.year, focus, s.event.year, s.event.month, s.event.day) {
                        byDay[rd, default: []].append(s)
                    }
                }
            }
            // Pack the OTHER events as if the dragged one weren't in this day, so they don't shrink/
            // reflow mid-edit; the dragged event then gets no layout slot → eventRect renders it
            // full-width, and it draws on top (selected → frontmost z). Committed on drop.
            days = byDay.map { rd, segs in
                let evs = segs.map(\.event)
                return TimedDayLayout(rd: rd, segs: segs,
                                      layout: layoutDay(draggingId != nil ? evs.filter { $0.id != draggingId } : evs))
            }
            if timedLayoutCache.count > 64 {
                timedLayoutCache.removeAll(keepingCapacity: true)
            }
            timedLayoutCache[layoutKey] = days
        }
        var gf = input; gf.focus = focus
        let dim = daysInMonth(input.year, focus)
        var placed: [(seg: TimedSegment, rect: CGRect, fade: Double)] = []
        // Segments scrolled fully past the timeline's top/bottom edge become PINNED edge-indicator
        // slivers instead of being culled (see dayEdgeIndicators — the whole clamp/stack layout is
        // a pure per-frame function of these same rects). Collected per day, appended after the
        // normal items: they draw above plain stickers but below active ones.
        var pinned: [(seg: TimedSegment, rect: CGRect, fade: Double, rank: Int, top: Bool)] = []
        var segRects: [(seg: TimedSegment, rect: CGRect)] = [] // reused per day (no per-day realloc)
        for day in days {
            let rd = day.rd
            // Spillover day (belongs to the previous/next month) → drawn dimmed but fully interactive;
            // a month-edge flip cross-fades the dim/bright swap. (rd<1 → prev month, rd>dim → next.)
            let evMonth = rd < 1 ? focus - 1 : (rd > dim ? focus + 1 : focus)
            let spill = (input.z >= 1.5) ? spillFactor((evMonth + 12) % 12, gf, dim: Self.spilloverDim) : 1
            let fade = dailyFade(rd, gf) * tl.reveal * fadeMul * spill
            if fade <= 0.02 {
                continue
            }
            segRects.removeAll(keepingCapacity: true)
            for s in day.segs {
                guard let r = eventRect(s.event, input.year, focus, tl, input.vp, day.layout[s.event.id])
                else { continue }
                let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                if rect.maxX < -40 || rect.minX > input.vp.w + 40 {
                    continue
                } // scrolled off horizontally (week/day)
                segRects.append((s, rect))
            }
            if segRects.isEmpty {
                continue
            }
            let colX = tl.x0 + (CGFloat(rd) - 1) * tl.colW
            let ind = Self.edgeIndKill ? DayEdgeIndicators()
                : dayEdgeIndicators(rects: segRects.map(\.rect), tlTop: tl.tlTop, tlBottom: tl.tlBottom,
                                    colX: colX, colW: tl.colW)
            for (i, sr) in segRects.enumerated() {
                if !ind.isIndicator.isEmpty && ind.isIndicator[i] {
                    continue
                } // clamped at an edge → rendered from ind.top/.bottom below
                if sr.rect.maxY < tl.tlTop || sr.rect.minY > tl.tlBottom {
                    continue
                } // outside the timeline band
                placed.append((sr.seg, sr.rect, Double(fade)))
            }
            for e in ind.top {
                pinned.append((segRects[e.index].seg, e.rect, Double(fade * e.opacity), e.rank, true))
            }
            for e in ind.bottom {
                pinned.append((segRects[e.index].seg, e.rect, Double(fade * e.opacity), e.rank, false))
            }
        }
        placed.sort(by: orderTimed)
        // APPEARANCE comes from the live per-frame `events` (which carries the engine's post-cache
        // overlays, e.g. the swatch hover color-preview); only GEOMETRY is served from the layout
        // cache. The cached segment copies bake the event values at cache-build time, so drawing
        // them directly ate any transient styling that (by design) doesn't bump editGen.
        let freshById = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Hover promotion (see bandItems): boxes the hovered event's segments overlap render as
        // glass views (forceGlass) so its glass frosts them — glass-on-glass, hover-only cost.
        let hoverRects = hovered.map { h in placed.filter { $0.seg.event.id == h }.map(\.rect) } ?? []
        var out: [Item2] = placed.enumerated().map { i, p in
            let id = p.seg.event.id
            let a = activation(id)
            let z: Double = a.isActive ? a.z : Double(i)
            var ev = p.seg.event // segment-shaped copy (per-day split hours) — keep its geometry fields
            if let fresh = freshById[id] {
                ev.color = fresh.color; ev.title = fresh.title
            }
            // The Item2 id must be unique per SEGMENT (a split event draws twice), but activation/badges
            // stay keyed by the shared event id → selecting highlights every segment at once.
            let segKey = "\(id)#\(p.seg.event.month * 100 + p.seg.event.day)"
            let showText = input.z >= 1.5
            // Hide the title ONLY on the segment the editor is over (rect match) — the other
            // segments of a cross-midnight event keep showing the title (which updates live as
            // you type), instead of going blank.
            let isEditing = editingId != nil && sourceId(of: id) == editingId && Self.editingThisBox(
                p.rect,
                editingRect
            )
            let badges = eventBadges[id] ?? []
            let (timeText, subText, plain) =
                (fmtHourRange(p.seg.fullStart, p.seg.fullEnd), subLabels[id], plainEff)
            let promoted = a == .plain && hoverRects.contains { $0.intersects(p.rect) }
            // Plain + not-editing/dragging → the Canvas fast path draws it. Text rendering
            // (week/day zoom) is canvas-drawn ONLY mid-transition (zoomTransient); at settled
            // week/day the rich SwiftUI text path owns it (canvasFastOn is false past z 1.5).
            let fast: StickerDraw? = (canvasFastOn && a == .plain && !isEditing && id != draggingId
                && !promoted && (!showText || zoomTransient))
                ? .timed(TimedDraw(ev: ev, clipTop: p.seg.clipTop, clipBottom: p.seg.clipBottom,
                                   badges: badges, showText: showText,
                                   timeText: timeText, subTimeText: subText))
                : nil
            return Item2(id: segKey + keyTag, rect: p.rect, fade: p.fade, z: z, makeView: {
                AnyView(EventSticker(ev: ev, height: p.rect.height, showText: showText,
                                     clipTop: p.seg.clipTop, clipBottom: p.seg.clipBottom,
                                     timeText: timeText,
                                     subTimeText: subText,
                                     plain: plain, forceGlass: promoted,
                                     activation: a, badges: badges,
                                     editing: isEditing,
                                     theme: theme))
            }, canvas: fast)
        }
        // Edge-indicator slivers: the event's color only — no text, no accent bar, no activation
        // (never hovered/selected; clicks are handled by the engine's edgeIndicatorTarget hit-test,
        // not these visuals). The "id#MMDD" prefix keeps onlyBox/hideBox segment matching intact.
        for pn in pinned {
            let id = pn.seg.event.id
            let colorKey = freshById[id]?.color ?? pn.seg.event.color
            let hidden = (eventBadges[id] ?? []).contains(.hidden)
            let key = "\(id)#\(pn.seg.event.month * 100 + pn.seg.event.day)!\(pn.top ? "t" : "b")" + keyTag
            let z = 930 - Double(pn.rank) // above plain stickers, below active (950+); innermost on top
            let onTop = pn.top
            let fast: StickerDraw? = canvasFastOn
                ? .edgeIndicator(EdgeIndicatorDraw(colorKey: colorKey, hidden: hidden, top: onTop))
                : nil
            let cardH = pn.rect.height
            out.append(Item2(id: key, rect: pn.rect, fade: pn.fade, z: z, makeView: { [theme] in
                AnyView(EdgeIndicatorSticker(colorKey: colorKey, hidden: hidden,
                                             top: onTop, height: cardH, theme: theme))
            }, canvas: fast))
        }
        return out
    }

    private static let bandGrainKill = ProcessInfo.processInfo.environment["CC_BANDGRAIN_OFF"] != nil

    /// One MONTH's rigid band canvas: a small equatable layer spanning just the month's band strip
    /// (4 tracks), holding only that month's bands — so its == key (bands slice + month-filtered
    /// activation ids) changes only when THIS month changes. Year-zoom packing is per-lane, so the
    /// month-sliced copy packs identically to the whole-year pass.
    private func rigidMonthBandsView(_ g0: SceneInput, month m: Int) -> some View {
        var copy = self
        copy.input = g0
        copy.yearG0 = nil
        let monthBands = bands.filter { $0.year == g0.year && $0.month == m }
        let ids = Set(monthBands.map(\.id))
        copy.bands = monthBands
        copy.bandBadges = bandBadges.filter { ids.contains($0.key) }
        copy.hovered = hovered.flatMap { ids.contains($0) ? $0 : nil }
        copy.selected = selected.flatMap { ids.contains($0) ? $0 : nil }
        copy.selectedIds = selectedIds.intersection(ids)
        copy.editingId = editingId.flatMap { ids.contains($0) ? $0 : nil }
        // The month's band strip in content space (g0: scrollY = 0), padded 4px for AA overflow.
        let f = frameFor(m, g0)
        let pad: CGFloat = 4
        let y0 = f.bandY - pad
        let h = 4 * f.trackH + 2 * pad
        return YearMonthBandsCanvas(overlay: copy, month: m, yOrigin: y0)
            .equatable()
            .frame(height: h)
            .offset(y: y0)
    }

    /// The record-once rigid band canvas for rest-year: a COPY of this overlay whose input is the
    /// scroll-free g0, wrapped in an Equatable view so the Canvas body (packing + drawing) only
    /// re-runs when band content / activation / theme actually change — not per scroll frame.
    private func rigidBandsView(_ g0: SceneInput) -> some View {
        var copy = self
        copy.input = g0
        copy.yearG0 = nil
        // Activation ids only matter to the BAND canvas when they refer to a band — a hovered/
        // selected TIMED event or deadline must not invalidate the cached layer (during a scroll
        // the pointer sweeps hover ids constantly). Filter to band ids before they enter the key.
        let bandIds = Set(bands.map(\.id))
        copy.hovered = hovered.flatMap { bandIds.contains($0) ? $0 : nil }
        copy.selected = selected.flatMap { bandIds.contains($0) ? $0 : nil }
        copy.selectedIds = selectedIds.intersection(bandIds)
        copy.editingId = editingId.flatMap { bandIds.contains($0) ? $0 : nil }
        return YearBandsCanvas(overlay: copy)
            .equatable()
            .frame(height: g0.vp.h)
    }

    /// Accessors for YearBandsCanvas (OverlayCanvases.swift; keeps the other members private).
    func rigidBandStickers() -> [CanvasSticker] { // internal: read by OverlayCanvases.swift
        canvasList(bandItems())
    }

    var themeRef: Theme { // internal: read by OverlayCanvases.swift
        theme
    }

    var inputRef: SceneInput { // internal: read by OverlayCanvases.swift
        input
    }

    /// Draw order: later-starting events in front; the selected box always frontmost.
    private func orderTimed(
        _ a: (seg: TimedSegment, rect: CGRect, fade: Double),
        _ b: (seg: TimedSegment, rect: CGRect, fade: Double)
    ) -> Bool {
        let sa = a.seg.event.id == selected, sb = b.seg.event.id == selected
        if sa != sb {
            return sb
        } // the selected box sorts last (front)
        if a.seg.event.startHour != b.seg.event.startHour {
            return a.seg.event.startHour < b.seg.event.startHour
        }
        return a.seg.event.endHour > b.seg.event.endHour
    }
}

public extension EventsOverlay {
    /// Launch prewarm: the FIRST month/week timeline reveal pays the whole per-event
    /// anchor-label timezone pass plus per-month segment/overlap packing in one lump — on the
    /// phone that lump landed inside the user's first zoom-in, stalling its opening frames
    /// (and, before the tween's first-tick rebase, consuming the whole animation). Fill both
    /// caches for `months` while the app idles at the year view; keys match timedItems'
    /// lookups exactly, so the first zoom finds everything hot. Safe to call repeatedly.
    @MainActor static func prewarmTimedCaches(events: [TimedEvent], year: Int, months: [Int],
                                              editGen: UInt64, mainTz: String) {
        for e in events {
            let key = SubLabelKey(id: e.id, start: e.startHour, end: e.endHour,
                                  anchorTz: e.anchorTz ?? "", mainTz: mainTz)
            if subLabelCache[key] == nil {
                subLabelCache[key] = anchorRangeLabel(e, mainTz: mainTz)
            }
        }
        for m in months where (0 ... 11).contains(m) {
            let layoutKey = TimedLayoutKey(year: year, focus: m, editGen: editGen, dragging: nil)
            if timedLayoutCache[layoutKey] != nil {
                continue
            }
            var byDay: [Int: [TimedSegment]] = [:]
            for e in events {
                for s in timedSegments(e) {
                    if let rd = relDomOf(year, m, s.event.year, s.event.month, s.event.day) {
                        byDay[rd, default: []].append(s)
                    }
                }
            }
            timedLayoutCache[layoutKey] = byDay.map { rd, segs in
                TimedDayLayout(rd: rd, segs: segs, layout: layoutDay(segs.map(\.event)))
            }
        }
    }
}

/// Frame-to-frame cache of the anchor-timezone sublabels (see timedItems). The key carries
/// everything the label depends on; a nil value ("no label") is cached too.
@MainActor private var subLabelCache: [SubLabelKey: String?] = [:]
private struct SubLabelKey: Hashable {
    let id: String
    let start: CGFloat
    let end: CGFloat
    let anchorTz: String
    let mainTz: String
}

/// Frame-to-frame cache of a month's segment grouping + per-day overlap packing — the parts of
/// timedItems that DON'T depend on the per-frame timeline geometry. With the neighbor months
/// mounted, timedItems runs 3× per frame and full re-packing was the hottest app symbol in the
/// swipe profile; positions (eventRect) stay per-frame, so nothing visual changes.
@MainActor private var timedLayoutCache: [TimedLayoutKey: [TimedDayLayout]] = [:]
struct TimedLayoutKey: Hashable {
    let year: Int
    let focus: Int
    let editGen: UInt64
    let dragging: String?
}

struct TimedDayLayout {
    let rd: Int
    let segs: [TimedSegment]
    let layout: [String: EventLayout]
}
