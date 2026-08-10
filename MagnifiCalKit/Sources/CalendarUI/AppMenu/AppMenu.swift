// The SINGLE SOURCE OF TRUTH for the app's menu bar.
//
// Both macOS shells render their menu bar from `AppMenu.sections(...)`:
//   • CalendarApp (the Xcode .app)  → a SwiftUI `Commands` adapter (AppMenuCommands.swift)
//   • CalendarMac (the dev shell)   → an AppKit `NSMenu` adapter    (AppMenuAppKit.swift)
// Because both read this one declaration, the two menu bars cannot silently drift — add or retitle
// an item here and both shells pick it up. Titles, shortcuts, icons, ordering, and the (shared,
// API-agnostic) action for each item all live here.
//
// What is NOT here (genuinely per-target): the *rendering* itself (SwiftUI Button vs NSMenuItem),
// and a few SwiftUI-only host constructs (the Settings scene, the MenuBarExtra status item). The
// Assistant menu + AI item require an assistant session, which only the .app has — so those nodes
// are gated behind `caps.hasAssistant` and simply omitted from the dev shell.

import AppKit
import CalendarEngine

/// ── Shortcut description (API-neutral; each adapter converts to its own modifier type) ──────────
public struct MenuMods: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = MenuMods(rawValue: 1 << 0)
    public static let shift = MenuMods(rawValue: 1 << 1)
    public static let control = MenuMods(rawValue: 1 << 2)
    public static let option = MenuMods(rawValue: 1 << 3)
}

public struct MenuShortcut: Sendable {
    public let key: Character
    public let mods: MenuMods
    public init(_ key: Character, _ mods: MenuMods = .command) {
        self.key = key; self.mods = mods
    }
}

/// ── The plain (button) items. Each carries its own title / shortcut / SF Symbol. ────────────────
public enum MenuItemID: Sendable {
    case about, openAssistant, settings, hide, quit
    case newCalendar, removeCalendar, renameCalendar
    case importICS, importMDC, exportMDC, printCalendar
    case deselectAll
    case goToYear, goToMonth, goToWeek, goToDay
    // View ▸ TODO List (⌘B) / Note Editor (⌘E) / Projects (⌘J) — faces of one coin: focus the
    // dashboard's TODO/NOTE/PROJ tab. Day: focus the tab (⌘E lands in the editor). Month/week:
    // closed → open on that tab; open on another tab → flip; already on that tab → retract.
    case todoList, noteEditor, projList
    case newConversation, currentConversation, apiKeys
    case syncNow
    case help, tutorial, keyboardShortcuts, reportProblem
    case closeWindow, minimize

    public static let appName = "MagnifiCal"

    public var title: String {
        switch self {
        case .about: "About \(Self.appName)"
        case .openAssistant: "\(Self.appName) AI"
        case .settings: "Settings…"
        case .hide: "Hide \(Self.appName)"
        case .quit: "Quit \(Self.appName)"
        case .newCalendar: "New \(Self.appName)"
        case .removeCalendar: "Remove Current \(Self.appName)"
        case .renameCalendar: "Rename Current \(Self.appName)…"
        case .importICS: "Import .ics…"
        case .importMDC: "Import Backup (.mdc)…"
        case .exportMDC: "Export Backup (.mdc)…"
        case .printCalendar: "Print…"
        case .deselectAll: "Deselect All"
        case .goToYear: "Go to Current Year"
        case .goToMonth: "Go to Current Month"
        case .goToWeek: "Go to Current Week"
        case .goToDay: "Go to Current Day"
        case .todoList: "TODO List"
        case .noteEditor: "Note Editor"
        case .projList: "Projects"
        case .newConversation: "New Conversation"
        case .currentConversation: "Current Conversation"
        case .apiKeys: "Configure API Keys…"
        case .syncNow: "Sync Now"
        case .help: "\(Self.appName) Help"
        case .tutorial: "Welcome to \(Self.appName)"
        case .keyboardShortcuts: "Keyboard Shortcuts"
        case .reportProblem: "Report a Problem…"
        case .closeWindow: "Close"
        case .minimize: "Minimize"
        }
    }

    public var shortcut: MenuShortcut? {
        switch self {
        case .openAssistant: MenuShortcut("i")
        case .syncNow: MenuShortcut("r")
        case .settings: MenuShortcut(",")
        case .hide: MenuShortcut("h")
        case .quit: MenuShortcut("q")
        case .printCalendar: MenuShortcut("p")
        case .deselectAll: MenuShortcut("d")
        case .todoList: MenuShortcut("b")
        case .noteEditor: MenuShortcut("e")
        case .projList: MenuShortcut("j")
        case .help: MenuShortcut("?")
        case .closeWindow: MenuShortcut("w")
        case .minimize: MenuShortcut("m")
        default: nil
        }
    }

    /// SF Symbol for the SwiftUI `Label` (AppKit ignores it). nil = no icon.
    public var icon: String? {
        switch self {
        case .openAssistant: "sparkles"
        case .newCalendar: "plus.rectangle.on.rectangle"
        case .removeCalendar: "trash"
        case .renameCalendar: "pencil"
        case .importICS: "calendar.badge.plus"
        case .printCalendar: "printer"
        case .importMDC: "square.and.arrow.down"
        case .exportMDC: "square.and.arrow.up"
        case .deselectAll: "square.dashed"
        // Go to Current — one glyph per zoom level's shape: month lanes, month grid,
        // week columns, the day's hourly timeline.
        case .goToYear: "calendar"
        case .goToMonth: "square.grid.3x3"
        case .goToWeek: "rectangle.split.3x1"
        case .goToDay: "clock"
        case .todoList: "checklist"
        case .noteEditor: "square.and.pencil"
        case .projList: "chart.bar.doc.horizontal"
        case .newConversation: "square.and.pencil"
        case .currentConversation: "bubble.left"
        case .apiKeys: "key"
        case .syncNow: "arrow.triangle.2.circlepath"
        case .help: "questionmark.circle"
        case .tutorial: "graduationcap"
        case .keyboardShortcuts: "keyboard"
        case .reportProblem: "ladybug"
        default: nil
        }
    }
}

/// ── Standard responder-chain Edit items. SwiftUI provides these itself; AppKit wires the selectors. ──
public enum StandardItem: Sendable {
    case undo, redo, cut, copy, paste, selectAll
    public var title: String {
        switch self {
        case .undo: return "Undo"; case .redo: return "Redo"
        case .cut: return "Cut"; case .copy: return "Copy"; case .paste: return "Paste"
        case .selectAll: return "Select All"
        }
    }

    public var shortcut: MenuShortcut {
        switch self {
        case .undo: return MenuShortcut("z")
        case .redo: return MenuShortcut("z", [.command, .shift])
        case .cut: return MenuShortcut("x"); case .copy: return MenuShortcut("c")
        case .paste: return MenuShortcut("v"); case .selectAll: return MenuShortcut("a")
        }
    }

    /// The AppKit responder selector name (SwiftUI routes these automatically).
    public var selector: String {
        switch self {
        case .undo: return "undo:"; case .redo: return "redo:"
        case .cut: return "cut:"; case .copy: return "copy:"; case .paste: return "paste:"
        case .selectAll: return "selectAll:"
        }
    }
}

/// ── Rich controls that each adapter renders in its own idiom (pickers, dynamic submenus, toggles). ──
public enum MenuWidget: Sendable {
    case recentCalendars // File ▸ Calendars ▸ (dynamic submenu: EVERY calendar with its item
    // count, the open one ticked; click switches). Rows come from engine.calendarMenuRows(),
    // rebuilt at menu-open time (NSMenuDelegate) in both shells — SwiftUI Commands can't be
    // trusted to re-render dynamic content, so the .app's FileMenuUpdater owns this item too.
    case showHiddenToggle // View ▸ Show Hidden Imported Events (checkmark)
    case currentTimezone // View ▸ Current Timezone ▸ (picker)
    case altTimezone // View ▸ Alternative Timezone ▸ (picker)
    case tagFilter // View ▸ Filter by Tags ▸ (dynamic submenu)
    case fullScreen // View ▸ Enter/Exit Full Screen (system)
    case assistantModel // Assistant ▸ Model ▸ (picker)
    case syncStatus // Sync ▸ "Last Sync: …" (disabled info row, dynamic)
}

/// ── One node in a menu. ─────────────────────────────────────────────────────────────────────────
public enum MenuNode: Sendable {
    case item(MenuItemID)
    case standard(StandardItem)
    case widget(MenuWidget)
    case separator
}

/// ── A whole menu, tagged with where it lands in each host. ──────────────────────────────────────
public enum MenuPlacement: Sendable { case app, file, edit, view, assistant, sync, window, help }

public struct MenuSection: Sendable {
    public let placement: MenuPlacement
    public let title: String // the menu's title (also the AppKit submenu title)
    public let nodes: [MenuNode]
    public init(_ placement: MenuPlacement, _ title: String, _ nodes: [MenuNode]) {
        self.placement = placement; self.title = title; self.nodes = nodes
    }
}

public struct AppMenuCaps: Sendable {
    /// The host owns an assistant session (only the .app does) → show the AI item + Assistant menu.
    public var hasAssistant: Bool
    public init(hasAssistant: Bool) {
        self.hasAssistant = hasAssistant
    }
}

public enum AppMenu {
    /// THE menu-bar declaration. Both shells build their native menu bar by walking this.
    public static func sections(_ caps: AppMenuCaps) -> [MenuSection] {
        var out: [MenuSection] = []

        // App menu — About / AI / Settings / Hide / Quit. (SwiftUI supplies About·Settings·Hide·Quit
        // itself; its adapter renders only the AI item. AppKit builds the whole thing.)
        var app: [MenuNode] = [.item(.about), .separator]
        if caps.hasAssistant {
            app += [.item(.openAssistant), .separator]
        }
        app += [.item(.settings), .separator, .item(.hide), .item(.quit)]
        out.append(MenuSection(.app, AppName.app, app))

        // File — the open calendar ("document") controls, then import/export + print, and Close at the
        // very bottom (kept out of the way of the calendar/document actions).
        out.append(MenuSection(.file, "File", [
            .item(.newCalendar), .item(.removeCalendar),
            .widget(.recentCalendars),
            .item(.renameCalendar), .separator,
            .item(.importICS), .separator,
            .item(.importMDC), .item(.exportMDC), .separator,
            .item(.printCalendar), .separator,
            .item(.closeWindow),
        ]))

        // Edit — undo/redo, clipboard, (de)select. SwiftUI provides the clipboard + select-all itself;
        // its adapter renders only undo/redo (routed to the engine) and Deselect All.
        out.append(MenuSection(.edit, "Edit", [
            .standard(.undo), .standard(.redo), .separator,
            .standard(.cut), .standard(.copy), .standard(.paste), .separator,
            .standard(.selectAll), .item(.deselectAll),
        ]))

        // View — go-to-today, visibility toggles, timezone pickers, tag filter, full screen.
        out.append(MenuSection(.view, "View", [
            .item(.goToYear), .item(.goToMonth), .item(.goToWeek), .item(.goToDay), .separator,
            .item(.todoList), .item(.noteEditor), .item(.projList),
            .widget(.showHiddenToggle), .separator,
            .widget(.currentTimezone), .widget(.altTimezone), .separator,
            .widget(.tagFilter), .separator,
            .widget(.fullScreen),
        ]))

        // Assistant (app only — the dev shell has no assistant session).
        if caps.hasAssistant {
            out.append(MenuSection(.assistant, "Assistant", [
                .item(.newConversation), .item(.currentConversation), .separator,
                .widget(.assistantModel), .separator,
                .item(.apiKeys),
            ]))
        }

        // Sync — last-synced info + manual refresh.
        out.append(MenuSection(.sync, "Sync", [
            .widget(.syncStatus), .item(.syncNow),
        ]))

        // Window — Minimize (Close lives at the bottom of File; AppKit builds this, SwiftUI manages its own).
        out.append(MenuSection(.window, "Window", [
            .item(.minimize),
        ]))

        // Help — help window, tutorial, shortcut guide, GitHub issue reporter.
        out.append(MenuSection(.help, "Help", [
            .item(.help), .separator,
            .item(.tutorial), .item(.keyboardShortcuts), .separator,
            .item(.reportProblem),
        ]))

        return out
    }
}

private enum AppName { static let app = MenuItemID.appName }
