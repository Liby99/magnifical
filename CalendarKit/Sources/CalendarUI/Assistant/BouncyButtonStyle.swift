// A springy button style — every button in the assistant window bounces a little on press,
// so the UI feels alive (like the Claude/ChatGPT/iMessage clients).

import SwiftUI

struct BouncyButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    var pressedOpacity: Double = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == BouncyButtonStyle {
    /// `.buttonStyle(.bouncy)` — spring scale-on-press.
    static var bouncy: BouncyButtonStyle {
        BouncyButtonStyle()
    }

    static func bouncy(scale: CGFloat) -> BouncyButtonStyle {
        BouncyButtonStyle(scale: scale)
    }
}
