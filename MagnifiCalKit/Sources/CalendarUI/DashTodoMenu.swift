// The dashboard TODO layering menu as ONE AppKit NSMenu (macOS only), popped from both entry
// points: the cog button at the panel's bottom-right (CogMenuButton) and a right-click inside
// the TODO panel. Single-sourced from DashTodoCatalog, writing through DashTodoSettings — both
// live in CalendarRender now (shared with the iPhone drawer); only this NSMenu shell is AppKit.
// Split from DashTodoPrefs.swift when the prefs types moved to CalendarRender.

import AppKit
import Foundation

/// Builds + owns the native callout menu. Long-lived (NSMenuItem.target is weak — a throwaway
/// builder would deallocate mid-tracking); the menu itself is rebuilt fresh on every pop so the
/// checkmarks always reflect the CURRENT scope's prefs.
@MainActor public final class DashTodoMenuController: NSObject {
    private let settings: DashTodoSettings
    private let scope: () -> DashTodoScope

    public init(settings: DashTodoSettings, scope: @escaping () -> DashTodoScope) {
        self.settings = settings
        self.scope = scope
    }

    public func menu() -> NSMenu {
        let sc = scope()
        let p = settings[sc]
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(item("Display Deadlines", token: "deadlines", on: p.deadlines))
        let cols = NSMenuItem(title: "Show Collections", action: nil, keyEquivalent: "")
        let colMenu = NSMenu()
        colMenu.autoenablesItems = false
        for s in DashTodoCatalog.sections(for: sc) {
            colMenu.addItem(item(s.label, token: "sec:\(s.key)", on: p.sections.contains(s.key)))
        }
        cols.submenu = colMenu
        m.addItem(cols)
        let from = NSMenuItem(title: "Collect from…", action: nil, keyEquivalent: "")
        let fromMenu = NSMenu()
        fromMenu.autoenablesItems = false
        for s in DashTodoCatalog.sources {
            fromMenu.addItem(item(s.label, token: "src:\(s.key)", on: p.sources.contains(s.key)))
        }
        from.submenu = fromMenu
        m.addItem(from)
        return m
    }

    private func item(_ title: String, token: String, on: Bool) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = token
        it.state = on ? .on : .off
        return it
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        let sc = scope()
        var p = settings[sc]
        func flip(_ set: inout Set<String>, _ key: String) {
            if set.contains(key) {
                set.remove(key)
            } else {
                set.insert(key)
            }
        }
        if token == "deadlines" {
            p.deadlines.toggle()
        } else if token.hasPrefix("sec:") {
            flip(&p.sections, String(token.dropFirst(4)))
        } else if token.hasPrefix("src:") {
            flip(&p.sources, String(token.dropFirst(4)))
        }
        settings[sc] = p
    }
}
