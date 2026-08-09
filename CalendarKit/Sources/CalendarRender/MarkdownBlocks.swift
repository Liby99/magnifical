// The house todo checkbox. (This file once held MarkdownBlocksView, the SwiftUI Text-stack
// note preview — superseded by MarkdownPreview's NSTextView document and relocated to
// legacy/MarkdownBlocksView.swift in the 2026-08-02 audit round.)

import CalendarEngine
import SwiftUI

/// The house checkbox for todo rows everywhere native (dashboard lists, gantt labels, note
/// previews): a ROUNDED square, stroked grey when open, filled with the ACCENT (red) and a white
/// check when done — matching the webview's styling, not SF Symbols' sharp squares.
public struct DashCheckbox: View {
    let checked: Bool
    let size: CGFloat
    var action: (() -> Void)?

    public init(checked: Bool, size: CGFloat = 15, action: (() -> Void)? = nil) {
        self.checked = checked; self.size = size; self.action = action
    }

    public var body: some View {
        // The webview's .cc-dtodo-check: 15px box, 5px radius, 1.5px accent-grey border;
        // checked = the ACCENT fill with a white check.
        let box = ZStack {
            if checked {
                RoundedRectangle(cornerRadius: size * 0.33)
                    .fill(Theme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                RoundedRectangle(cornerRadius: size * 0.33)
                    .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.12), value: checked) // fill/border transition
        if let action {
            Button(action: action) { box.contentShape(Rectangle()) }
                .buttonStyle(PressScaleStyle()) // :active scale, like the CSS
        } else {
            box
        }
    }
}

/// The checkbox's press feedback (.cc-dtodo-check:active): a quick 0.9 scale while held.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
