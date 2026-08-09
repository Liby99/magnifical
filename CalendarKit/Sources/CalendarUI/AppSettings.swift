// App-wide preferences that need one code path shared between the SwiftUI settings tab and
// the AppKit launch bootstrap. Right now that's just the appearance override.
//
// The calendar re-themes automatically: CalendarView reads @Environment(\.colorScheme) and
// rebuilds Theme(dark:) every frame, so forcing NSApp.appearance is all it takes — no other
// plumbing. Persisted in UserDefaults under `appearanceDefaultsKey` (matching the app's
// existing "cc." @AppStorage convention).

import AppKit
import Foundation

/// User's chosen appearance. `.auto` follows the system setting (NSApp.appearance = nil).
public enum AppearanceMode: String, CaseIterable, Sendable {
    case auto, light, dark

    /// Label for the segmented picker.
    public var label: String {
        switch self {
        case .auto: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// UserDefaults key for the persisted appearance choice.
public let appearanceDefaultsKey = "cc.appearance"

/// Force the whole app to the given appearance (or hand it back to the system for `.auto`).
/// Uses `NSApplication.shared` (non-optional) rather than the implicitly-unwrapped `NSApp`,
/// so it can't nil-crash if invoked before the app is fully up.
@MainActor public func applyAppearance(_ mode: AppearanceMode) {
    let app = NSApplication.shared
    switch mode {
    case .auto: app.appearance = nil
    case .light: app.appearance = NSAppearance(named: .aqua)
    case .dark: app.appearance = NSAppearance(named: .darkAqua)
    }
}

/// Apply the persisted choice straight from UserDefaults — used at launch so a saved Light/Dark
/// preference is in effect before the first frame paints.
@MainActor public func applyPersistedAppearance() {
    let raw = UserDefaults.standard.string(forKey: appearanceDefaultsKey) ?? AppearanceMode.auto.rawValue
    applyAppearance(AppearanceMode(rawValue: raw) ?? .auto)
}

// ── iCloud sync for preferences ─────────────────────────────────────────────────────
// Settings live in UserDefaults (via @AppStorage). This mirrors a small allow-list of them
// to iCloud's key-value store (NSUbiquitousKeyValueStore) so they follow the user across
// devices signed in to the same Apple ID — the right iCloud mechanism for a handful of
// preferences (the CKSyncEngine pipeline in CalendarEngine is for the calendar data model).
//
// Only the signed app carries the ubiquity-kvstore entitlement; on the unsigned dev binary
// the store simply never syncs and settings stay local — the same graceful degradation as
// the CloudKit calendar sync. No conflict logic needed: KVS is last-writer-wins per key.

/// UserDefaults keys that should follow the user across their devices via iCloud.
/// (API keys are deliberately NOT here — they aren't persisted, and secrets shouldn't sync.)
public let syncedPrefKeys: [String] = [appearanceDefaultsKey]

@MainActor
public final class PrefsSync {
    public static let shared = PrefsSync()
    private let store = NSUbiquitousKeyValueStore.default
    private var started = false

    private init() {}

    /// Reconcile with iCloud and start observing changes in both directions. Idempotent and
    /// safe to call very early (e.g. a SwiftUI App's `init()`): it touches only UserDefaults,
    /// NotificationCenter, and the KVS — never `NSApp`. The caller applies the reconciled
    /// appearance separately, once the app is up (see `applyPersistedAppearance()`), because
    /// forcing `NSApp.appearance` before launch would crash.
    public func start() {
        guard !started else { return }
        started = true

        // Inbound: another device (or the initial iCloud fetch) changed a synced pref.
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store
        )
        // Outbound: a local @AppStorage write should propagate up to iCloud.
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil
        )

        store.synchronize() // kick off the iCloud fetch
        adoptFromCloud(syncedPrefKeys) // adopt anything already cached locally by KVS
    }

    /// iCloud → UserDefaults, then re-apply anything with a live side effect (appearance).
    @objc private func cloudChanged(_ note: Notification) {
        let changed = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? syncedPrefKeys
        adoptFromCloud(changed.filter(syncedPrefKeys.contains))
        applyPersistedAppearance()
    }

    /// UserDefaults → iCloud for the synced keys (no-op when values already match, so this
    /// never echoes an inbound change back out — no update loop).
    @objc private func defaultsChanged() {
        let ud = UserDefaults.standard
        for key in syncedPrefKeys {
            guard let local = ud.string(forKey: key) else { continue }
            if local != store.string(forKey: key) {
                store.set(local, forKey: key)
            }
        }
    }

    private func adoptFromCloud(_ keys: [String]) {
        let ud = UserDefaults.standard
        for key in keys {
            if let cloud = store.string(forKey: key), cloud != ud.string(forKey: key) {
                ud.set(cloud, forKey: key)
            }
        }
    }
}
