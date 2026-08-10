// The macOS app shell. All the calendar lives in the CalendarKit package; this just
// hosts CalendarView in a WindowGroup so Xcode gives us a proper debuggable .app.

import AppKit
import CalendarEngine
import CalendarUI
import SwiftUI
#if canImport(Sparkle)
    import Combine
    import Sparkle
#endif

@main
struct CalendarApp: App {
    #if canImport(Sparkle)
        /// Sparkle auto-updates — DIRECT (Developer-ID) build only; the Mac App Store variant
        /// drops the Sparkle dependency and this whole block compiles away (canImport). Starting
        /// the updater here schedules the daily background appcast check (see Info-macOS.plist
        /// for the feed URL + EdDSA public key).
        private let updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
    #endif
    /// The standalone chat window's session. Lives at app level (not in a window) so it persists
    /// while the window is closed and while only the menu bar is present.
    @State private var assistant: AssistantState
    /// The quick-ask callout's OWN session — independent thread from the window's (a new chat in
    /// the window never switches the callout), but recorded in the same store/sidebar.
    @State private var quickAssistant: AssistantState

    /// The one calendar engine, owned at app level so BOTH the calendar window and the standalone
    /// chat window read the same live state — the assistant's read-only calendar context reflects
    /// whatever the calendar is currently showing. Constructed in init() (NOT as a property
    /// default, which Swift evaluates BEFORE the init body): it must come after the legacy-
    /// defaults migration, or the registry would read the active-calendar id from empty prefs.
    @State private var engine: CalendarEngine
    /// The File menu's AppKit-side maintenance: Close/Close All at the bottom + the dynamic
    /// "Calendars" submenu, rebuilt on every open (retained so its delegate lives).
    @State private var fileMenuUpdater = FileMenuUpdater()

    init() {
        // FIRST, before anything reads preferences (the engine's registry, PrefsSync below):
        // one-time defaults migration from the legacy dev.libirabu.calendar bundle id.
        LegacyIdentity.migrateDefaultsIfNeeded()
        _engine = State(initialValue: CalendarEngine())
        // The conversation store is shared by (and retained through) both sessions below.
        let store = ConversationStore()
        _assistant = State(initialValue: AssistantState(store: store))
        _quickAssistant = State(initialValue: AssistantState(store: store))
        // Reconcile preferences with iCloud at launch (KVS/UserDefaults only — no NSApp access,
        // so it's safe this early). This build carries the ubiquity-kvstore entitlement, so
        // synced prefs actually follow the user across their devices (see AppSettings.swift).
        // The appearance itself is applied in .onAppear below, once NSApp is up.
        PrefsSync.shared.start()
    }

    var body: some Scene {
        WindowGroup(id: "calendar") {
            CalendarView(engine: engine, assistant: quickAssistant, windowAssistant: assistant)
                // NO root .frame(minWidth:minHeight:) here: that modifier makes the window's
                // NSHostingView re-derive min-size constraints through the toolbar's Auto Layout
                // engine on every animation tick — nearly half the per-tick cost in the ⌘J-pop
                // traces, and the push over the 8.3ms @120Hz budget that froze presents entirely.
                // CalendarView.setupOnAppear pins the same 900×600 floor via window.contentMinSize.
                // Translucent window material → the calendar picks up the macOS 26
                // wallpaper tint (and the frosted masks read as glass over it). The
                // toolbar (breadcrumb + glass buttons) lives inside CalendarView.
                .containerBackground(.windowBackground, for: .window)
                // Apply the reconciled Light/Dark choice once the app is running (doing this in
                // App.init() would touch NSApp before it exists and crash).
                .onAppear {
                    applyPersistedAppearance()
                    quickAssistant.engine = engine // the callout's session needs the engine too
                    assistant.engine = engine
                    // The calendar is a single-window app — no window tabs. Turning off automatic
                    // tabbing removes the View/Window menu's "Show Tab Bar / Show All Tabs / Move Tab…"
                    // items. Idempotent; safe to set on every appearance.
                    NSWindow.allowsAutomaticWindowTabbing = false
                    // File menu upkeep (AppKit, on every open): Close/Close All to the bottom +
                    // the dynamic "Calendars" submenu — matching the dev shell's spec-driven menu.
                    fileMenuUpdater.install(engine: engine)
                }
        }
        .defaultSize(width: 1440, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false)) // thick, Safari/Finder-style bar
        .commands {
            // ⌘I (I for AI) → open the standalone Calendar AI window from anywhere in the app.
            // A menu command's key equivalent fires whenever the app is active, across any window.
            CommandGroup(after: .appInfo) {
                OpenAssistantCommand(engine: engine)
                #if canImport(Sparkle)
                    CheckForUpdatesButton(updater: updaterController.updater)
                #endif
            }
            // Remove SwiftUI's default File → New Window (⌘N). ⌘N is our "new event at the block
            // cursor" shortcut (handled by the calendar's key monitor); otherwise it also spawns a
            // new window.
            CommandGroup(replacing: .newItem) {}
            // File menu: the open-calendar ("document") controls, then import an .ics calendar and
            // import/export a backup. Contents live in CalendarUI (CalendarMenuContent / FileCommands);
            // `.importExport` lands them in the standard File menu.
            CommandGroup(replacing: .importExport) {
                CalendarMenuContent(engine: engine)
                Divider()
                FileCommands(engine: engine)
            }
            // File ▸ Print… (⌘P): the YEAR view prints via the system panel; other levels show a notice.
            // Title/shortcut + the action (post .requestPrint) come from the shared AppMenu spec.
            CommandGroup(replacing: .printItem) {
                MenuActionButton(.printCalendar, engine: engine)
            }
            // ⌘Z / ⌘⇧Z — the SINGLE undo/redo handler (the calendar's key monitor deliberately passes these
            // through so they don't fire twice). A focused text field does its own native undo via `undo:`;
            // otherwise call the engine DIRECTLY — not via the responder chain — so undo works even when the
            // canvas isn't first responder (e.g. right after an inline title rename hands focus back). Titles
            // come from the shared spec (StandardItem); the routing is host-specific so it stays here.
            CommandGroup(replacing: .undoRedo) {
                Button { routeUndoRedo(redo: false, engine: engine) } label: { Label(
                    StandardItem.undo.title,
                    systemImage: "arrow.uturn.backward"
                ) }
                .keyboardShortcut("z", modifiers: .command)
                Button { routeUndoRedo(redo: true, engine: engine) } label: { Label(
                    StandardItem.redo.title,
                    systemImage: "arrow.uturn.forward"
                ) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // Deselect All (⌘D). "Select All" (⌘A) is the standard Edit item, handled by the calendar canvas's
            // `selectAll(_:)` responder. Both also flow through the key monitor so they work regardless of focus.
            CommandGroup(after: .pasteboard) {
                MenuActionButton(.deselectAll, engine: engine)
            }
            // The View menu payload (go-to-today, show-hidden, timezone pickers, tag filter) is defined ONCE
            // in CalendarUI (ViewMenuContent) and shared with the dev shell's View menu. REPLACING the
            // .toolbar group also strips its "Show/Customize Toolbar" items — the calendar's toolbar is fixed.
            // (SwiftUI still supplies Enter/Exit Full Screen itself; window-tab items are removed separately.)
            CommandGroup(replacing: .toolbar) {
                ViewMenuContent(engine: engine)
            }
            // A top-level "Assistant" menu — new/current conversation, model selection, API keys. Its
            // contents live in CalendarUI (AICommands) so they can read the internal assistant model catalog.
            CommandMenu("Assistant") {
                AICommands(assistant: assistant)
            }
            // A top-level "Sync" menu: when iCloud last synced + a manual refresh (Apple Calendar
            // import + iCloud fetch/push). The label re-renders each minute via the monitor's ticker.
            CommandMenu("Sync") {
                ConnectivityMenu(engine: engine)
            }
            // Standard macOS Help menu (kept at the end). Per Apple HIG, "<App> Help" is the first item
            // and opens the in-app Help browser window; the tutorial + ⌘K shortcut guide sit below it. All
            // titles/shortcuts/actions come from the shared AppMenu spec.
            CommandGroup(replacing: .help) {
                OpenHelpCommand() // "MagnifiCal Help" (⌘?) → opens the HelpView window
                Divider()
                MenuActionButton(.tutorial, engine: engine)
                MenuActionButton(.keyboardShortcuts, engine: engine)
                Divider()
                MenuActionButton(.reportProblem, engine: engine) // prefilled GitHub issue
            }
        }

        // Native macOS Settings scene → the standard ⌘, preferences window with toolbar tabs.
        Settings {
            SettingsView()
        }

        // The standalone "Calendar AI" chat window — a separate, draggable window opened from the
        // toolbar sparkles button or the menu-bar item. Independent of the calendar window.
        Window("MagnifiCal AI", id: "assistant") {
            AssistantWindowView(state: assistant, callout: quickAssistant)
                .onAppear {
                    applyPersistedAppearance()
                    assistant.engine = engine // share the live engine → read-only calendar context
                    quickAssistant.engine = engine // (in case the chat window opens first)
                }
        }
        .defaultSize(width: 420, height: 640) // slim, chat-only by default (sidebar starts closed)
        .windowResizability(.contentMinSize)

        // The in-app Help browser — its own window (matches the AppKit dev shell's Help ▸ MagnifiCal Help).
        // A single-instance window: opening it again just refocuses it. Content is HelpView (CalendarUI).
        Window("MagnifiCal Help", id: "help") {
            HelpView()
                .onAppear { applyPersistedAppearance() }
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)

        // Menu-bar item (top-right) → a small dropdown. Its presence keeps the app alive when all
        // windows are closed, so the chat can be opened without (or outliving) the calendar window.
        MenuBarExtra("MagnifiCal AI", systemImage: "sparkles") {
            MenuBarContent(assistant: assistant)
        }
    }
}

#if canImport(Sparkle)
    /// App menu ▸ "Check for Updates…" — disabled while Sparkle can't check (e.g. an update is
    /// already in flight). `canCheckForUpdates` is KVO-observable; the Combine publisher bridges
    /// it into SwiftUI (the standard Sparkle 2 pattern).
    private struct CheckForUpdatesButton: View {
        let updater: SPUUpdater
        @State private var canCheck = false

        var body: some View {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!canCheck)
                .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
        }
    }
#endif

/// The File menu's AppKit-side maintenance, attached as its NSMenuDelegate so it re-runs on EVERY
/// open (a one-shot pass is unreliable — SwiftUI builds the menu lazily and can rebuild it at will;
/// and SwiftUI Commands don't reliably re-render dynamic content, so anything that must stay fresh
/// is (re)built here instead, mirroring the dev shell's menuNeedsUpdate approach). Duties:
///   1. Move the SwiftUI-injected Close (⌘W) / Close All items to the very bottom.
///   2. Own the "Calendars" submenu: every calendar with its item count, the open one ticked,
///      click switches. Rebuilt from engine.calendarMenuRows() on each open.
///   3. Enable/disable "Remove Current MagnifiCal" by whether another calendar exists.
/// The File menu is found locale-independently by our own "New MagnifiCal" item.
@MainActor final class FileMenuUpdater: NSObject, NSMenuDelegate {
    private weak var engine: CalendarEngine?
    private static let calendarsTag = 0xCA15 // marks OUR inserted "Calendars" item

    func install(engine: CalendarEngine, attempt: Int = 0) {
        self.engine = engine
        if let file = findFileMenu() {
            refresh(file)
            file.delegate = self // re-run on every open (survives SwiftUI rebuilding the menu)
        } else if attempt < 12 { // menu bar not built yet → retry briefly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.install(engine: engine, attempt: attempt + 1)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh(menu)
    }

    private func refresh(_ menu: NSMenu) {
        relocate(menu)
        refreshCalendars(menu)
    }

    /// (Re)build the "Calendars" item: remove any previous instance (SwiftUI rebuilds can shuffle
    /// the menu under us), then insert a fresh AppKit-owned submenu right after "Remove Current".
    private func refreshCalendars(_ menu: NSMenu) {
        guard let engine else { return }
        if let old = menu.items.first(where: { $0.tag == Self.calendarsTag }) {
            menu.removeItem(old)
        }
        let item = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
        item.tag = Self.calendarsTag
        item.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        let sub = NSMenu(title: "Calendars")
        sub.autoenablesItems = false
        for row in engine.calendarMenuRows() {
            let mi = NSMenuItem(title: row.label, action: #selector(pickCalendar(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = row.id as NSString
            mi.state = row.active ? .on : .off // the tick on the open calendar
            sub.addItem(mi)
        }
        item.submenu = sub
        // After "Remove Current MagnifiCal" (spec order: New, Remove, Calendars ▸, Rename); fall back
        // to after "New MagnifiCal", then the top.
        let anchor = menu.items.firstIndex { $0.title == MenuItemID.removeCalendar.title }
            ?? menu.items.firstIndex { $0.title == MenuItemID.newCalendar.title }
        menu.insertItem(item, at: anchor.map { $0 + 1 } ?? 0)
        // Remove Current is pointless with a single calendar (the engine no-ops); SwiftUI's own
        // .disabled can't track this (stale Commands), so set it here at open time.
        if let remove = menu.items.first(where: { $0.title == MenuItemID.removeCalendar.title }) {
            remove.isEnabled = engine.canRemoveCalendar
        }
    }

    @objc private func pickCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        engine?.switchCalendar(to: id) // no-op when it's already the open one
    }

    private func findFileMenu() -> NSMenu? {
        for top in NSApp.mainMenu?.items ?? [] {
            if let sub = top.submenu, sub.items.contains(where: { $0.title == MenuItemID.newCalendar.title }) {
                return sub
            }
        }
        return nil
    }

    /// Collapse the Close and Close All item(s) to exactly one of each, at the bottom (after a
    /// separator, Close first). Idempotent: once they're last, re-running leaves them in place.
    private func relocate(_ menu: NSMenu) {
        let closes = menu.items.filter { isClose($0, all: false) }
        let closeAlls = menu.items.filter { isClose($0, all: true) }
        guard !(closes.isEmpty && closeAlls.isEmpty) else { return }
        for c in closes + closeAlls {
            menu.removeItem(c)
        }
        if menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        if let c = closes.first {
            menu.addItem(c)
        }
        if let ca = closeAlls.first {
            menu.addItem(ca)
        }
    }

    /// `all: false` → Close (⌘W / performClose); `all: true` → Close All (⌥⌘W, or any
    /// "…closeAll…" selector, whatever name SwiftUI gives its injected item).
    private func isClose(_ item: NSMenuItem, all: Bool) -> Bool {
        if item.keyEquivalent == "w",
           item.keyEquivalentModifierMask == (all ? [.command, .option] : [.command]) {
            return true
        }
        guard let action = item.action else { return false }
        return all ? String(describing: action).localizedCaseInsensitiveContains("closeall")
            : action == #selector(NSWindow.performClose(_:))
    }
}

/// ⌘Z / ⌘⇧Z routing. A focused text field / editor keeps its own native undo (via the `undo:`/`redo:`
/// responder-chain selectors); anywhere else, undo the calendar engine directly. Calling the engine
/// directly (rather than sending `undo:` to the chain) means it works even when the canvas isn't first
/// responder — the case that made an inline title rename look un-undoable.
@MainActor private func routeUndoRedo(redo: Bool, engine: CalendarEngine) {
    if engine.inputModalUp {
        return
    } // a blocking modal (delete confirm) is up → ignore undo/redo
    if firstResponderIsTextInput() {
        NSApp.sendAction(NSSelectorFromString(redo ? "redo:" : "undo:"), to: nil, from: nil)
    } else {
        redo ? engine.redo() : engine.undo()
    }
}

/// Is the key window's first responder a text-editing view (field editor, text field, or the notes
/// WKWebView's content view)? Then ⌘Z belongs to it, not the calendar.
@MainActor private func firstResponderIsTextInput() -> Bool {
    guard let r = NSApp.keyWindow?.firstResponder else { return false }
    if r is NSText {
        return true
    }
    let cls = String(describing: type(of: r))
    return cls.contains("TextView") || cls.contains("TextField") || cls.contains("WKContent")
}

/// The "Connectivity" menu's contents: a disabled "Last Synced" line + a "Sync Now" action. A dedicated
/// view so it can observe the engine's `syncMonitor` (@Observable) and refresh the relative-time label.
private struct ConnectivityMenu: View {
    let engine: CalendarEngine
    var body: some View {
        Text(lastSyncedLabel) // plain Text → a disabled info row in the menu
        Button { engine.refreshConnectivity() } label: {
            Label(engine.syncMonitor.isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
        }
        .keyboardShortcut("r", modifiers: .command) // matches AppMenu's .syncNow spec (⌘R, dev shell)
        .disabled(engine.syncMonitor.isSyncing)
    }

    private var lastSyncedLabel: String {
        _ = engine.syncMonitor.minuteTick // depend on the tick so a Today→Yesterday rollover refreshes
        guard engine.syncMonitor.cloudEnabled else { return "iCloud: Local only" }
        guard let at = engine.syncMonitor.lastSyncedAt else { return "Last Sync: never" }
        let cal = Calendar.current
        let time = at.formatted(date: .omitted, time: .shortened) // locale-aware "12:35 PM" / "12:35"
        let day: String = if cal.isDateInToday(at) {
            "Today"
        } else if cal.isDateInYesterday(at) {
            "Yesterday"
        } else {
            at.formatted(date: .abbreviated, time: .omitted)
        }
        return "Last Sync: \(day), \(time)"
    }
}

/// The ⌘I menu command that opens the Calendar AI window. A dedicated view so
/// `@Environment(\.openWindow)` resolves inside the command builder.
private struct OpenAssistantCommand: View {
    let engine: CalendarEngine
    @Environment(\.openWindow) private var openWindow
    /// Published by CalendarView (and by the open callout itself): present while a calendar window
    /// is key → ⌘I toggles the quick-ask callout; absent (menu-bar only / chat window key) → ⌘I
    /// opens the standalone window as before.
    @FocusedBinding(\.assistantCallout) private var callout: Bool?

    var body: some View {
        Button {
            guard !engine.inputModalUp else { return } // blocked while a modal is up
            if callout != nil {
                callout = !(callout ?? false)
            } else {
                openWindow(id: "assistant")
            }
        } label: {
            menuLabel(.openAssistant) // "MagnifiCal AI" + sparkles, from the shared spec
        }
        .modifier(OptionalShortcut(s: MenuItemID.openAssistant.shortcut))
    }
}

/// Help ▸ "MagnifiCal Help" (⌘?) — opens the in-app Help browser window. A dedicated view so
/// `@Environment(\.openWindow)` resolves inside the command builder (mirrors OpenAssistantCommand).
private struct OpenHelpCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "help") } label: { menuLabel(.help) } // "MagnifiCal Help" + icon, from the spec
            .modifier(OptionalShortcut(s: MenuItemID.help.shortcut))
    }
}

/// The menu-bar dropdown. A dedicated view so `@Environment(\.openWindow)` resolves (it isn't
/// reliably populated directly on the `App` type).
private struct MenuBarContent: View {
    let assistant: AssistantState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "assistant") } label: { Label("Open MagnifiCal AI", systemImage: "sparkles") }
        Button { assistant.newChat(); openWindow(id: "assistant") } label: { Label(
            "New Chat",
            systemImage: "square.and.pencil"
        ) }
        Divider()
        Button { openWindow(id: "calendar") } label: { Label("Show MagnifiCal", systemImage: "calendar") }
        SettingsLink { Label("Settings…", systemImage: "gearshape") }
        Divider()
        Button { NSApplication.shared.terminate(nil) } label: { Label("Quit MagnifiCal", systemImage: "power") }
    }
}
