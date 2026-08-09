// The timed/band sticker views (EventSticker, BandSticker) plus the surface, border, and
// badge helpers they share. Split from EventsOverlay.swift (audit round, 2026-08-02).

import CalendarGeometry
import SwiftUI
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

private extension View {
    /// Event surface. `flat` = cheap tinted fill (Performance Mode at rest). `keepFillBase` keeps
    /// that flat fill UNDER the glass (Performance Mode is on), so a flat→glass hover cross-fades:
    /// the fill stays put and the glass materializes over the colored fill instead of tearing the
    /// fill out and flashing the dark backdrop while the glass forms. Non-perf: glass only.
    func eventSurface<S: Shape>(_ glass: CompatGlass, plainFill: Color, in shape: S, flat: Bool,
                                keepFillBase: Bool) -> some View {
        modifier(EventSurface(glass: glass, plainFill: plainFill, shape: shape,
                              flat: flat, keepFillBase: keepFillBase))
    }
}

/// The surface body behind eventSurface. The under-fill exists so the flat→glass switch never
/// flashes the bare backdrop (the sticker mounts mid-hover, the canvas's flat fill gone that same
/// frame) — but left at full strength it also DEFEATS the glass: `.regular` glass over an opaque-ish
/// tint plate has nothing to frost, which is why hovered events stopped reading as Liquid Glass once
/// Performance Mode became the default. So: mount WITH the fill (seamless takeover), then fade it
/// away once the glass is up — the established glass frosts the actual backdrop (grid lines,
/// neighboring events). Flipping back to `flat` shows the fill again on that same frame
/// (`flat || !glassed`), no state round-trip needed, so un-hovering never shows an empty box.
private struct EventSurface<S: Shape>: ViewModifier {
    let glass: CompatGlass
    let plainFill: Color
    let shape: S
    let flat: Bool
    let keepFillBase: Bool
    @State private var glassed = false // glass established → the under-fill has faded away

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                if flat || keepFillBase {
                    shape.fill(plainFill).opacity(flat || !glassed ? 1 : 0)
                } // stable base in Performance Mode; fades out under established glass
                if !flat {
                    Color.clear.glassEffectCompat(glass, in: shape)
                } // glass on top; fades in over the fill
            }
        }
        .onAppear { // mounted already-active (the canvas→view hover promotion)
            if !flat {
                fadeFillOut()
            }
        }
        .onChange(of: flat) { _, isFlat in
            if isFlat {
                glassed = false // rearm; the fill is ALREADY visible via the `flat ||` branch
            } else {
                fadeFillOut()
            }
        }
    }

    /// The short delay keeps the fill solid over the first frames while the glass forms.
    private func fadeFillOut() {
        withAnimation(.easeOut(duration: 0.3).delay(0.05)) { glassed = true }
    }
}

/// A timed event — same visual language as a band (BandStyle): frosted glass tinted with
/// the event color, a rounded accent bar, dotted-when-selected / solid-when-drawer border.
/// Content is the height-driven title + time (clipped, unlike bands' overflow).
struct EventSticker: View { // internal: read by EventsOverlay.swift
    let ev: TimedEvent
    let height: CGFloat
    var showText: Bool = true // month view hides title/time (tiny slivers) — glass + bar only
    var clipTop: Bool = false // cross-midnight: continues from the previous day → square top, bar to top edge
    var clipBottom: Bool = false // cross-midnight: continues into the next day → square bottom, bar to bottom edge
    var timeText: String? // the WHOLE event's range (every segment shows the true span, e.g. "23:00 – 06:00")
    var subTimeText: String? // anchor-zone time when it differs from the view (e.g. "12:00 – 14:00 (PST)")
    var plain: Bool = false // skip glass (animating, or tiny month sliver)
    var forceGlass: Bool = false // glass despite plain — a box the hovered event overlaps
    let activation: EventActivation
    var badges: EventBadges = [] // provenance/kind marker glyphs (same as bands)
    var editing: Bool = false // the inline title editor is open over this box → hide its own title
    let theme: Theme

    var body: some View {
        let lay = eventTextLayout(height, hasSubline: subTimeText != nil)
        // A revealed hidden imported event reads as "off": a neutral gray fill + gray border/badges, with
        // ONLY the left (dotted) bar keeping the event's color as its identity.
        let hidden = badges.contains(.hidden)
        let barColor = theme.eventBorder(ev.color) // left bar — always colorful
        let border = hidden ? theme.textMuted : barColor // border + badge glyphs
        let color = hidden ? theme.text : theme.eventColor(ev.color) // glass / fill tint
        let r = BandStyle.cornerRadius
        let active = activation.isActive
        let tint = activation.tint * theme.eventTintScale
        let glass: CompatGlass = (active || BandStyle.idleFrosted) ? .regular.tint(color.opacity(tint))
            : .clear.tint(color.opacity(tint))
        let barWidth = activation.accentWide ? BandStyle.accentWidthSelected : BandStyle.accentWidth
        // The left accent bar is a fixed-width vertical bar on every timed event, tall or short.
        // Normally inset top/bottom (accentInset) like a band; but on a short event the inset would
        // eat the bar, so shrink it toward 0 — a very short event's bar spans the full height.
        let barVInset = min(BandStyle.accentInset, max(0, (height - BandStyle.accentInset * 2) / 2))
        // Cross-midnight: square the corners on the edge the event continues over, and run the accent bar
        // flush to that edge (no inset) — the same "…continued" cue a band uses across a month boundary.
        let boxShape = UnevenRoundedRectangle(
            topLeadingRadius: clipTop ? 0 : r,
            bottomLeadingRadius: clipBottom ? 0 : r,
            bottomTrailingRadius: clipBottom ? 0 : r,
            topTrailingRadius: clipTop ? 0 : r
        )
        let barTopInset = clipTop ? 0 : barVInset
        let barBotInset = clipBottom ? 0 : barVInset
        VStack(alignment: .leading, spacing: showText ? -1 : 0) {
            // Month view (no title): markers sit in-flow at the top, same as bands. Week/day view
            // shows the title starting at the top — its markers are a top-right overlay (below), so
            // they don't push the title down.
            if !showText, !badges.isEmpty, height >= 12 { // too-short boxes hide the marker row
                badgeRow(badges, border)
            }
            if showText {
                Text(ev.title)
                    .font(.custom(BandStyle.titleFontName, size: lay.tiny ? 10 : 13))
                    .foregroundStyle(theme.text)
                    .lineLimit(lay.titleLines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(editing ? 0 : 1) // hidden while the inline editor is open (keeps layout stable)
                if !(lay.short || lay.tiny) {
                    Text(timeText ?? fmtHourRange(ev.startHour, ev.endHour))
                        .font(.system(size: 8.5))
                        .foregroundStyle(theme.text.opacity(0.72))
                        .padding(.top, 2) // a touch more breathing room below the title
                    if let subTimeText, lay.subLine { // anchor-zone time — only when the block is tall enough
                        Text(subTimeText)
                            .font(.system(size: 8))
                            .foregroundStyle(theme.text.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, BandStyle.accentInset + barWidth + BandStyle.barTextGap)
        .padding(.trailing, BandStyle.titleTrailing)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .eventSurface(glass, plainFill: color.opacity(tint), in: boxShape,
                      flat: plain && !active && !forceGlass, keepFillBase: plain)
        .overlay(alignment: .topTrailing) { // week/day view: markers pinned to the top-right corner
            if showText, !badges.isEmpty, height >= 12 { // too-short boxes hide the marker row
                badgeRow(badges, border).padding(.top, 3).padding(.trailing, 4).padding(.leading, 4)
            }
        }
        .overlay(alignment: .leading) { // left accent bar — DOTTED + the ONLY colorful part when hidden
            Group {
                // The bar's caps are rounded on the event's REAL ends but flat (square) where it continues
                // over a midnight boundary (clipTop/clipBottom) — matching the box corners. A normal event
                // rounds both ends (equivalent to a capsule for a bar this thin).
                if hidden {
                    DottedBar(width: barWidth, color: barColor)
                } else {
                    let cap = barWidth / 2
                    UnevenRoundedRectangle(
                        topLeadingRadius: clipTop ? 0 : cap,
                        bottomLeadingRadius: clipBottom ? 0 : cap,
                        bottomTrailingRadius: clipBottom ? 0 : cap,
                        topTrailingRadius: clipTop ? 0 : cap
                    )
                    .fill(barColor).frame(width: barWidth)
                }
            }
            .padding(.top, barTopInset).padding(.bottom, barBotInset).padding(.leading, BandStyle.accentInset)
        }
        .overlay {
            if clipTop || clipBottom {
                // A cross-midnight segment: draw the selection/focus border on every side EXCEPT the
                // midnight continuation edge(s), so the internal boundary between two segments of one
                // event stays borderless (only the real outer sides get the thick border).
                segmentBorder(activation, color: border, radius: r, clipTop: clipTop, clipBottom: clipBottom)
            } else {
                activationBorder(activation, color: border, in: boxShape)
            }
        }
        .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }
}

/// Selection/focus border for a cross-midnight segment: same widths/dash as `activationBorder`, but on an
/// OPEN path that omits the midnight continuation edge(s).
@ViewBuilder
private func segmentBorder(_ activation: EventActivation, color: Color, radius: CGFloat, clipTop: Bool,
                           clipBottom: Bool) -> some View {
    let stroke: (w: CGFloat, dash: [CGFloat])? = switch activation {
    case .selected: (BandStyle.selectedBorderWidth, [])
    case .focusMain: (BandStyle.focusBorderWidth, [])
    case .accompanied: (BandStyle.accompaniedBorderWidth, BandStyle.accompaniedDash)
    case .hover, .plain: nil
    }
    if let s = stroke {
        OpenBorderShape(radius: radius, clipTop: clipTop, clipBottom: clipBottom, inset: s.w / 2)
            .stroke(color, style: StrokeStyle(lineWidth: s.w, lineCap: .butt, lineJoin: .round, dash: s.dash))
    }
}

/// The outline of a rounded rect with the clipped (continuation) edge(s) removed — an OPEN path tracing
/// only the sides that aren't a midnight boundary. Closed sides are inset by half the stroke so the stroke
/// sits inside the box (like strokeBorder); the vertical sides run to the full open edge.
private struct OpenBorderShape: Shape {
    var radius: CGFloat
    var clipTop: Bool
    var clipBottom: Bool
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX + inset, x1 = rect.maxX - inset
        let rad = max(0, min(radius, min(rect.width, rect.height) / 2 - inset))
        var p = Path()
        if clipTop && clipBottom { // middle day of a 3+ day span → the two sides only
            p.move(to: CGPoint(x: x0, y: rect.minY)); p.addLine(to: CGPoint(x: x0, y: rect.maxY))
            p.move(to: CGPoint(x: x1, y: rect.minY)); p.addLine(to: CGPoint(x: x1, y: rect.maxY))
        } else if clipBottom { // open bottom → up the left, rounded top, down the right
            let yTop = rect.minY + inset
            p.move(to: CGPoint(x: x0, y: rect.maxY))
            p.addLine(to: CGPoint(x: x0, y: yTop + rad))
            p.addQuadCurve(to: CGPoint(x: x0 + rad, y: yTop), control: CGPoint(x: x0, y: yTop))
            p.addLine(to: CGPoint(x: x1 - rad, y: yTop))
            p.addQuadCurve(to: CGPoint(x: x1, y: yTop + rad), control: CGPoint(x: x1, y: yTop))
            p.addLine(to: CGPoint(x: x1, y: rect.maxY))
        } else { // clipTop → open top: down the left, rounded bottom, up the right
            let yBot = rect.maxY - inset
            p.move(to: CGPoint(x: x0, y: rect.minY))
            p.addLine(to: CGPoint(x: x0, y: yBot - rad))
            p.addQuadCurve(to: CGPoint(x: x0 + rad, y: yBot), control: CGPoint(x: x0, y: yBot))
            p.addLine(to: CGPoint(x: x1 - rad, y: yBot))
            p.addQuadCurve(to: CGPoint(x: x1, y: yBot - rad), control: CGPoint(x: x1, y: yBot))
            p.addLine(to: CGPoint(x: x1, y: rect.minY))
        }
        return p
    }
}

/// A horizontal row of the event's provenance/kind marker glyphs (shared by the in-flow month
/// layout and the week/day top-right overlay).
/// A vertical DOTTED accent bar (round dots down a line), used in place of the solid accent bar to mark
/// a revealed hidden imported event. Dot diameter = `width`; spacing ≈ 2.2× so the dots read as dotted.
private struct DottedBar: View {
    let width: CGFloat
    let color: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: width / 2, y: width / 2))
                p.addLine(to: CGPoint(x: width / 2, y: max(width, geo.size.height - width / 2)))
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.01, width * 2.2]))
        }
        .frame(width: width)
    }
}

/// Marker glyph row that never overflows its box: ViewThatFits tries the full row, then each
/// shorter LEADING prefix, and finally nothing — so a too-small event drops trailing glyphs
/// (possibly all of them) instead of spilling outside the sticker. Mirrors the Canvas fast
/// path's drawBadges fit rule; keep the two in sync.
private func badgeRow(_ badges: EventBadges, _ color: Color) -> some View {
    let syms = badgeSymbols(badges)
    func row(_ n: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(syms.prefix(n), id: \.self) { sym in
                Image(systemName: sym).font(.system(size: 6.5, weight: .bold))
            }
        }
    }
    return ViewThatFits(in: .horizontal) {
        row(syms.count)
        if syms.count > 1 {
            row(syms.count - 1)
        }
        if syms.count > 2 {
            row(syms.count - 2)
        }
        if syms.count > 3 {
            row(syms.count - 3)
        }
        Color.clear.frame(width: 0, height: 0) // nothing fits → show nothing
    }
    .foregroundStyle(color)
}

/// SF Symbol glyphs for an event's provenance/kind markers, in a stable left→right order.
func badgeSymbols(_ b: EventBadges) -> [String] {
    var s: [String] = []
    if b.contains(.recurrent) {
        s.append("repeat")
    }
    if b.contains(.promoted) {
        s.append("pin.fill")
    }
    if b.contains(.ai) {
        s.append("sparkles")
    }
    if b.contains(.imported) {
        s.append("square.and.arrow.down")
    }
    return s
}

/// The per-activation border overlay shared by both stickers: normal solid (focus), dashed
/// (accompanied sibling), thick solid (selected/drawer); nothing for hover/plain.
@ViewBuilder
func activationBorder<S: InsettableShape>(
    _ activation: EventActivation,
    color: Color, // internal: read by DeadlinesOverlay.swift
    in shape: S
) -> some View {
    switch activation {
    case .selected:
        shape.strokeBorder(color, lineWidth: BandStyle.selectedBorderWidth)
    case .focusMain:
        shape.strokeBorder(color, lineWidth: BandStyle.focusBorderWidth)
    case .accompanied:
        shape.strokeBorder(
            color,
            style: StrokeStyle(lineWidth: BandStyle.accompaniedBorderWidth, dash: BandStyle.accompaniedDash)
        )
    case .hover, .plain:
        EmptyView()
    }
}

/// An all-day band: a frosted liquid-glass rounded rect tinted with the event color.
/// Hover fades the fill slightly; single-select adds a thin dotted border; an open
/// drawer (double-click) makes it a solid, thicker border.
struct BandSticker: View { // internal: read by EventsOverlay.swift
    let ev: BandEvent
    let activation: EventActivation
    let editing: Bool
    let gap: CGFloat? // px to the nearest later-starting bar (title clips before it)
    let clipBox: Bool // clip title to this box's right edge (shorter same-start bar on top)
    let clipStart: Bool // band started before the viewport's left edge → square left, no accent bar
    let clipEnd: Bool // band ends after the viewport's right edge → square right corners
    let warn: Bool // fully-overlapping-events warning (this is the kept band)
    let box: CGSize // band box size (for scrim geometry)
    var badges: EventBadges = [] // provenance/kind marker glyphs at the bottom of the bar
    var plain: Bool = false // skip glass while animating (page-turn/pinch) — cheaper per frame
    var forceGlass: Bool = false // glass despite plain — a bar the hovered event overlaps
    let theme: Theme

    var body: some View {
        let border = theme.eventBorder(ev.color)
        let color = theme.eventColor(ev.color)
        let r = BandStyle.cornerRadius
        let active = activation.isActive
        let tint = activation.tint * theme.eventTintScale
        let glass: CompatGlass = (active || BandStyle.idleFrosted) ? .regular.tint(color.opacity(tint))
            : .clear.tint(color.opacity(tint))
        let barWidth = activation.accentWide ? BandStyle.accentWidthSelected : BandStyle.accentWidth
        // Clipped edges (band runs off-screen): square off that side's corners so it reads as continuing
        // past the viewport. A left clip also drops the accent bar and pulls the title in a touch, since
        // the bar's width no longer occupies the lead.
        let leftR: CGFloat = clipStart ? 0 : r
        let rightR: CGFloat = clipEnd ? 0 : r
        let bandShape = UnevenRoundedRectangle(topLeadingRadius: leftR, bottomLeadingRadius: leftR,
                                               bottomTrailingRadius: rightR, topTrailingRadius: rightR,
                                               style: .circular)
        let lead = clipStart ? BandStyle.accentInset + BandStyle.barTextGap
            : BandStyle.accentInset + barWidth + BandStyle.barTextGap

        // Only the FOCUSED box (exact click / drawer, or a lone hover) un-truncates to full overflow —
        // NOT the accompanied siblings of a selected series, which stay clipped like normal bars so
        // just the one main title spills. Otherwise: a shorter same-start bar (on top) clips to its
        // own box; everyone else clips before the next later bar (unbounded when none).
        let expanded = activation.expandsTitle
        let clip: CGFloat? = expanded ? nil
            : (clipBox ? max(0, box.width - lead - BandStyle.titleTrailing) : gap.map { max(12, $0 - 10) })
        // Spill scrim (focused box only): the part of the full title past the box's right edge, when
        // it overruns something behind it — a longer same-start bar (clipBox) or a later bar.
        // A dark plate occludes that bar's text so the spilled title stays readable.
        let titleEnd = lead + Self.titleWidth(ev.title)
        let spill = max(0, titleEnd + 9 - box.width)
        let maskW: CGFloat = (expanded && spill > 0 && (clipBox || (gap != nil && gap! < titleEnd))) ? spill : 0

        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .eventSurface(
                glass,
                plainFill: color.opacity(tint),
                in: bandShape,
                flat: plain && !active && !forceGlass,
                keepFillBase: plain
            )
            // Spill scrim: a frosted plate of THIS event's color that sits UNDER the box, shares its
            // two left corners (same radius), and extends right to cover the full un-truncated title.
            // Under the box it's hidden by the glass; past the box it occludes the bar behind the
            // spill. A single rounded rect → no triangular gap at the box's rounded right corner.
            .background(alignment: .leading) {
                if maskW > 0 {
                    let shape = bandShape
                    Rectangle().fill(theme.bg.opacity(0.55)) // base occlusion under the frost
                        .frame(width: box.width + maskW, height: box.height)
                        .glassEffectCompat(.regular.tint(color.opacity(BandStyle.tintIdle * theme.eventTintScale)), in: shape)
                        .clipShape(shape)
                }
            }
            .overlay(alignment: .leading) { // accent bar — omitted when the band starts off-screen left
                if !clipStart {
                    Capsule().fill(border).frame(width: barWidth)
                        .padding(.vertical, BandStyle.accentInset).padding(.leading, BandStyle.accentInset)
                }
            }
            .overlay(alignment: .leading) { // markers (top) + title, as one vertically-centered block
                if !editing {
                    VStack(alignment: .leading, spacing: -3) { // negative → pull the title up tight under the icons
                        if !badges.isEmpty, box.height >= 12 { // fitted row: overflowing glyphs drop
                            badgeRow(badges, border)
                        }
                        titleView(clip: clip)
                    }
                    .padding(.leading, lead)
                    .allowsHitTesting(false)
                }
            }
            .overlay { activationBorder(activation, color: border, in: bandShape) } // level-specific border
            .overlay(alignment: .topLeading) { // fully-overlapping warning
                if warn {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                        .padding(.leading, 2).padding(.top, 1)
                        .help("Fully overlapping events")
                }
            }
            .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }

    @ViewBuilder private func titleView(clip: CGFloat?) -> some View {
        let t = Text(ev.title)
            .font(.custom(BandStyle.titleFontName, size: BandStyle.titleSize))
            .foregroundStyle(theme.text)
            .lineLimit(1)
        if let clip {
            t.truncationMode(.tail).frame(width: clip, alignment: .leading)
        } else {
            t.fixedSize()
        }
    }

    static func titleWidth(_ s: String) -> CGFloat {
        // iOS has no Comic Sans; Font.custom falls back to the system font when rendering, and
        // this measurement must use the SAME font the sticker actually renders with, or band
        // title-spill widths drift from what's on screen.
        #if canImport(AppKit)
            let f = NSFont(name: BandStyle.titleFontName, size: BandStyle.titleSize) ?? NSFont
                .systemFont(ofSize: BandStyle.titleSize)
        #else
            let f = UIFont(name: BandStyle.titleFontName, size: BandStyle.titleSize) ?? UIFont
                .systemFont(ofSize: BandStyle.titleSize)
        #endif
        return (s as NSString).size(withAttributes: [.font: f]).width
    }
}
