// The 2026-08 bundle-id rename (dev.libirabu.calendar → dev.magnifical.calendar) and what
// carries across it. Most identity deliberately did NOT move: the CloudKit container
// (CloudSync.containerID), the KVS store id, and the Keychain service/access group are all
// pinned to the legacy id — invisible to users, and moving them would orphan or force a
// re-upload of real data. The local store is bundle-id independent (Application
// Support/CalendarKit). The ONE thing macOS keys by bundle id is UserDefaults: the old
// app's preferences live in the dev.libirabu.calendar domain, which the renamed app would
// otherwise start without (losing view prefs, per-calendar Apple import selections, the
// active-calendar id, notification prefs, …).

import Foundation

public enum LegacyIdentity {
    static let legacyDomain = "dev.libirabu.calendar"
    private static let marker = "cc.migratedDefaultsFromLibirabu"

    /// One-time copy of the legacy bundle id's UserDefaults into the current (standard) domain.
    /// Call from the .app BEFORE anything reads preferences (PrefsSync, the engine's registry).
    ///
    /// Semantics: runs once (marker key), copies only keys the new domain doesn't already have
    /// (never clobbers anything written since), and is a silent no-op when there's nothing to
    /// migrate — a fresh install, the dev shell (its own domain never held app data), iOS, or a
    /// future sandboxed build where cross-domain reads are denied and CFPreferences returns nil.
    public static func migrateDefaultsIfNeeded() {
        let std = UserDefaults.standard
        guard !std.bool(forKey: marker) else { return }
        // The marker is set FIRST: if the copy below half-fails we'd rather skip retrying than
        // re-clobber... nothing — copies are non-destructive — but a retry loop on every launch
        // against a denied domain (sandbox) would be wasted work forever.
        std.set(true, forKey: marker)
        guard Bundle.main.bundleIdentifier != legacyDomain else { return } // old build: nothing to do
        let domain = legacyDomain as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String], !keys.isEmpty else { return }
        guard let values = CFPreferencesCopyMultiple(keys as CFArray, domain,
                                                     kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any] else { return }
        var copied = 0
        for (key, value) in values where std.object(forKey: key) == nil {
            std.set(value, forKey: key)
            copied += 1
        }
        storeLog.info("migrated \(copied) preference keys from \(legacyDomain, privacy: .public)")
    }
}
