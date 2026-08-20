// Dashboard TODO layering: per-scope (day/week/month) preferences for WHICH SOURCES feed the
// list (event notes / daily / weekly / monthly notes), which COLLECTIONS (sections) render, and
// whether the deadlines section shows. One prefs value per dashboard scope, persisted together
// in UserDefaults and pushed to the dashboard WebView as JSON (CK.setTodoPrefs); the section and
// (source KEYS once mirrored the retired webview dashboard's; now native-only.)
//
// The menu (Display Deadlines / Show Collections ▸ / Collect from… ▸) is single-sourced from the
// catalog below; the macOS NSMenu builder lives in CalendarUI/DashTodoMenu.swift (this file is
// cross-platform — the iPhone drawer reads the same catalog + settings).

import Foundation
import SwiftUI

/// Which dashboard tab a panel body shows. Shared chrome vocabulary across the Mac's pinned
/// panels (DashChrome/NativePanelHost) and the iPhone drawer.
public enum DashTab: Hashable {
    case todo, note, proj
}

public enum DashTodoScope: String, CaseIterable {
    case day, week, month
}

public struct DashTodoPrefs: Codable, Equatable {
    public var deadlines: Bool
    public var sections: Set<String>
    public var sources: Set<String>
}

/// The single source of truth for keys + menu labels (JS filters by the same keys).
public enum DashTodoCatalog {
    public static let sources: [(key: String, label: String)] = [
        ("event", "Event Notes"),
        ("daily", "Daily Notes"),
        ("weekly", "Weekly Notes"),
        ("monthly", "Monthly Notes"),
    ]

    /// Collections are dashboard-scope-dependent: the day view's six day-relative sections vs.
    /// the week/month range panels' open/completed pair.
    public static func sections(for scope: DashTodoScope) -> [(key: String, label: String)] {
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
    public static func defaults(_ scope: DashTodoScope) -> DashTodoPrefs {
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
