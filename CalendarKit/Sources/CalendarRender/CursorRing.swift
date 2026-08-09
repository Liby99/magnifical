// The shared keyboard-focus indicator: a thin, dashed, red rounded-rect outline that springs/slides to
// its target rect. Used by every navigation cursor (block / band / event) and — eventually — the
// drawer's field focus ring, so the whole keyboard layer reads as one system. See
// docs/prompts/keyboard_control.md → "Cursor styling".
//
// The rect is in the calendar's GEOMETRY space (the same space as EventsOverlay: x measured from the
// content's left edge, before the padLeft inset), so the host places this in an overlay offset by
// padLeft. A nil rect hides it (mouse mode, or a state without a cursor).

import CalendarGeometry
import SwiftUI

public struct CursorRing: View {
    let rect: CGRect?
    var theme: Theme
    var cornerRadius: CGFloat = 8
    /// True while the view geometry is itself animating (zoom/scroll tween). Then the ring must follow
    /// the geometry EXACTLY each frame — its own spring would lag behind. It springs only for discrete
    /// cursor moves (at rest).
    var geometryAnimating: Bool = false

    public init(rect: CGRect?, theme: Theme, cornerRadius: CGFloat = 8, geometryAnimating: Bool = false) {
        self.rect = rect
        self.theme = theme
        self.cornerRadius = cornerRadius
        self.geometryAnimating = geometryAnimating
    }

    public var body: some View {
        ZStack {
            if let r = rect {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.eventBorder("red"),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .transition(.opacity) // fade in/out when it appears / disappears
            }
        }
        .allowsHitTesting(false)
        // Spring so the outline slides between cells on a discrete move; but during a view tween, follow
        // the geometry frame-for-frame (nil animation) so it doesn't lag.
        .animation(geometryAnimating ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: rect)
    }
}
