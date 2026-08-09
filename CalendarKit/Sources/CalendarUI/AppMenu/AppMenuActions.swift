// The shared, API-agnostic behavior behind each plain menu item. Both the SwiftUI and AppKit adapters
// call `runMenuItem` so an item does exactly the same thing in both shells. Everything here is either a
// NotificationCenter post, an engine call, a UserDefaults flip, or an NSApp/window action — all of which
// work identically from either host. Window-opening is the one host-specific bit, injected as a closure.

import AppKit
import CalendarEngine
import CalendarGeometry // isoDayString
import SwiftUI
import UniformTypeIdentifiers

/// Which host window a menu action wants to summon (opened differently per shell).
public enum MenuWindow: Sendable { case assistant, help, settings }

/// The host-provided hooks the shared actions need. `engine` is a getter (the AppKit shell resolves it
/// lazily via `CalendarEngine.mainInstance`; the .app captures its live instance).
@MainActor public struct MenuContext {
    public var engine: () -> CalendarEngine?
    public var open: (MenuWindow) -> Void
    public var newChat: () -> Void
    public var showAbout: () -> Void
    public init(engine: @escaping () -> CalendarEngine?,
                open: @escaping (MenuWindow) -> Void,
                newChat: @escaping () -> Void = {},
                showAbout: @escaping () -> Void = {}) {
        self.engine = engine; self.open = open; self.newChat = newChat; self.showAbout = showAbout
    }
}

/// Run a plain menu item's action. Identical behavior in both shells.
@MainActor public func runMenuItem(_ id: MenuItemID, _ ctx: MenuContext) {
    switch id {
    case .about: ctx.showAbout()
    case .openAssistant: ctx.open(.assistant)
    case .settings: ctx.open(.settings)
    case .hide: NSApp.hide(nil)
    case .quit: NSApp.terminate(nil)
    case .newCalendar: NotificationCenter.default.post(name: .newCalendar, object: nil)
    case .removeCalendar: NotificationCenter.default.post(name: .removeCalendar, object: nil)
    case .renameCalendar: NotificationCenter.default.post(name: .renameCalendar, object: nil)
    case .importICS: if let e = ctx.engine() {
            MenuFileActions.importICS(e)
        }
    case .importMDC: if let e = ctx.engine() {
            MenuFileActions.importMDC(e)
        }
    case .exportMDC: if let e = ctx.engine() {
            MenuFileActions.exportMDC(e)
        }
    case .printCalendar: NotificationCenter.default.post(name: .requestPrint, object: nil)
    case .deselectAll: ctx.engine()?.deselectAll()
    case .goToYear: ctx.engine()?.goToCurrent("year")
    case .goToMonth: ctx.engine()?.goToCurrent("month")
    case .goToWeek: ctx.engine()?.goToCurrent("week")
    case .goToDay: ctx.engine()?.goToCurrent("day")
    case .todoList: NotificationCenter.default.post(name: .focusDashTodo, object: nil)
    case .noteEditor: NotificationCenter.default.post(name: .focusDashNote, object: nil)
    case .projList: NotificationCenter.default.post(name: .focusDashProj, object: nil)
    case .newConversation: ctx.newChat(); ctx.open(.assistant)
    case .currentConversation: ctx.open(.assistant)
    case .apiKeys: ctx.open(.settings)
    case .syncNow: ctx.engine()?.refreshConnectivity()
    case .help: ctx.open(.help)
    case .tutorial: NotificationCenter.default.post(name: .showTutorial, object: nil)
    case .keyboardShortcuts: NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
    case .closeWindow: NSApp.keyWindow?.performClose(nil)
    case .minimize: NSApp.keyWindow?.performMiniaturize(nil)
    case .reportProblem: openProblemReport()
    }
}

/// The public repo's issue tracker (see docs/release-roadmap.md — created when the
/// project open-sources; the menu item simply 404s to the profile until then).
private let githubRepoURL = "https://github.com/liby99/MagnifiCal"

/// Help ▸ Report a Problem… → a prefilled GitHub issue with the environment block filled
/// in (app version, macOS) so friends' reports arrive triageable without back-and-forth.
@MainActor private func openProblemReport() {
    let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let body = """
    <!-- What happened? Steps to reproduce, what you expected, what you saw. -->


    ---
    MagnifiCal \(app) · \(os)
    """
    var c = URLComponents(string: "\(githubRepoURL)/issues/new")!
    c.queryItems = [URLQueryItem(name: "body", value: body)]
    if let url = c.url {
        NSWorkspace.shared.open(url)
    }
}

/// ── File ▸ import/export. AppKit panels + alerts; the work is on the engine. Shared so both the SwiftUI
///    FileCommands view and the AppKit menu run the exact same code. ─────────────────────────────────
@MainActor public enum MenuFileActions {
    public static func importICS(_ engine: CalendarEngine) {
        guard let url = openPanel([UTType(filenameExtension: "ics") ?? .plainText, .plainText]) else { return }
        do {
            let n = try engine.importICS(from: url)
            info("Imported \(n) item\(n == 1 ? "" : "s") from “\(url.lastPathComponent)”.")
        } catch { report("Couldn’t import that .ics file.", error) }
    }

    /// Drag-and-drop import (the main window's .ics drop target): several files at once, ONE
    /// summary alert. File ▸ Import stays single-file via the open panel above.
    public static func importICSFiles(_ urls: [URL], engine: CalendarEngine) {
        let ics = urls.filter { $0.pathExtension.lowercased() == "ics" }
        guard !ics.isEmpty else { return }
        var total = 0
        var failed: [String] = []
        for url in ics {
            // Dropped-file URLs carry a sandbox extension; scope access around the read.
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                total += try engine.importICS(from: url)
            } catch {
                failed.append(url.lastPathComponent)
            }
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let from = ics.count == 1 ? "“\(ics[0].lastPathComponent)”" : "\(ics.count) files"
        if failed.isEmpty {
            info("Imported \(total) item\(total == 1 ? "" : "s") from \(from).")
        } else {
            info("Imported \(total) item\(total == 1 ? "" : "s"); couldn’t read "
                + failed.joined(separator: ", ") + ".")
        }
    }

    public static func importMDC(_ engine: CalendarEngine) {
        // .mgc = MaGiCal backup (current); .mdc = the legacy MaDoCal name; .zip = the web export.
        let mgc = UTType(filenameExtension: "mgc") ?? .data
        let mdc = UTType(filenameExtension: "mdc") ?? .data
        guard let url = openPanel([mgc, mdc, .zip]) else { return }
        let a = NSAlert()
        a.messageText = "Replace all calendar data?"
        a.informativeText = "Importing “\(url.lastPathComponent)” replaces your current events, deadlines, notes, and track names with the backup’s contents. You can undo this with ⌘Z."
        a.alertStyle = .warning
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try engine.importMDC(from: url) }
        catch { report("Couldn’t import that backup.", error) }
    }

    public static func exportMDC(_ engine: CalendarEngine) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mgc") ?? .data]
        panel.nameFieldStringValue = "MagnifiCal-\(isoDayString()).mgc"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.exportMDC(to: url) }
        catch { report("Couldn’t export the backup.", error) }
    }

    private static func openPanel(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func info(_ text: String) {
        let a = NSAlert(); a.messageText = text; a.alertStyle = .informational; a.addButton(withTitle: "OK"); a
            .runModal()
    }

    private static func report(_ text: String, _ error: Error) {
        let a = NSAlert(); a.messageText = text
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning; a.addButton(withTitle: "OK"); a.runModal()
    }
}
