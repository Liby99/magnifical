// The subscribed ICS feed URLs (Google Calendar "secret addresses" etc.), stored as a JSON
// array in ONE Keychain item PER MagnifiCal calendar — imports are calendar-scoped: a feed
// subscribed while "Demo" is open belongs to Demo and never bleeds into Main. The secret URL
// *is* the credential (anyone holding it can read that calendar), so it never touches
// UserDefaults. The engine gets the active calendar's list via a closure
// (CalendarEngine.icsFeedURLs) and never reads the Keychain itself.

import CalendarEngine
import Foundation

enum ICSFeeds {
    /// The pre-per-calendar item (one global list). Migrated into Main's item on first read:
    /// those feeds were subscribed when Main was the only calendar.
    static let legacyAccount = "ics-feed-urls"

    static func account(_ calendarId: String) -> String {
        "ics-feed-urls-\(calendarId)"
    }

    static func list(calendarId: String) -> [String] {
        if let urls = read(account: account(calendarId)) {
            return urls
        }
        // Legacy migration (Main only): move the old global list under Main's account.
        if calendarId == PrefKeys.mainCalendarId, let legacy = read(account: legacyAccount) {
            store(legacy, account: account(calendarId))
            _ = Keychain.set(nil, account: legacyAccount)
            return legacy
        }
        return []
    }

    static func save(_ urls: [String], calendarId: String) {
        let cleaned = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        store(cleaned, account: account(calendarId))
        NotificationCenter.default.post(name: .icsFeedsChanged, object: nil)
    }

    static func add(_ url: String, calendarId: String) {
        var urls = list(calendarId: calendarId)
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !urls.contains(clean) else { return }
        urls.append(clean)
        save(urls, calendarId: calendarId)
    }

    static func remove(_ url: String, calendarId: String) {
        save(list(calendarId: calendarId).filter { $0 != url }, calendarId: calendarId)
    }

    /// A privacy-friendly display form of a secret URL: host + a stable short key.
    static func displayName(_ url: String) -> String {
        let host = URL(string: url)?.host ?? "feed"
        return "\(host) · \(ICSFeedKey.feedKey(url))"
    }

    private static func read(account: String) -> [String]? {
        guard let raw = Keychain.get(account: account),
              let urls = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return nil }
        return urls
    }

    private static func store(_ urls: [String], account: String) {
        if let data = try? JSONEncoder().encode(urls) {
            _ = Keychain.set(String(decoding: data, as: UTF8.self), account: account)
        }
    }
}
