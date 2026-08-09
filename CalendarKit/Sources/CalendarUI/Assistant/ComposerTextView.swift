// The composer's text input — an AppKit NSTextView. SwiftUI's TextField(axis: .vertical) on macOS
// caches a stale wrapping width (typing wraps at the sidebar-open width even after the sidebar
// closes) and its multi-line growth is unreliable. NSTextView rewraps at its ACTUAL live width,
// reports its content height so SwiftUI can grow the pill up to a cap, and scrolls internally
// beyond it. Enter sends; Shift+Enter inserts a newline.

import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let textColor: NSColor
    let focusToken: Int // bump → grab keyboard focus
    let onSend: () -> Void
    let onHeightChange: (CGFloat) -> Void

    private static let fontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView() // a correctly-configured editable stack
        guard let tv = scroll.documentView as? NSTextView else {
            assertionFailure("scrollableTextView() did not vend an NSTextView document view")
            return scroll // degraded (no editor) instead of crashing on an AppKit change
        }
        context.coordinator.textView = tv

        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: Self.fontSize)
        tv.textColor = textColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false

        // Re-report the height whenever the layout width changes (sidebar toggle, window resize) —
        // this is what keeps the wrap width honest.
        tv.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: tv, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.reportHeight() }
        }

        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } // focus on appear
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.string != text {
            tv.string = text
            c.reportHeight()
        }
        if tv.textColor != textColor {
            tv.textColor = textColor
        }
        if c.lastFocusToken != focusToken {
            c.lastFocusToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        var lastFocusToken = 0
        var frameObserver: NSObjectProtocol?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        deinit {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            reportHeight()
        }

        /// Enter → send; Shift+Enter → a real newline.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    return false
                } // newline as typed
                parent.onSend()
                return true
            }
            return false
        }

        /// The text's natural height at the CURRENT width — SwiftUI caps it and we scroll beyond.
        func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            parent.onHeightChange(max(h, ComposerTextView.fontSize + 6))
        }
    }
}
