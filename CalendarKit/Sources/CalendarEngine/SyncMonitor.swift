// Observable "last synced" state for the Connectivity menu. The engine + CloudSync are plain (non-
// @Observable) types, so this small object is the one bit the SwiftUI menu watches: it holds the last
// successful iCloud round-trip time and ticks once a minute so an open menu's "X minutes ago" stays fresh.

import Foundation
import Observation

@MainActor @Observable public final class SyncMonitor {
    private static let lastAtKey = "cc.sync.lastAt"

    /// Last time a CloudKit fetch/send completed successfully (nil = never this account). Persisted so
    /// "last synced N minutes ago" survives relaunch.
    public var lastSyncedAt: Date?
    /// A currently-running manual "Sync Now" (drives the menu's disabled/label state).
    public var isSyncing = false
    /// Bumped every minute so views observing this object re-render their relative-time label.
    public var minuteTick = 0

    /// True only when this build is signed with the iCloud entitlement — otherwise sync never runs and
    /// the menu shows "local only". Mirrors CloudSync.isEntitled without importing CloudKit here.
    public let cloudEnabled: Bool

    private var ticker: Timer?

    public init(cloudEnabled: Bool) {
        self.cloudEnabled = cloudEnabled
        let t = UserDefaults.standard.double(forKey: Self.lastAtKey)
        if t > 0 {
            lastSyncedAt = Date(timeIntervalSince1970: t)
        }
        // A once-a-minute wake so the relative label ("5 minutes ago") advances on its own.
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.minuteTick &+= 1 }
        }
    }

    /// Record a successful sync as "now" and persist it.
    public func markSynced(_ when: Date = Date()) {
        lastSyncedAt = when
        UserDefaults.standard.set(when.timeIntervalSince1970, forKey: Self.lastAtKey)
    }
}
