// macOS app bootstrap. A plain SwiftPM executable can't rely on the SwiftUI App
// lifecycle to show a window reliably, so we bring up NSApplication ourselves and
// host CalendarView in an NSWindow via NSHostingView.

import AppKit
import CalendarEngine
import CalendarUI
import SwiftUI

// Note: the unhandled-key "funk" beep is silenced inside CalendarView (WindowBeepSilencerView), so
// it's handled for both this shell and the SwiftUI CalendarApp shell without per-window subclassing.

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var settingsWindow: NSWindow?
    var helpWindow: NSWindow?
    /// The menu bar is built from the shared AppMenu spec (CalendarUI), so this dev shell and the Xcode
    /// .app can't drift. The coordinator owns all the menu wiring; we only supply the window/About hosts.
    var menuCoordinator: AppMenuCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        // "How to…" deep links (e.g. Settings ▸ Google Calendar) → show the Help window; HelpView
        // selects the topic itself (HelpNav.pending / the notification's object).
        NotificationCenter.default.addObserver(forName: .openHelpTopic, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.showHelp(nil) }
        }
        // Reconcile preferences with iCloud, then apply the saved appearance now that NSApp
        // exists. Syncs only on the entitled signed app; local-only here (see AppSettings.swift).
        PrefsSync.shared.start()
        applyPersistedAppearance()
        // Recording: CC_APPEARANCE=light|dark pins the app appearance so each tutorial GIF can be captured
        // in BOTH themes deterministically (the tutorial shows the variant matching the viewer's scheme).
        if let ap = ProcessInfo.processInfo.environment["CC_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: ap == "dark" ? .darkAqua : .aqua)
        }

        // The default 1440×840 (also used for GIF recording — a wider grid reads less cluttered; the recorded
        // crop rect is read back from the actual window, so any fixed size stays deterministic).
        let demo = !(ProcessInfo.processInfo.environment["CC_DEMO"] ?? "").isEmpty
        // CC_WINDOW=WxH overrides the size (benchmarks measure at realistic, e.g. full-screen, sizes).
        var size = NSSize(width: 1440, height: 840)
        if let ws = ProcessInfo.processInfo.environment["CC_WINDOW"] {
            let p = ws.lowercased().split(separator: "x")
            if p.count == 2, let w = Double(p[0]), let h = Double(p[1]) {
                size = NSSize(width: w, height: h)
            }
        }
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MagnifiCal"
        // Keep the window alive after Cmd-W so it can be reopened (see reopen handler).
        window.isReleasedWhenClosed = false
        // contentView (not contentViewController): a GeometryReader-based SwiftUI view
        // reports a 0×0 fitting size, which contentViewController would collapse to.
        let hosting = NSHostingView(rootView: CalendarView())
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Bench/demo runs: float the window. Repeated launches stop winning macOS's
        // focus-stealing arbitration, and an occluded window suspends the dashboard WKWebView's
        // page ("hidden" visibilityState → no rAF), silently blanking the web-side bench stats.
        if demo {
            window.level = .floating
            // Also surface over full-screen Spaces: if the user works in a fullscreen app while a
            // bench runs, the bench window would otherwise sit on another Space, OCCLUDED — which
            // suspends its display link and presents (a run that silently measures nothing).
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
        // CC_WINDOW=fs: a REAL full-screen Space (not a fullscreen-sized window) — full-screen
        // presentation goes through a different compositor path than windowed, and the two can
        // stall differently under identical layer trees.
        if (ProcessInfo.processInfo.environment["CC_WINDOW"] ?? "").lowercased() == "fs" {
            window.level = .normal
            window.collectionBehavior.insert(.fullScreenPrimary)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in
                window?.toggleFullScreen(nil)
            }
        }
        // CC_TOOLBAR=1: attach a unified NSToolbar with an NSHostingView-backed item, mimicking
        // the app shell's window chrome. The toolbar drags an Auto Layout engine into the window;
        // the ⌘J-pop hypothesis is that hosted-view frame updates during the dash slide then
        // re-dirty window layout INSIDE CA::Transaction::commit's layout loop, which can't
        // converge until the animation ends (one 300ms commit, zero presented frames).
        if ProcessInfo.processInfo.environment["CC_TOOLBAR"] != nil {
            let tb = NSToolbar(identifier: "cc-bench-toolbar")
            tb.delegate = BenchToolbarDelegate.shared
            tb.displayMode = .iconOnly
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.toolbar = tb
        }
        if demo {
            exportContentRect()
        }
        // Dev/screenshot affordance: open the Help window on launch (used to capture Help GIFs/screens).
        if ProcessInfo.processInfo.environment["CC_OPEN_HELP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showHelp(nil) }
        }
        if ProcessInfo.processInfo.environment["CC_OPEN_TUTORIAL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NotificationCenter.default.post(
                name: .showTutorial,
                object: nil
            ) }
        }
        // Dev: fire File ▸ Print… a few seconds in (pair with CC_PRINT_PDF to verify the pipeline headless).
        if ProcessInfo.processInfo.environment["CC_PRINT_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NotificationCenter.default.post(
                name: .requestPrint,
                object: nil
            ) }
        }
    }

    /// Write the window's CONTENT area as a top-left-origin screen rect (points) so the recording script can
    /// `screencapture -R` exactly the calendar (no title bar). Written to $CC_DEMO_DATADIR/rect.txt.
    private func exportContentRect() {
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty,
              let screen = window.screen ?? NSScreen.main else { return }
        let c = window.contentRect(forFrameRect: window.frame) // bottom-left origin, points
        let topLeftY = screen.frame.height - c.maxY // flip to top-left origin
        let line = "\(Int(c.origin.x.rounded())) \(Int(topLeftY.rounded())) \(Int(c.width.rounded())) \(Int(c.height.rounded()))\n"
        try? line.write(toFile: (dir as NSString).appendingPathComponent("rect.txt"), atomically: true, encoding: .utf8)
    }

    /// Cmd-W closes the window but leaves the app running (Cmd-Q quits).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    /// Reopen the window when the Dock icon is clicked and nothing is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Settings/Preferences (⌘,). Lazily create a single window hosting SettingsView; reuse it on
    /// subsequent invocations so ⌘, just brings the existing window forward (no duplicates).
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Build the menu bar from the shared AppMenu spec. The coordinator (CalendarUI) does all the wiring;
    /// we inject only the host-specific bits: how to reach the engine, how to open the Settings/Help
    /// windows, and the custom About panel. `hasAssistant: false` → no AI item / Assistant menu here (the
    /// dev shell has no assistant session).
    private func installMenu() {
        let ctx = MenuContext(
            engine: { CalendarEngine.mainInstance },
            open: { [weak self] target in
                switch target {
                case .help: self?.showHelp(nil)
                case .settings: self?.showSettings(nil)
                case .assistant: break // no assistant window in the dev shell
                }
            },
            showAbout: { [weak self] in self?.showAbout(nil) }
        )
        menuCoordinator = AppMenuCoordinator(ctx: ctx)
        menuCoordinator.install(caps: AppMenuCaps(hasAssistant: false))
    }

    /// Help ▸ MagnifiCal Help — open (or focus) the in-app Help browser window.
    @objc func showHelp(_ sender: Any?) {
        if helpWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "MagnifiCal Help"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HelpView())
            w.center()
            helpWindow = w
        }
        helpWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A richer standard About panel (the SPM binary has no Info.plist strings to populate it).
    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let credits = NSAttributedString(
            string: "A zoomable calendar that keeps your schedule, notes, and to-dos together — with a built-in AI assistant.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MagnifiCal",
            .applicationVersion: version,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// CC_TOOLBAR=1 bench chrome: one toolbar item hosting a SwiftUI view, like the app shell's
/// breadcrumb/glass buttons (see the CC_TOOLBAR block in applicationDidFinishLaunching).
@MainActor
final class BenchToolbarDelegate: NSObject, NSToolbarDelegate {
    static let shared = BenchToolbarDelegate()
    private let ids: [NSToolbarItem.Identifier] = [.init("cc-bench-item"), .flexibleSpace]
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ids
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ids
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "cc-bench-item" {
            item.view = NSHostingView(rootView: Text("MagnifiCal Bench").font(.callout).padding(.horizontal, 8))
        }
        return item
    }
}

let app = NSApplication.shared
/// AppDelegate is @MainActor (its menu code touches main-actor engine state); top-level main.swift code
/// is nonisolated, so construct it on the main actor explicitly. We're literally on the main thread here.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
