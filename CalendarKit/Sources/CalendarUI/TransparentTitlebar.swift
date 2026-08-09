// Keeps the window's titlebar/toolbar transparent — INCLUDING in full screen. SwiftUI's
// .toolbarBackgroundVisibility(.hidden) only reaches the windowed titlebar; on entering full
// screen AppKit re-applies an opaque backdrop that the SwiftUI modifier (and even
// titlebarAppearsTransparent) doesn't remove. So in full screen we walk the window's own titlebar
// container — and the private NSToolbarFullScreenWindow overlay, if the auto-hide mode is on —
// and hide the material/backdrop views (toolbar ITEMS live in sibling views and stay visible).
// Everything hidden is restored on exit, so windowed behavior is untouched.

import AppKit
import SwiftUI

struct TransparentTitlebar: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let v = HookView()
        v.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView.window)
    }

    private final class HookView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var hiddenBackdrops: [NSView] = [] // what we hid, to restore on exit
        private var dumped = false

        func attach(to window: NSWindow?) {
            guard let window, window !== self.window else { return }
            self.window = window
            apply()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            let names: [Notification.Name] = [
                NSWindow.willEnterFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.apply()
                        // Full-screen toolbar chrome is (re)built lazily — sweep again after the
                        // transition settles, and once more for the slide-in overlay variant.
                        for delay in Self.resweepDelays {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                self?.apply()
                            }
                        }
                    }
                }
            }
        }

        /// The fullscreen transition has no "chrome finished building" callback, so we re-apply on
        /// a settle-time guess (once after the animation, once after the lazy overlay appears).
        private static let resweepDelays: [TimeInterval] = [0.4, 1.2]

        private func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)

            guard window.styleMask.contains(.fullScreen) else {
                // Windowed again → restore anything we hid; SwiftUI's own modifier rules here.
                hiddenBackdrops.forEach { $0.isHidden = false }
                hiddenBackdrops.removeAll()
                return
            }
            // 1. The window's OWN titlebar container (toolbar always visible in full screen).
            if let frame = window.contentView?.superview {
                sweepTitlebars(in: frame)
            }
            // 2. The private overlay bar (auto-hide toolbar mode).
            for w in NSApp.windows where String(describing: type(of: w)).contains("ToolbarFullScreen") {
                if let root = w.contentView {
                    dumpOnce(root, label: "overlay")
                    hideBackdrops(in: root)
                }
            }
        }

        /// Find titlebar containers anywhere in the frame view and clear their backdrops.
        private func sweepTitlebars(in root: NSView) {
            for sub in root.subviews {
                if String(describing: type(of: sub)).localizedCaseInsensitiveContains("titlebar") {
                    dumpOnce(sub, label: "titlebar")
                    hideBackdrops(in: sub)
                } else {
                    sweepTitlebars(in: sub)
                }
            }
        }

        /// Hide material/backdrop views (NOT the toolbar items). Records what it hides for restore.
        private func hideBackdrops(in view: NSView) {
            for sub in view.subviews {
                let cls = String(describing: type(of: sub))
                let isBackdrop = sub is NSVisualEffectView
                    || cls.localizedCaseInsensitiveContains("backdrop")
                    || cls.localizedCaseInsensitiveContains("background")
                if isBackdrop {
                    if !sub.isHidden {
                        sub.isHidden = true
                        hiddenBackdrops.append(sub)
                    }
                } else {
                    hideBackdrops(in: sub)
                }
            }
        }

        /// One-shot console dump of the chrome hierarchy, so a resistant machine can report what
        /// classes actually make up its full-screen toolbar. DEBUG builds only.
        private func dumpOnce(_ view: NSView, label: String) {
            #if DEBUG
                guard !dumped else { return }
                dumped = true
                func walk(_ v: NSView, _ depth: Int) {
                    print(
                        "[TransparentTitlebar] \(String(repeating: "  ", count: depth))\(type(of: v)) hidden=\(v.isHidden)"
                    )
                    v.subviews.forEach { walk($0, depth + 1) }
                }
                print("[TransparentTitlebar] —— \(label) hierarchy ——")
                walk(view, 0)
            #endif
        }
    }
}
