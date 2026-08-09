// The AppKit adapter: builds a full NSMenu bar from the shared AppMenu spec. Used by the CalendarMac dev
// shell (main.swift just creates a coordinator and calls `install`). Plain items dispatch through the
// shared `runMenuItem`; the rich controls (toggles, timezone pickers, the dynamic tag filter, the sync
// status row) are rendered here in AppKit idiom. This is the one place the dev shell's menu lives — it
// stays in lockstep with the .app because both read AppMenu.sections(...).

import AppKit
import CalendarEngine

@MainActor public final class AppMenuCoordinator: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private let ctx: MenuContext
    /// Boxes a MenuItemID onto an NSMenuItem (enums can't be a representedObject directly).
    private final class IDBox { let id: MenuItemID; init(_ id: MenuItemID) {
        self.id = id
    } }

    // Dynamic Sync menu state, refreshed when the menu opens.
    private weak var syncMenu: NSMenu?
    private weak var syncStatusItem: NSMenuItem?
    // Dynamic File menu state (multi-calendar): the Calendars submenu.
    private weak var fileMenu: NSMenu?
    private weak var recentCalendarsMenu: NSMenu?

    public init(ctx: MenuContext) {
        self.ctx = ctx
    }

    /// Build the menu bar from the spec and install it as `NSApp.mainMenu`.
    public func install(caps: AppMenuCaps) {
        let main = NSMenu()
        for section in AppMenu.sections(caps) {
            let holder = NSMenuItem()
            main.addItem(holder)
            let sub = NSMenu(title: section.title)
            holder.submenu = sub
            // Leave autoenablesItems at its default (true) so the Edit menu's responder-chain items
            // (cut/copy/paste/undo/selectAll) gray out when nothing handles them. Dynamic submenus that
            // manage their own enablement (tag filter, timezone pickers) set it false themselves.
            for node in section.nodes {
                add(node, to: sub, placement: section.placement)
            }
            switch section.placement {
            case .window: NSApp.windowsMenu = sub
            case .help: NSApp.helpMenu = sub
            case .sync: syncMenu = sub; sub.delegate = self // refresh "Last Sync: …"
            case .file: fileMenu = sub; sub.delegate = self // (Calendars submenu refreshes via its own delegate)
            default: break
            }
        }
        NSApp.mainMenu = main
    }

    /// ── Node rendering ──────────────────────────────────────────────────────────────────────────
    private func add(_ node: MenuNode, to menu: NSMenu, placement: MenuPlacement) {
        switch node {
        case .separator:
            menu.addItem(.separator())
        case let .item(id):
            let mi = menu.addItem(withTitle: id.title, action: #selector(fire(_:)),
                                  keyEquivalent: keyChar(id.shortcut))
            mi.keyEquivalentModifierMask = flags(id.shortcut)
            mi.target = self
            mi.representedObject = IDBox(id)
        case let .standard(std):
            // Responder-chain items (undo:/redo:/cut:/… ) — no target, AppKit routes to the focused view.
            let mi = menu.addItem(withTitle: std.title, action: NSSelectorFromString(std.selector),
                                  keyEquivalent: String(std.shortcut.key))
            mi.keyEquivalentModifierMask = flags(std.shortcut)
        case let .widget(w):
            addWidget(w, to: menu)
        }
    }

    private func addWidget(_ w: MenuWidget, to menu: NSMenu) {
        switch w {
        case .recentCalendars:
            let item = menu.addItem(withTitle: "Calendars", action: nil, keyEquivalent: "")
            let rm = NSMenu(title: "Calendars")
            rm.delegate = self
            rm.autoenablesItems = false
            item.submenu = rm
            recentCalendarsMenu = rm
        case .showHiddenToggle:
            let mi = menu.addItem(withTitle: "Show Hidden Imported Events",
                                  action: #selector(toggleShowHidden(_:)), keyEquivalent: "")
            mi.target = self
        case .currentTimezone:
            addTimezonePicker(to: menu, title: "Current Timezone", key: PrefKeys.mainTz,
                              includeNone: false, defaultId: CalendarTimezones.autoId)
        case .altTimezone:
            addTimezonePicker(to: menu, title: "Alternative Timezone", key: PrefKeys.altTz,
                              includeNone: true, defaultId: "none")
        case .tagFilter:
            // A menu can't stay open while multi-toggling on macOS, so this opens the tag-filter popover
            // (in CalendarView's toolbar) via a notification — identical to the .app's View menu.
            let mi = menu.addItem(
                withTitle: "Filter by Tags…",
                action: #selector(openTagFilter(_:)),
                keyEquivalent: "g"
            )
            mi.target = self // default modifier mask = ⌘ → ⌘G toggles the popover
        case .fullScreen:
            let mi = menu.addItem(withTitle: "Enter Full Screen",
                                  action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            mi.keyEquivalentModifierMask = [.control, .command]
        case .syncStatus:
            let mi = menu.addItem(withTitle: "Last Sync: …", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            syncStatusItem = mi
        case .assistantModel:
            break // dev shell has no assistant session (Assistant menu is gated off there)
        }
    }

    /// ── Shortcut conversion (spec → AppKit) ───────────────────────────────────────────────────────
    private func keyChar(_ s: MenuShortcut?) -> String {
        s.map { String($0.key) } ?? ""
    }

    private func flags(_ s: MenuShortcut?) -> NSEvent.ModifierFlags {
        s.map { flags($0.mods) } ?? []
    }

    private func flags(_ m: MenuMods) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) {
            f.insert(.command)
        }
        if m.contains(.shift) {
            f.insert(.shift)
        }
        if m.contains(.control) {
            f.insert(.control)
        }
        if m.contains(.option) {
            f.insert(.option)
        }
        return f
    }

    /// ── Plain-item dispatch ───────────────────────────────────────────────────────────────────────
    @objc private func fire(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? IDBox else { return }
        runMenuItem(box.id, ctx)
    }

    /// ── Show Hidden Imported Events (checkmark toggle) ─────────────────────────────────────────────
    @objc private func toggleShowHidden(_ sender: NSMenuItem) {
        let key = PrefKeys.showHiddenImported
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        NotificationCenter.default.post(name: .calendarViewPrefsChanged, object: nil)
    }

    /// ── Timezone pickers (submenu of checkmarked zones writing a pref) ────────────────────────────
    private func addTimezonePicker(to menu: NSMenu, title: String, key: String,
                                   includeNone: Bool, defaultId: String) {
        let parent = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        parent.submenu = sub
        let current = UserDefaults.standard.string(forKey: key) ?? defaultId
        if includeNone {
            addZone(to: sub, key: key, id: "none", label: "None", current: current)
            sub.addItem(.separator())
        }
        // The alt picker omits "Automatic" (that would equal the current zone).
        for z in CalendarTimezones.all where !(includeNone && z.id == CalendarTimezones.autoId) {
            addZone(to: sub, key: key, id: z.id, label: z.label, current: current)
        }
    }

    private func addZone(to menu: NSMenu, key: String, id: String, label: String, current: String) {
        let mi = menu.addItem(withTitle: label, action: #selector(pickZone(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = ZonePick(key: key, id: id)
        mi.state = (id == current) ? .on : .off
    }

    private final class ZonePick {
        let key: String; let id: String; init(key: String, id: String) {
            self.key = key; self.id = id
        }
    }

    @objc private func pickZone(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? ZonePick else { return }
        UserDefaults.standard.set(p.id, forKey: p.key)
        NotificationCenter.default.post(name: .calendarViewPrefsChanged, object: nil)
    }

    /// ── Filter by Tags → open the stay-open popover (hosted in CalendarView's toolbar) ────────────
    @objc private func openTagFilter(_ sender: Any?) {
        NotificationCenter.default.post(name: .toggleTagFilter, object: nil)
    }

    /// ── validation + dynamic submenus ─────────────────────────────────────────────────────────────
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleShowHidden(_:)) {
            item.state = UserDefaults.standard.bool(forKey: PrefKeys.showHiddenImported) ? .on : .off
        }
        // "Remove Current MagnifiCal" is disabled when it's the only calendar.
        if let box = item.representedObject as? IDBox, box.id == .removeCalendar {
            return ctx.engine()?.canRemoveCalendar ?? false
        }
        // TODO: List / Note Editor / Projects (⌘B/⌘E/⌘J): dashboard tab focus — enabled wherever
        // the dashboard is reachable (day always; month/week can open it), never at year or
        // under the drawer.
        if let box = item.representedObject as? IDBox,
           box.id == .todoList || box.id == .noteEditor || box.id == .projList {
            guard let e = ctx.engine() else { return false }
            return e.chrome.level >= 1 && !e.drawerOpen
        }
        return true
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === syncMenu {
            refreshSyncStatus()
        }
        if menu === recentCalendarsMenu {
            rebuildRecents(menu)
        }
    }

    /// ── Calendars ▸ (dynamic; EVERY calendar with its item count, the open one ticked) ────────────
    private final class RecentPick { let id: String; init(_ id: String) {
        self.id = id
    } }
    private func rebuildRecents(_ menu: NSMenu) {
        menu.removeAllItems()
        for row in ctx.engine()?.calendarMenuRows() ?? [] {
            let mi = menu.addItem(withTitle: row.label, action: #selector(switchToRecent(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = RecentPick(row.id)
            mi.state = row.active ? .on : .off
        }
    }

    @objc private func switchToRecent(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? RecentPick else { return }
        ctx.engine()?.switchCalendar(to: p.id)
    }

    /// ── Sync status (dev-shell mirror of ConnectivityMenu's label) ────────────────────────────────
    private func refreshSyncStatus() {
        syncStatusItem?.title = lastSyncedLabel
    }

    private var lastSyncedLabel: String {
        guard let mon = ctx.engine()?.syncMonitor else { return "iCloud: Local only" }
        guard mon.cloudEnabled else { return "iCloud: Local only" }
        guard let at = mon.lastSyncedAt else { return "Last Sync: never" }
        let cal = Calendar.current
        let time = at.formatted(date: .omitted, time: .shortened)
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
