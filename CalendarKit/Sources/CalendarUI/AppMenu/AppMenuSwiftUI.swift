// SwiftUI menu pieces shared by the CalendarApp Commands adapter. Everything here reads titles /
// shortcuts / icons from the AppMenu spec so the .app's menu bar can't drift from the dev shell's.
// The View-menu payload (go-to-today, show-hidden, timezone pickers, tag filter) lives here too, so
// both the item set AND the widgets are defined once.

import CalendarEngine
import SwiftUI

/// ── Shortcut conversion (spec → SwiftUI) ────────────────────────────────────────────────────────
public extension MenuShortcut {
    var swiftUIKey: KeyEquivalent {
        KeyEquivalent(key)
    }

    var swiftUIModifiers: EventModifiers {
        var m: EventModifiers = []
        if mods.contains(.command) {
            m.insert(.command)
        }
        if mods.contains(.shift) {
            m.insert(.shift)
        }
        if mods.contains(.control) {
            m.insert(.control)
        }
        if mods.contains(.option) {
            m.insert(.option)
        }
        return m
    }
}

/// Applies a MenuShortcut as a `.keyboardShortcut`, or nothing when the item has none.
public struct OptionalShortcut: ViewModifier {
    let s: MenuShortcut?
    public init(s: MenuShortcut?) {
        self.s = s
    }

    public func body(content: Content) -> some View {
        if let s {
            content.keyboardShortcut(s.swiftUIKey, modifiers: s.swiftUIModifiers)
        } else {
            content
        }
    }
}

/// A menu button for a "plain" item whose action is pure (engine call / notification post — no window
/// opening). Label, icon, and shortcut all come from the spec. Used for Print, Deselect All, the
/// Go-to-Current group, Sync Now, Tutorial, and Keyboard Shortcuts.
public struct MenuActionButton: View {
    let id: MenuItemID
    let engine: CalendarEngine
    public init(_ id: MenuItemID, engine: CalendarEngine) {
        self.id = id; self.engine = engine
    }

    public var body: some View {
        Button {
            runMenuItem(id, MenuContext(engine: { engine }, open: { _ in }))
        } label: { menuLabel(id) }
            .modifier(OptionalShortcut(s: id.shortcut))
    }
}

/// ── File menu: multiple-calendars payload (shared) ──────────────────────────────────────────────
/// The STATIC calendar ("document") controls at the top of the File menu: New/Remove/Rename (they
/// post notifications → CalendarView shows a dialog). The DYNAMIC "Calendars" submenu (every
/// calendar with its item count, the open one ticked) is deliberately NOT rendered here: macOS
/// SwiftUI Commands don't reliably re-evaluate dynamic content (@Observable *and* @AppStorage
/// triggers both left it stale), so the .app's FileMenuUpdater (CalendarApp.swift) builds that
/// item in AppKit on every menu open — the same mechanism the dev shell uses (menuNeedsUpdate).
public struct CalendarMenuContent: View {
    let engine: CalendarEngine
    public init(engine: CalendarEngine) {
        self.engine = engine
    }

    public var body: some View {
        MenuActionButton(.newCalendar, engine: engine)
        MenuActionButton(.removeCalendar, engine: engine)
        MenuActionButton(.renameCalendar, engine: engine)
    }
}

/// ── View menu payload (shared) ──────────────────────────────────────────────────────────────────
/// The full contents of the View menu, minus the system-provided Enter/Exit Full Screen (SwiftUI adds
/// that itself). Ordering mirrors AppMenu.sections(...)'s `.view` section.
public struct ViewMenuContent: View {
    let engine: CalendarEngine
    @AppStorage(PrefKeys.showHiddenImported) private var showHidden = false
    @AppStorage(PrefKeys.mainTz) private var mainTz = CalendarTimezones.autoId
    @AppStorage(PrefKeys.altTz) private var altTz = "none"
    public init(engine: CalendarEngine) {
        self.engine = engine
    }

    public var body: some View {
        MenuActionButton(.goToYear, engine: engine)
        MenuActionButton(.goToMonth, engine: engine)
        MenuActionButton(.goToWeek, engine: engine)
        MenuActionButton(.goToDay, engine: engine)
        Divider()
        // TODO: List / Note Editor (⌘B/⌘E): focus the dashboard's tab — the open/flip/retract state
        // machine lives in CalendarView (it owns the tab state), reached via notification in both
        // shells. Enabled wherever the dashboard is reachable (never at year / under the drawer).
        Button { NotificationCenter.default.post(name: .focusDashTodo, object: nil) } label: {
            Label("TODO List", systemImage: "checklist")
        }
        .keyboardShortcut("b", modifiers: .command)
        .disabled(engine.chrome.level < 1 || engine.chrome.drawerOpen)
        Button { NotificationCenter.default.post(name: .focusDashNote, object: nil) } label: {
            Label("Note Editor", systemImage: "square.and.pencil")
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(engine.chrome.level < 1 || engine.chrome.drawerOpen)
        Button { NotificationCenter.default.post(name: .focusDashProj, object: nil) } label: {
            Label("Projects", systemImage: "chart.bar.doc.horizontal")
        }
        .keyboardShortcut("j", modifiers: .command)
        .disabled(engine.chrome.level < 1 || engine.chrome.drawerOpen)
        Toggle(isOn: $showHidden) { Label("Show Hidden Imported Events", systemImage: "eye.slash") }
        Divider()
        Picker(selection: $mainTz) {
            ForEach(CalendarTimezones.all) { Text($0.label).tag($0.id) }
        } label: { Label("Current Timezone", systemImage: "clock") }
        Picker(selection: $altTz) {
            Text("None").tag("none")
            ForEach(CalendarTimezones.all.filter { $0.id != CalendarTimezones.autoId }) { Text($0.label).tag($0.id) }
        } label: { Label("Alternative Timezone", systemImage: "globe") }
        Divider()
        // A menu can't host a stay-open checklist on macOS, so this just toggles the tag-filter popover
        // (anchored to its toolbar button in CalendarView) via a notification — same in both shells.
        Button { NotificationCenter.default.post(name: .toggleTagFilter, object: nil) } label: {
            Label("Filter by Tags…", systemImage: "tag")
        }
        .keyboardShortcut("g", modifiers: .command)
    }
}
