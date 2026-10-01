// The .ics drop MASK for the main calendar window (dashed border, centered "Drop .ics files
// here"). The drop logic itself lives in AttachmentDropRouter's fallback — the SwiftUI
// DropDelegate that used to live here spanned the whole window at the AppKit layer and could
// hold an entire drag session hostage from the note editors (see DropRouter.swift).

import CalendarRender
import SwiftUI

/// The full-window drop mask: a frosted wash, a large dashed border just inside the window
/// edges, and the centered import glyph + "Drop .ics files here".
struct ICSDropOverlay: View {
    let theme: Theme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Theme.accent.opacity(0.85),
                              style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                .padding(16)
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 44, weight: .medium))
                Text("Drop .ics files here")
                    .font(.system(size: 21, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .allowsHitTesting(false) // visual only — the drop lands on the window's drop target
        .transition(.opacity)
    }
}
