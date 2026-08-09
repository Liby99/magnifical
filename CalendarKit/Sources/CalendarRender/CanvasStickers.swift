// Canvas fast path for PLAIN stickers (Performance Mode, year/month zoom).
//
// The flamegraph (docs: bench/results.log + the month-swipe profiling session) showed ~66% of
// main-thread frame time in SwiftUI's view-graph re-layout of the sticker views — ForEach list
// maintenance + per-sticker layout chains — while the Canvas passes cost ~0.5ms/frame. At year/
// month zoom EVERY visible event is a sticker (hundreds), and a PLAIN sticker's flat rendering is
// tiny: an (uneven-)rounded fill + a 1pt accent bar + optional badge glyphs + (bands only) a title.
// So plain stickers are drawn here, in one Canvas, and only ACTIVE stickers (hover/selected/
// accompanied/editing) remain real SwiftUI views — they keep glass, borders, spill scrims, and
// activation animations. Week/day zoom keeps the full view path (rich multi-line text, few boxes).
//
// Pixel parity: every constant below is read from BandStyle / EventActivation / Theme — the same
// sources the view stickers use — so the flat rendering matches the SwiftUI output. The one known
// difference: a plain→hover transition swaps Canvas→view instantly, so the 0.18s tint fade-in
// starts from the flat fill rather than cross-fading (invisible in Performance Mode, where idle
// and hover fills differ only by 0.05 tint).

import CalendarGeometry
import SwiftUI
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Frame-to-frame cache of tail-truncated band titles (see drawBand): key = title + 1px width
/// bucket → the "…"-suffixed string that fits. Measurement matches the render font exactly.
@MainActor private var truncCache: [TruncKey: String] = [:]
private struct TruncKey: Hashable {
    let s: String
    let w: Int
}

@MainActor private func truncatedTitle(_ s: String, width: CGFloat) -> String {
    let key = TruncKey(s: s, w: Int(width))
    if let hit = truncCache[key] {
        return hit
    }
    if truncCache.count > Layout.measureCacheCap {
        truncCache.removeAll(keepingCapacity: true)
    }
    let out: String
    if bandTitleWidth(s) <= width {
        out = s
    } else {
        // Longest prefix whose "…"-suffixed width still fits (character-level tail truncation).
        var lo = 0, hi = s.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if bandTitleWidth(String(s.prefix(mid)) + "…") <= width {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        out = lo > 0 ? String(s.prefix(lo)) + "…" : "…"
    }
    truncCache[key] = out
    return out
}

/// Width of a band-title string in the actual render font (mirrors BandSticker.titleWidth).
private func bandTitleWidth(_ s: String) -> CGFloat {
    #if canImport(AppKit)
        let f = NSFont(name: BandStyle.titleFontName, size: BandStyle.titleSize)
            ?? NSFont.systemFont(ofSize: BandStyle.titleSize)
    #else
        let f = UIFont(name: BandStyle.titleFontName, size: BandStyle.titleSize)
            ?? UIFont.systemFont(ofSize: BandStyle.titleSize)
    #endif
    return (s as NSString).size(withAttributes: [.font: f]).width
}

/// Flat-rendering payload for a plain BAND sticker (mirrors BandSticker's Performance-Mode path).
struct BandDraw {
    let ev: BandEvent
    let gap: CGFloat? // px to the nearest later-starting bar — title clips before it (nil = unbounded)
    let clipBox: Bool // shorter same-start bar on top → title clips to its own box
    let clipStart: Bool // continues off-screen left → square left corners, no accent bar
    let clipEnd: Bool // continues off-screen right → square right corners
    let warn: Bool // fully-overlapping-events marker
    let badges: EventBadges
}

/// Flat-rendering payload for a plain TIMED sticker. At month zoom showText=false (fill + accent
/// bar + in-flow badge row). During a zoom TRANSITION (see zoomTransient) week/day stickers are
/// also canvas-drawn WITH text — title/time/subline per eventTextLayout — so the view-mount storm
/// waits for the settled frame; at settled week/day the SwiftUI text path owns rendering.
struct TimedDraw {
    let ev: TimedEvent
    let clipTop: Bool // cross-midnight: continues from the previous day
    let clipBottom: Bool // …into the next day
    let badges: EventBadges
    var showText: Bool = false // week/day zoom: title + time (+subline), badges top-right
    var timeText: String? // the WHOLE event's range ("23:00 – 06:00")
    var subTimeText: String? // anchor-zone range when it differs from the view tz
}

enum StickerDraw { case band(BandDraw), timed(TimedDraw) }

/// One Canvas-drawable sticker: geometry + the flat payload.
struct CanvasSticker {
    let rect: CGRect
    let fade: Double
    let z: Double
    let draw: StickerDraw
}

@MainActor enum StickerCanvas {
    /// Draw a clip-group of stickers in z order (matches the view path's zIndex ordering).
    static func draw(_ items: [CanvasSticker], in ctx: inout GraphicsContext, theme: Theme) {
        for it in items.sorted(by: { $0.z < $1.z }) {
            switch it.draw {
            case let .band(b): drawBand(b, rect: it.rect, fade: it.fade, ctx: &ctx, theme: theme)
            case let .timed(t): drawTimed(t, rect: it.rect, fade: it.fade, ctx: &ctx, theme: theme)
            }
        }
    }

    /// ── Band: fill + accent bar + (badges above title, 3px overlapped) + warn triangle ──────────
    private static func drawBand(_ b: BandDraw, rect: CGRect, fade: Double,
                                 ctx: inout GraphicsContext, theme: Theme) {
        guard fade > 0.001, rect.width > 0.5 else { return }
        var layer = ctx
        layer.opacity = fade
        let border = theme.eventBorder(b.ev.color)
        let color = theme.eventColor(b.ev.color)
        let r = BandStyle.cornerRadius
        let leftR: CGFloat = b.clipStart ? 0 : r, rightR: CGFloat = b.clipEnd ? 0 : r
        layer.fill(
            Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
                topLeading: leftR, bottomLeading: leftR, bottomTrailing: rightR, topTrailing: rightR
            )),
            with: .color(color.opacity(BandStyle.tintIdle * theme.eventTintScale))
        )
        let barWidth = BandStyle.accentWidth // plain is never accentWide
        if !b.clipStart {
            let bar = CGRect(x: rect.minX + BandStyle.accentInset, y: rect.minY + BandStyle.accentInset,
                             width: barWidth, height: max(0, rect.height - 2 * BandStyle.accentInset))
            layer.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .color(border))
        }
        let lead = b.clipStart ? BandStyle.accentInset + BandStyle.barTextGap
            : BandStyle.accentInset + barWidth + BandStyle.barTextGap
        // Title width limit (plain never expands): own box for a stacked shorter bar, else up to the
        // next later-starting bar, else unbounded overflow — same rules as BandSticker.
        let clipW: CGFloat? = b.clipBox ? max(0, rect.width - lead - BandStyle.titleTrailing)
            : b.gap.map { max(12, $0 - 10) }
        let font = Font.custom(BandStyle.titleFontName, size: BandStyle.titleSize)
        let resolved = resolvedText(b.ev.title, font, 0, theme.text, &layer)
        let tSize = resolved.measure(in: CGSize(width: 4000, height: 200))
        // Badge row (7px glyph row) sits above the title, pulled 3px into it (VStack spacing -3).
        // On a box too small for even ONE glyph (or too short for the row) it's hidden entirely and
        // the title re-centers; on a partial fit the overflowing glyphs are dropped, never spilled.
        let badgeMaxX = rect.maxX - 2
        let showBadges = !b.badges.isEmpty && rect.height >= 12
            && firstBadgeFits(b.badges, x: rect.minX + lead, maxX: badgeMaxX, color: border, ctx: &layer)
        let badgeH: CGFloat = showBadges ? 8 : 0
        let blockH = showBadges ? badgeH - 3 + tSize.height : tSize.height
        let y0 = rect.midY - blockH / 2
        if showBadges {
            drawBadges(b.badges, at: CGPoint(x: rect.minX + lead, y: y0 + badgeH / 2),
                       maxX: badgeMaxX, color: border, ctx: &layer)
        }
        let titleMidY = y0 + (showBadges ? badgeH - 3 : 0) + tSize.height / 2
        if let clipW {
            // Tail-truncated inside the width limit. draw(Text, in:) would re-resolve the string
            // EVERY frame (it bypasses the resolved-text cache) — ~0.4ms/f of text resolution in
            // the swipe/fling profiles — so truncate once (cached) and draw the cached resolution.
            let t = truncatedTitle(b.ev.title, width: clipW)
            let rt = resolvedText(t, font, 0, theme.text, &layer)
            layer.draw(rt, at: CGPoint(x: rect.minX + lead, y: titleMidY), anchor: .leading)
        } else {
            layer.draw(resolved, at: CGPoint(x: rect.minX + lead, y: titleMidY), anchor: .leading)
        }
        if b.warn {
            let tri = layer.resolve(Text(Image(systemName: "exclamationmark.triangle.fill"))
                .font(.system(size: 10)).foregroundStyle(.yellow))
            layer.draw(tri, at: CGPoint(x: rect.minX + 2, y: rect.minY + 1), anchor: .topLeading)
        }
    }

    /// ── Timed (month zoom, no text): fill + accent bar (dotted when hidden) + badge row ─────────
    private static func drawTimed(_ t: TimedDraw, rect: CGRect, fade: Double,
                                  ctx: inout GraphicsContext, theme: Theme) {
        guard fade > 0.001, rect.width > 0.5 else { return }
        var layer = ctx
        layer.opacity = fade
        // Hidden (revealed hidden import): neutral gray fill/badges; only the dotted bar keeps color.
        let hidden = t.badges.contains(.hidden)
        let barColor = theme.eventBorder(t.ev.color)
        let border = hidden ? theme.textMuted : barColor
        let color = hidden ? theme.text : theme.eventColor(t.ev.color)
        let r = BandStyle.cornerRadius
        let topR: CGFloat = t.clipTop ? 0 : r, botR: CGFloat = t.clipBottom ? 0 : r
        layer.fill(
            Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
                topLeading: topR, bottomLeading: botR, bottomTrailing: botR, topTrailing: topR
            )),
            with: .color(color.opacity(BandStyle.tintIdle * theme.eventTintScale))
        )
        let barWidth = BandStyle.accentWidth
        let barVInset = min(BandStyle.accentInset, max(0, (rect.height - BandStyle.accentInset * 2) / 2))
        let topIn: CGFloat = t.clipTop ? 0 : barVInset, botIn: CGFloat = t.clipBottom ? 0 : barVInset
        let bar = CGRect(x: rect.minX + BandStyle.accentInset, y: rect.minY + topIn,
                         width: barWidth, height: max(0, rect.height - topIn - botIn))
        if hidden {
            // DottedBar: round dots down the bar's line (dot ⌀ = width, spacing ≈ 2.2×).
            var p = Path()
            p.move(to: CGPoint(x: bar.midX, y: bar.minY + barWidth / 2))
            p.addLine(to: CGPoint(x: bar.midX, y: max(bar.minY + barWidth, bar.maxY - barWidth / 2)))
            layer.stroke(p, with: .color(barColor),
                         style: StrokeStyle(lineWidth: barWidth, lineCap: .round, dash: [0.01, barWidth * 2.2]))
        } else {
            let cap = barWidth / 2
            layer.fill(
                Path(roundedRect: bar, cornerRadii: RectangleCornerRadii(
                    topLeading: t.clipTop ? 0 : cap, bottomLeading: t.clipBottom ? 0 : cap,
                    bottomTrailing: t.clipBottom ? 0 : cap, topTrailing: t.clipTop ? 0 : cap
                )),
                with: .color(barColor)
            )
        }
        if t.showText {
            // Week/day text block (transition frames only — mirrors EventSticker's VStack layout):
            // title (Comic Sans 13 / 10 tiny, up to titleLines wrapped lines), then the time range
            // (8.5pt @0.72), then the anchor-tz subline (8pt @0.5) when the block is tall enough.
            let lay = eventTextLayout(rect.height, hasSubline: t.subTimeText != nil)
            let lead = BandStyle.accentInset + barWidth + BandStyle.barTextGap
            let textX = rect.minX + lead
            let textW = max(0, rect.width - lead - BandStyle.titleTrailing)
            let lineH: CGFloat = lay.tiny ? 12 : 16.5
            if textW > 4 {
                let titleFont = Font.custom(BandStyle.titleFontName, size: lay.tiny ? 10 : 13)
                let titleRect = CGRect(x: textX, y: rect.minY + 3, width: textW,
                                       height: min(rect.height - 4, CGFloat(lay.titleLines) * lineH))
                layer.draw(Text(t.ev.title).font(titleFont).foregroundStyle(theme.text), in: titleRect)
                if !(lay.short || lay.tiny), let time = t.timeText {
                    // Time sits under the actually-used title height (measured, capped at titleLines).
                    let m = layer.resolve(Text(t.ev.title).font(titleFont))
                    let usedH = min(m.measure(in: CGSize(width: textW, height: 1000)).height,
                                    titleRect.height)
                    var ty = rect.minY + 3 + usedH + 1
                    layer.draw(Text(time).font(.system(size: 8.5))
                        .foregroundStyle(theme.text.opacity(0.72)),
                        in: CGRect(x: textX, y: ty, width: textW, height: 12))
                    ty += 11
                    if let sub = t.subTimeText, lay.subLine {
                        layer.draw(Text(sub).font(.system(size: 8))
                            .foregroundStyle(theme.text.opacity(0.5)),
                            in: CGRect(x: textX, y: ty, width: textW, height: 11))
                    }
                }
            }
            if !t.badges.isEmpty, rect.height >= 12 {
                // Week/day: badges pinned top-right (the view uses a topTrailing overlay). Keep the
                // LEADING prefix that fits the box's width and drop the rest — a sliver-thin event
                // shows no markers rather than glyphs spilling outside its box.
                let font = Font.system(size: 6.5, weight: .bold)
                var w: CGFloat = 0
                var glyphs: [(g: GraphicsContext.ResolvedText, w: CGFloat)] = []
                for sym in badgeSymbols(t.badges) {
                    let g = layer.resolve(Text(Image(systemName: sym)).font(font).foregroundStyle(border))
                    let gw = g.measure(in: CGSize(width: 100, height: 100)).width
                    if w + gw + 2 > rect.width - 8 {
                        break
                    }
                    glyphs.append((g, gw))
                    w += gw + 2
                }
                var x = rect.maxX - 4 - w + 2
                for e in glyphs {
                    layer.draw(e.g, at: CGPoint(x: x, y: rect.minY + 7), anchor: .leading)
                    x += e.w + 2
                }
            }
        } else if !t.badges.isEmpty, rect.height >= 12 {
            // In-flow at the top (the month-view EventSticker layout: leading pad after the bar, 3px top).
            // Boxes too short for the row show none; glyphs past the box's width are dropped.
            let x = rect.minX + BandStyle.accentInset + barWidth + BandStyle.barTextGap
            drawBadges(t.badges, at: CGPoint(x: x, y: rect.minY + 3 + 4), maxX: rect.maxX - 2,
                       color: border, ctx: &layer)
        }
    }

    /// The badge glyph row: 6.5pt bold SF Symbols, 2px apart, left-anchored at `at.x`, centered on `at.y`.
    /// Symbols are drawn as image-interpolated Text (Text(Image(…))) — the Canvas-idiomatic way to give
    /// an SF Symbol a font size/weight + foreground color, and it reuses the resolved-text cache.
    /// Glyphs that would cross `maxX` are DROPPED, not clipped: a box too small for its markers shows
    /// only the leading prefix that fits (possibly none) instead of overflowing the sticker.
    private static func drawBadges(_ badges: EventBadges, at: CGPoint, maxX: CGFloat, color: Color,
                                   ctx: inout GraphicsContext) {
        var x = at.x
        let font = Font.system(size: 6.5, weight: .bold)
        for sym in badgeSymbols(badges) {
            let t = ctx.resolve(Text(Image(systemName: sym)).font(font).foregroundStyle(color))
            let sz = t.measure(in: CGSize(width: 100, height: 100))
            if x + sz.width > maxX {
                break
            }
            ctx.draw(t, at: CGPoint(x: x, y: at.y), anchor: .leading)
            x += sz.width + 2
        }
    }

    /// Whether at least the FIRST marker glyph fits between `x` and `maxX`. When it doesn't, the
    /// caller hides the whole row (and reclaims its layout space) instead of reserving an empty band.
    private static func firstBadgeFits(_ badges: EventBadges, x: CGFloat, maxX: CGFloat, color: Color,
                                       ctx: inout GraphicsContext) -> Bool {
        guard let sym = badgeSymbols(badges).first else { return false }
        let t = ctx.resolve(Text(Image(systemName: sym))
            .font(Font.system(size: 6.5, weight: .bold)).foregroundStyle(color))
        return x + t.measure(in: CGSize(width: 100, height: 100)).width <= maxX
    }
}
