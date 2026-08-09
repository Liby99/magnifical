// The rigid rest-year band canvases (YearMonthBandsCanvas, YearBandsCanvas) and the RectClip
// shape. Split from EventsOverlay.swift (audit round, 2026-08-02).

import CalendarGeometry
import SwiftUI

/// One month's rigid band layer (per-month granularity of YearBandsCanvas): a SMALL canvas over
/// just the month's band strip. Its == sees only the month-sliced bands + month-filtered
/// activation ids, so a hover/edit elsewhere in the year leaves this layer's display list intact.
struct YearMonthBandsCanvas: View, Equatable { // internal: read by EventsOverlay.swift
    let overlay: EventsOverlay // bands sliced to one month; input = scroll-free g0
    let month: Int
    let yOrigin: CGFloat // content-space top of this canvas (bandY − pad)

    static func == (a: Self, b: Self) -> Bool {
        a.month == b.month && a.yOrigin == b.yOrigin
            && a.overlay.inputRef == b.overlay.inputRef && a.overlay.bands == b.overlay.bands
            && a.overlay.bandBadges == b.overlay.bandBadges
            && a.overlay.hovered == b.overlay.hovered && a.overlay.selected == b.overlay.selected
            && a.overlay.selectedIds == b.overlay.selectedIds
            && a.overlay.editingId == b.overlay.editingId && a.overlay.hideBox == b.overlay.hideBox
            && a.overlay.themeRef.dark == b.overlay.themeRef.dark
            && a.overlay.themeRef.accentDark == b.overlay.themeRef.accentDark
    }

    var body: some View {
        Canvas { ctx, _ in
            var c = ctx
            RenderProf.measure("rigidBands", "2s_rigidBands") {
                let g = overlay.inputRef
                c.translateBy(x: 0, y: -yOrigin) // content space → this month's small canvas
                c.clip(to: Path(CGRect(x: Layout.labelW, y: yOrigin,
                                       width: max(0, g.vp.w - Layout.labelW),
                                       height: 4 * frameFor(month, g).trackH + 8)))
                StickerCanvas.draw(overlay.rigidBandStickers(), in: &c, theme: overlay.themeRef)
            }
        }
    }
}

/// Equatable wrapper around the rest-year rigid band canvas: body (band packing + sticker draws)
/// runs only when == says the CONTENT changed — bands (includes live color previews), the
/// activation-relevant ids, or the theme — never merely because scrollY/now ticked.
struct YearBandsCanvas: View, Equatable { // internal: read by EventsOverlay.swift
    let overlay: EventsOverlay // input already swapped to the scroll-free g0

    static func == (a: Self, b: Self) -> Bool {
        a.overlay.inputRef == b.overlay.inputRef && a.overlay.bands == b.overlay.bands
            && a.overlay.bandBadges == b.overlay.bandBadges
            && a.overlay.hovered == b.overlay.hovered && a.overlay.selected == b.overlay.selected
            && a.overlay.selectedIds == b.overlay.selectedIds
            && a.overlay.editingId == b.overlay.editingId && a.overlay.hideBox == b.overlay.hideBox
            && a.overlay.themeRef.dark == b.overlay.themeRef.dark
            && a.overlay.themeRef.accentDark == b.overlay.themeRef.accentDark
    }

    var body: some View {
        Canvas { ctx, _ in
            var c = ctx
            RenderProf.measure("rigidBands", "2s_rigidBands") {
                let g = overlay.inputRef
                c.clip(to: Path(CGRect(x: Layout.labelW, y: 0,
                                       width: max(0, g.vp.w - Layout.labelW), height: g.vp.h)))
                StickerCanvas.draw(overlay.rigidBandStickers(), in: &c, theme: overlay.themeRef)
            }
        }
    }
}

/// Clips content to an absolute rectangle in the parent's coordinate space.
public struct RectClip: Shape {
    let rect: CGRect
    public init(rect: CGRect) {
        self.rect = rect
    }

    public func path(in _: CGRect) -> Path {
        Path(rect)
    }
}
