// Dashboard TODO layering: per-scope (day/week/month) preferences for WHICH SOURCES feed the
// list (event notes / daily / weekly / monthly notes), which COLLECTIONS (sections) render, and
// whether the deadlines section shows. One prefs value per dashboard scope, persisted together
// in UserDefaults and pushed to the dashboard WebView as JSON (CK.setTodoPrefs); the section and
// (source KEYS once mirrored the retired webview dashboard's; now native-only.)
//
// The menu (Display Deadlines / Show Collections ▸ / Collect from… ▸) is single-sourced from the
// catalog below and built as ONE AppKit NSMenu, popped from both entry points: the cog button at
// the panel's bottom-right, and a right-click inside the TODO panel (PassThroughWebView).

import AppKit
import Foundation
import SwiftUI

public enum DashTodoScope: String, CaseIterable {
    case day, week, month
}

public struct DashTodoPrefs: Codable, Equatable {
    public var deadlines: Bool
    public var sections: Set<String>
    public var sources: Set<String>
}

/// The single source of truth for keys + menu labels (JS filters by the same keys).
enum DashTodoCatalog {
    static let sources: [(key: String, label: String)] = [
        ("event", "Event Notes"),
        ("daily", "Daily Notes"),
        ("weekly", "Weekly Notes"),
        ("monthly", "Monthly Notes"),
    ]

    /// Collections are dashboard-scope-dependent: the day view's six day-relative sections vs.
    /// the week/month range panels' open/completed pair.
    static func sections(for scope: DashTodoScope) -> [(key: String, label: String)] {
        switch scope {
        case .day: [
                ("dueDay", "Due This Day"),
                ("overdue", "Overdue"),
                ("followup", "Remember to Followup"),
                ("highSoon", "High Priority · Due Soon"),
                ("dueSoon", "Due Soon"),
                ("done", "Recently Completed"),
            ]
        case .week: [
                ("open", "TODOs This Week"),
                ("done", "Completed This Week"),
            ]
        case .month: [
                ("open", "TODOs This Month"),
                ("done", "Completed This Month"),
            ]
        }
    }

    /// Defaults: everything shown, but each scope only collects DOWN to its own granularity —
    /// day skips weekly+monthly notes, week skips monthly, month collects all four.
    static func defaults(_ scope: DashTodoScope) -> DashTodoPrefs {
        let srcs: Set<String> = switch scope {
        case .day: ["event", "daily"]
        case .week: ["event", "daily", "weekly"]
        case .month: ["event", "daily", "weekly", "monthly"]
        }
        return DashTodoPrefs(deadlines: true,
                             sections: Set(sections(for: scope).map(\.key)),
                             sources: srcs)
    }
}

/// The persisted per-scope prefs. @Observable so a menu toggle re-renders the SwiftUI hosts,
/// which re-push the JSON to the WebView (Coordinator diffing keeps that cheap).
@MainActor @Observable public final class DashTodoSettings {
    private static let defaultsKey = "cc.dashTodoPrefs"
    private var byScope: [String: DashTodoPrefs]

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: DashTodoPrefs].self, from: data) {
            byScope = decoded
        } else {
            byScope = [:]
        }
    }

    public subscript(_ scope: DashTodoScope) -> DashTodoPrefs {
        get { byScope[scope.rawValue] ?? DashTodoCatalog.defaults(scope) }
        set {
            byScope[scope.rawValue] = newValue
            if let data = try? JSONEncoder().encode(byScope) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }
}

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
