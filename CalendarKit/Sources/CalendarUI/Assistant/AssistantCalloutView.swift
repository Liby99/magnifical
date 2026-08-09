// The quick-ask callout — layer 1 of the assistant. Presented as a popover from the calendar
// toolbar's sparkles button (an NSPopover under the hood: caret pointing at the button, system
// glass material, may extend beyond the calendar window — the Apple Calendar event-callout feel).
// It renders THE SAME live conversation as the standalone window (shared AssistantState), with no
// sidebar/model chrome: just a slim header (New Conversation + Open in Window) and ConversationView.

import SwiftUI

public struct AssistantCalloutView: View {
    @Bindable var state: AssistantState
    @Environment(\.colorScheme) private var scheme
    let onOpenWindow: () -> Void

    /// Callout size. Popover self-sizing fights a growing transcript, so it's a stable tall panel
    /// (the transcript scrolls inside). Tune to taste.
    static let size = CGSize(width: 400, height: 560)

    public init(state: AssistantState, onOpenWindow: @escaping () -> Void) {
        self.state = state
        self.onOpenWindow = onOpenWindow
    }

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("AI Assistant")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
                Spacer()
                // Shortcuts live on the buttons, so they're active exactly while the popover is
                // the key window — the calendar's own ⌘N (new event) is untouched elsewhere.
                Button { state.newChat() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bouncy)
                .keyboardShortcut("n", modifiers: .command)
                .help("New conversation (⌘N)")
                Button(action: onOpenWindow) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bouncy)
                .keyboardShortcut("o", modifiers: .command)
                .help("Open in separate window (⌘O)")
            }
            .foregroundStyle(theme.textMuted)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // The exact same conversation surface as the window — bubbles, action cards, composer.
            // `translucent` lets the popover's glass material show through the transcript.
            ConversationView(state: state, theme: theme, translucent: true)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

// ── ⌘I plumbing ────────────────────────────────────────────────────────────────────────
// CalendarView publishes its callout binding as a focused scene value; the app's ⌘I command reads
// it — calendar window key → toggle the callout; otherwise fall back to the standalone window.

private struct AssistantCalloutKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    public var assistantCallout: Binding<Bool>? {
        get { self[AssistantCalloutKey.self] }
        set { self[AssistantCalloutKey.self] = newValue }
    }
}
