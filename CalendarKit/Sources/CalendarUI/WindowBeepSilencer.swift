// Silences the macOS "funk" beep a window emits for an unhandled key-down.
//
// Keyboard shortcuts are dispatched by a local NSEvent monitor (see CalendarView). But when a SwiftUI
// overlay like the event drawer opens, a key can reach the window unhandled (first responder falls to
// the window, or a key slips past the monitor via WebKit's own key handling and bubbles up). A window
// answers an unhandled key-down with the system beep — that's what we silence.
//
// HOW: a one-time METHOD-swizzle of -[NSWindow keyDown:] to a no-op. Method swizzling only swaps an
// implementation on the class; it never touches any instance's isa pointer, so — unlike isa-swizzling
// the window to a subclass — it can't corrupt the KVO that SwiftUI relies on for its windows.
//
// WHY IT'S SAFE: a window's keyDown is the TERMINAL fallback, reached only after nothing in the
// responder chain handled the key. Real typing is consumed by the focused field / editor long before
// it reaches the window, and Command-shortcuts go through menu key equivalents. So the only thing this
// removes is the beep for a genuinely-unhandled key (e.g. Space while the drawer is open).

import AppKit
import ObjectiveC

enum WindowBeepSilencer {
    private static var installed = false

    /// Swizzle `-[NSWindow keyDown:]` to swallow unhandled key-downs (no beep). Idempotent.
    static func installOnce() {
        guard !installed else { return }
        installed = true
        guard let method = class_getInstanceMethod(NSWindow.self, #selector(NSResponder.keyDown(with:))) else { return }
        let swallow: @convention(block) (NSWindow, NSEvent) -> Void = { _, _ in
            // Do nothing — the calendar's key monitor already had its chance; don't beep.
        }
        method_setImplementation(method, imp_implementationWithBlock(swallow))
    }
}
