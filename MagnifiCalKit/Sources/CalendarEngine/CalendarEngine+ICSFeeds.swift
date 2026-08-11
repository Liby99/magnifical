// ICS feed subscriptions — "Connect Google Calendar" path 2: the user pastes a calendar's
// SECRET iCal address (Google: Settings ▸ [calendar] ▸ Integrate calendar ▸ "Secret address in
// iCal format") and we periodically fetch + merge it as READ-ONLY imported items, exactly like
// the Apple Calendar import (same imported bucket, provenance badges, hide/color overlays).
// No OAuth: the secret URL itself is the credential, so it lives in the KEYCHAIN.

import CalendarGeometry
import CryptoKit
import Foundation

public extension Notification.Name {
    /// Posted by Settings when the feed list changes → re-import.
    static let icsFeedsChanged = Notification.Name("cc.icsFeeds.changed")
    /// Posted after a fetch stores a feed's display name (X-WR-CALNAME) → Settings re-renders its
    /// feed rows. Deliberately distinct from icsFeedsChanged, which would re-trigger the import.
    static let icsFeedNamesChanged = Notification.Name("cc.icsFeeds.namesChanged")
    /// Posted by Settings when a feed's DEFAULT color changes → the calendar re-colors the feed's
    /// items that carry no per-item override (CalendarView bumps the display caches).
    static let icsFeedColorsChanged = Notification.Name("cc.icsFeeds.colorsChanged")
}

/// Per-feed DEFAULT event colors. Every imported item from a feed shows the feed's color unless
/// the user picked one for that item (the rich colorOverride — that override is the "changed"
/// bit, so default-color changes propagate exactly to the untouched items). Stored in
/// UserDefaults by feed key; new subscriptions cycle through the palette.
public enum ICSFeedColors {
    /// The stored default for a feed key, if one has been assigned.
    public static func color(forKey feedKey: String) -> String? {
        UserDefaults.standard.string(forKey: PrefKeys.icsFeedColor(feedKey))
    }

    public static func set(_ color: String, forKey feedKey: String) {
        UserDefaults.standard.set(color, forKey: PrefKeys.icsFeedColor(feedKey))
    }

    /// First-time assignment: cycle the real palette ("default" excluded) so each new
    /// subscription lands on a fresh color. Idempotent for feeds that already have one.
    public static func assignIfNeeded(url: String) {
        let key = ICSFeedKey.feedKey(url)
        guard color(forKey: key) == nil else { return }
        let palette = EVENT_COLORS.filter { $0 != "default" }
        let d = UserDefaults.standard
        let cursor = d.integer(forKey: PrefKeys.icsFeedColorCursor)
        d.set(palette[cursor % palette.count], forKey: PrefKeys.icsFeedColor(key))
        d.set(cursor + 1, forKey: PrefKeys.icsFeedColorCursor)
    }
}

/// Stable 10-hex key for a feed URL — the id-prefix its items live under. (The URL list itself
/// is stored UI-side in the Keychain — see ICSFeeds in CalendarUI — and passed in.)
public enum ICSFeedKey {
    public static func feedKey(_ url: String) -> String {
        let digest = SHA256.hash(data: Data(url.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    }
}

/// Which provider a subscribed ICS feed belongs to, from its URL host — drives the drawer's
/// provenance label, the managed-note "imported from:" line, and the Settings feed rows.
public enum ICSFeedProvider {
    public static func label(forURL url: String?) -> String {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return "Calendar Feed" }
        if host.hasSuffix("google.com") {
            return "Google Calendar"
        }
        if host.hasSuffix("outlook.live.com") || host.hasSuffix("outlook.office.com")
            || host.hasSuffix("office365.com") { // covers outlook.office365.com
            return "Outlook Calendar"
        }
        return "Calendar Feed"
    }
}

extension CalendarEngine {
    /// Fetch every subscribed feed and merge it into the read-only imported bucket. Each feed
    /// replaces ONLY its own contribution (id prefix "gcal-<feedKey>-"); Apple-imported items and
    /// other feeds are untouched. Failures leave the previous contribution in place.
    public func importICSFeeds(urls: [String]) {
        guard !Self.isDemoMode else { return } // recording sessions never touch personal data
        // Prune contributions of feeds that were removed.
        let liveKeys = Set(urls.map { "gcal-\(ICSFeedKey.feedKey($0))-" })
        let stale = imported.events.contains { id in
            id.id.hasPrefix("gcal-") && !liveKeys.contains(where: { id.id.hasPrefix($0) })
        } || imported.bands.contains { b in
            b.id.hasPrefix("gcal-") && !liveKeys.contains(where: { b.id.hasPrefix($0) })
        }
        if stale {
            imported.events
                .removeAll { e in e.id.hasPrefix("gcal-") && !liveKeys.contains(where: { e.id.hasPrefix($0) }) }
            imported.bands
                .removeAll { b in b.id.hasPrefix("gcal-") && !liveKeys.contains(where: { b.id.hasPrefix($0) }) }
            caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
        }
        guard !urls.isEmpty else { return }
        for url in urls { // Edit-original links + provenance labels resolve the feed by its key
            icsFeedByKey[ICSFeedKey.feedKey(url)] = url.trimmingCharacters(in: .whitespacesAndNewlines)
            ICSFeedColors.assignIfNeeded(url: url) // pre-existing subscriptions get a color too
        }
        // Feeds are PER MagnifiCal calendar: a fetch started on one calendar must never merge into
        // another (the user can switch while a slow fetch is in flight).
        let calendar = registry.activeId
        let window = (year - 1) ... (year + 2)
        Task { [weak self] in
            for url in urls {
                guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
                      u.scheme?.hasPrefix("http") == true else { continue }
                guard let (data, resp) = try? await URLSession.shared.data(from: u),
                      (200 ... 299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let key = ICSFeedKey.feedKey(url)
                // Remember the feed's own display name (X-WR-CALNAME) — Settings shows it in
                // place of the anonymous host·key row. Not calendar-gated: the name belongs to
                // the FEED, whichever MagnifiCal calendar subscribed it.
                if let name = ICSImport.feedCalendarName(from: text) {
                    await MainActor.run {
                        let nameKey = PrefKeys.icsFeedName(key)
                        if UserDefaults.standard.string(forKey: nameKey) != name {
                            UserDefaults.standard.set(name, forKey: nameKey)
                            NotificationCenter.default.post(name: .icsFeedNamesChanged, object: nil)
                        }
                    }
                }
                let parsed = ICSImport.feedItems(from: text, feedKey: key, years: window,
                                                 provenance: "\(ICSFeedProvider.label(forURL: url)) feed")
                await MainActor.run { [weak self] in
                    guard let self, self.registry.activeId == calendar else { return }
                    self.mergeFeed(key: key, events: parsed.events, bands: parsed.bands,
                                   rich: parsed.rich, uids: parsed.uids)
                }
            }
        }
    }

    func mergeFeed(key: String, events: [TimedEvent], bands: [BandEvent], // internal: tested directly
                   rich: [String: RichFields], uids: [String: String]) {
        let prefix = "gcal-\(key)-"
        imported.events.removeAll { $0.id.hasPrefix(prefix) }
        imported.bands.removeAll { $0.id.hasPrefix(prefix) }
        imported.gcalUids = imported.gcalUids.filter { !$0.key.hasPrefix(prefix) }.merging(uids) { _, new in new }
        imported.events += events
        imported.bands += bands
        // Series rich: the MANAGED note block (provenance / location / organizer / attendees /
        // description) REFRESHES on every fetch, composed with any user-typed postfix — exactly
        // like the Apple import's setImportedNote. (It used to attach only when no overlay existed
        // yet: any series that first appeared via a color/promote overlay — or an older build's
        // fetch — never showed its vendor sections at all.) User overlays (color, tags, promote,
        // hide, their own note text) always survive the refetch.
        var richChanged = false
        for (k, v) in rich {
            if var rf = items.richById[k] {
                let composed = ManagedNote.replaceManaged(rf.notes, v.notes ?? "")
                let newNotes: String? = composed.isEmpty ? nil : composed
                if rf.notes != newNotes {
                    rf.notes = newNotes
                    items.richById[k] = rf
                    richChanged = true
                }
            } else {
                items.richById[k] = v
                richChanged = true
            }
        }
        if richChanged {
            schedulePersist() // the managed blocks are stored state (like the Apple import's)
        }
        caches.editGen &+= 1; caches.deadlineGen &+= 1
        wake()
        onExternalDataChange?() // a refresh may have removed an open item
    }
}

/// ── Imported-event provenance (the drawer's top banner) ───────────────────────────────────────
public struct ImportedProvenance: Sendable {
    public let label: String // "Apple Calendar" / "Google Calendar" / "Calendar Feed"
    public let editURL: URL? // deep link to the original event, when derivable
    public let editHelp: String // the Edit-original button's tooltip
}

extension CalendarEngine {
    /// The feed's default color for a gcal box id — nil for Apple/local ids or unassigned feeds.
    static func feedDefaultColor(_ id: String) -> String? {
        guard id.hasPrefix("gcal-") else { return nil }
        let key = String(id.dropFirst("gcal-".count).prefix(while: { $0 != "-" }))
        return ICSFeedColors.color(forKey: key)
    }

    /// Settings changed a feed's default color → re-derive the display caches so the feed's
    /// non-overridden items pick the new color up.
    public func feedColorsChanged() {
        caches.editGen &+= 1
        caches.deadlineGen &+= 1
        wake()
    }
}

public extension CalendarEngine {
    /// Where a read-only imported box came from, for the drawer's banner: label + (when we can
    /// build one) a deep link to edit the original. nil for editable (non-imported-bucket) items.
    func importedProvenance(_ id: String) -> ImportedProvenance? {
        let sid = sourceId(of: id)
        if sid.hasPrefix("apple-") {
            return ImportedProvenance(label: "Apple Calendar", editURL: appleOriginalURL(id),
                                      editHelp: "Open this event in Calendar.app")
        }
        if sid.hasPrefix("gcal-") {
            // "gcal-<feedKey>-…" → the subscribed feed it came from. Only Google gets an
            // Edit-original deep link (Outlook's published-ICS UIDs aren't derivable into
            // web-app event URLs) — googleEventURL returns nil for other hosts.
            let key = String(sid.dropFirst("gcal-".count).prefix(while: { $0 != "-" }))
            let feedURL = icsFeedByKey[key]
            return ImportedProvenance(label: ICSFeedProvider.label(forURL: feedURL),
                                      editURL: googleEventURL(sid: sid, feedURL: feedURL.flatMap { URL(string: $0) }),
                                      editHelp: "Open this event in Google Calendar")
        }
        return nil
    }

    /// The Google Calendar web deep link for a feed event: Google's event URLs are
    /// `…/calendar/event?eid=base64url("<uid-local> <calendarId>")`, and the secret feed URL
    /// carries the calendar id in its path (`…/calendar/ical/<calendarId>/private-…/basic.ics`).
    /// nil for non-Google feeds or when the raw UID wasn't captured.
    private func googleEventURL(sid: String, feedURL: URL?) -> URL? {
        guard let feedURL, feedURL.host?.hasSuffix("google.com") == true else { return nil }
        let comps = feedURL.pathComponents
        guard let i = comps.firstIndex(of: "ical"), comps.count > i + 1 else { return nil }
        let calId = comps[i + 1].removingPercentEncoding ?? comps[i + 1]
        guard let uid = imported.gcalUids[overlayKey(sid)] else { return nil }
        let local = uid.hasSuffix("@google.com") ? String(uid.dropLast("@google.com".count)) : uid
        let eid = Data("\(local) \(calId)".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return URL(string: "https://calendar.google.com/calendar/event?eid=\(eid)")
    }
}
