// Local, secure storage for API keys. Secrets don't belong in UserDefaults/JSON, so they go
// into the macOS Keychain as generic-password items.
//
// We use the DATA-PROTECTION keychain (kSecUseDataProtectionKeychain), not the legacy login
// keychain. Legacy items are protected by an ACL bound to the creating binary's code signature —
// so every clean rebuild / re-sign produced a binary the ACL no longer trusted, and the keys
// "disappeared" (get returned nil even though the item still existed). The data-protection
// keychain scopes access by the app's keychain access group (team + bundle id from the signing
// entitlements) instead, which is stable across rebuilds. Requires a signed app; the unsigned
// CalendarMac dev shell gets errSecMissingEntitlement there, so it falls back to the legacy path
// (with the old rebuild caveat — dev-shell only).
//
// `kSecAttrAccessibleWhenUnlocked` + no kSecAttrSynchronizable keeps keys on THIS device only —
// matching the intent that API keys stay local and unsynced, unlike the appearance preference.

import Foundation
import Security

enum Keychain {
    /// Namespaces our items so they don't collide with anything else in the keychain.
    /// DELIBERATELY the legacy id (pre-2026-08 bundle-id rename): the service string is how
    /// existing items are FOUND — renaming it would orphan every stored API key and feed URL.
    /// The entitlements list the legacy keychain access group so those items stay readable.
    private static let service = "dev.libirabu.calendar.apikeys"

    /// Store (or, for a nil/empty value, remove) the secret for `account`. Returns success.
    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        guard let value, !value.isEmpty else { return delete(account: account) }
        // Data-protection keychain first (entitlement-scoped → survives rebuilds/cleans);
        // unsigned dev builds lack an access group → fall back to the legacy login keychain.
        if store(value, account: account, dataProtection: true) {
            return true
        }
        return store(value, account: account, dataProtection: false)
    }

    /// The stored secret for `account`, or nil if none.
    static func get(account: String) -> String? {
        // Env override (CC_KEY_<ACCOUNT>, non-alphanumerics → "_"): headless processes — the
        // assistant-eval trajectory runner — can't read the app's data-protection keychain items
        // (they're scoped to the signed app's access group), so keys are passed via environment.
        let envName = "CC_KEY_" + String(account.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        if let v = ProcessInfo.processInfo.environment[envName], !v.isEmpty {
            return v
        }
        if let v = read(account: account, dataProtection: true) {
            return v
        }
        // Migration + dev fallback: if a legacy login-keychain item exists (e.g. saved by a build
        // before this change), promote it into the data-protection keychain so future rebuilds
        // keep access without re-entering the key.
        if let v = read(account: account, dataProtection: false) {
            _ = store(v, account: account, dataProtection: true)
            return v
        }
        return nil
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        /// Remove from BOTH keychains, so a stale legacy copy can't resurface via migration.
        func ok(_ s: OSStatus) -> Bool {
            s == errSecSuccess || s == errSecItemNotFound
        }
        let dp = SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        let legacy = SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
        return ok(dp) && ok(legacy)
    }

    // ── Internals ─────────────────────────────────────────────────────────────────────

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }

    private static func store(_ value: String, account: String, dataProtection: Bool) -> Bool {
        let match = baseQuery(account: account, dataProtection: dataProtection)
        let update: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(match.merging(update) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func read(account: String, dataProtection: Bool) -> String? {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
