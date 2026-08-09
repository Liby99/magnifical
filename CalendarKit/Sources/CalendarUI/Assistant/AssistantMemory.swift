// The assistant's long-term memory — the native counterpart of src/lib/assistant/memory.ts
// (the web's per-user Postgres table). Recalled facts are injected into the system prompt each turn
// so the assistant remembers across conversations.
//
// Backend: iCloud key-value store (NSUbiquitousKeyValueStore) — the same iCloud mechanism the
// preference sync uses (ubiquity-kvstore entitlement), so memory follows the user across devices.
// Each fact is its OWN KVS key ("cc.mem.<key>") rather than one blob, so two devices editing
// different facts merge instead of clobbering. Keys beginning "assistant." are reserved for internal
// settings and hidden from recall, matching the web's convention.

import Foundation

@MainActor
enum AssistantMemory {
    private static let prefix = "cc.mem."
    private static var kv: NSUbiquitousKeyValueStore {
        .default
    }

    /// All remembered facts (excluding reserved `assistant.*` keys) — injected into the prompt.
    static func recallAll() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (rawKey, rawVal) in kv.dictionaryRepresentation where rawKey.hasPrefix(prefix) {
            let key = String(rawKey.dropFirst(prefix.count))
            guard !key.hasPrefix("assistant.") else { continue }
            if let data = rawVal as? Data, let val = try? JSONDecoder().decode(JSONValue.self, from: data) {
                out[key] = val
            }
        }
        return out
    }

    static func remember(_ key: String, _ value: JSONValue) {
        do {
            let data = try JSONEncoder().encode(value)
            kv.set(data, forKey: prefix + key)
            kv.synchronize() // flush now so it starts syncing out promptly
        } catch {
            assertionFailure("unencodable memory value for '\(key)': \(error)") // JSONValue should always encode
        }
    }

    static func forget(_ key: String) {
        kv.removeObject(forKey: prefix + key)
        kv.synchronize()
    }
}
