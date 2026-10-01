// The attachment REVERSE INDEX, computed on demand — deliberately not a stored table: stored
// link tables drift under undo/redo, sync merges, and crash-mid-edit (the same reasoning that
// rejected stored refcounts, design §7). The notes ARE the reference database; this scans
// every calendar's notes (active in memory, others from their on-disk stores — the census
// pattern) and joins the result against the blob index, so the Settings ▸ Developer browser
// shows every imported file with everything that references it, and every orphan.

import CalendarGeometry
import Foundation

/// Where a reference can be navigated to — the browser's "show in calendar" jump target.
public enum AttachmentRefTarget: Sendable, Hashable {
    case item(id: String, occurrence: String?) // an event/band/deadline note (+ occKey if any)
    case note(key: String) // daily "YYYY-MM-DD" / "week:<sunday>" / "month:<YYYY-MM>"
}

/// One place a blob is referenced from, as a human-readable label
/// ("Event “Standup”", "Daily note 2026-09-21 · ‹Work›", …).
public struct AttachmentRef: Sendable, Hashable, Identifiable {
    public var id: String { label + "|" + noteKey }
    public let label: String
    public let noteKey: String // diagnostic: the raw storage key / item id
    public let target: AttachmentRefTarget
    public let inActiveCalendar: Bool // navigation only works within the open calendar
}

/// One row of the browser: a blob (or a still-waiting token) + everything referencing it.
public struct AttachmentInventoryRow: Sendable, Identifiable {
    public let id: String // full sha256, or the token prefix for a not-yet-synced blob
    public let name: String // meta name, or the referencing token's display name
    public let meta: AttachmentMeta? // nil = blob not in the local store (waiting/orphan token)
    public let refs: [AttachmentRef]
}

public extension CalendarEngine {
    /// Every known attachment + every reference to it, across ALL calendars. Orphans (blob
    /// present, zero references) and ghosts (token present, blob still syncing) both appear.
    func attachmentInventory() -> [AttachmentInventoryRow] {
        // prefix id → (token display name, refs)
        var refsByPrefix: [String: (name: String, refs: [AttachmentRef])] = [:]
        func note(_ text: String?, label: String, key: String, target: AttachmentRefTarget,
                  calendar: String?) {
            guard let text, !text.isEmpty else { return }
            for m in AttachmentTokens.matches(in: text) {
                let full = calendar.map { "\(label) · ‹\($0)›" } ?? label
                var slot = refsByPrefix[m.token.id] ?? (m.token.name, [])
                slot.name = m.token.name
                slot.refs.append(AttachmentRef(label: full, noteKey: key, target: target,
                                               inActiveCalendar: calendar == nil))
                refsByPrefix[m.token.id] = slot
            }
        }
        func scanState(events: [TimedEvent], bands: [BandEvent], deadlines: [Deadline],
                       rich: [String: RichFields], dailyNotes: [String: String],
                       calendar: String?) {
            func title(_ id: String) -> String {
                events.first { $0.id == id }.map { "Event “\($0.title)”" }
                    ?? bands.first { $0.id == id }.map { "Event “\($0.title)”" }
                    ?? deadlines.first { $0.id == id }.map { "Deadline “\($0.title)”" }
                    ?? "Imported event \(String(id.prefix(18)))…"
            }
            for (id, rf) in rich {
                note(rf.notes, label: title(id), key: id,
                     target: .item(id: id, occurrence: nil), calendar: calendar)
                for (occ, text) in rf.occurrenceNotes ?? [:] {
                    note(text, label: "\(title(id)) · \(occ)", key: "\(id)|\(occ)",
                         target: .item(id: id, occurrence: occ), calendar: calendar)
                }
            }
            for (key, text) in dailyNotes {
                let label = key.hasPrefix("week:") ? "Weekly note \(key.dropFirst(5))"
                    : key.hasPrefix("month:") ? "Monthly note \(key.dropFirst(6))"
                    : "Daily note \(key)"
                note(text, label: label, key: key, target: .note(key: key), calendar: calendar)
            }
        }

        for metaCal in registry.all {
            if metaCal.id == registry.activeId {
                scanState(events: items.events, bands: items.bands, deadlines: items.deadlines,
                          rich: items.richById, dailyNotes: items.dailyNotes, calendar: nil)
            } else if let data = try? Data(
                contentsOf: calendarDir(metaCal.id).appendingPathComponent("data.json")
            ), let st = try? JSONDecoder().decode(PersistedState.self, from: data) {
                scanState(events: st.events, bands: st.bands, deadlines: st.deadlines,
                          rich: st.rich ?? [:], dailyNotes: st.dailyNotes ?? [:],
                          calendar: metaCal.name)
            }
        }

        // Join against the blob index: referenced blobs, then orphans (indexed, unreferenced).
        var rows: [AttachmentInventoryRow] = []
        var coveredHashes = Set<String>()
        for (prefix, slot) in refsByPrefix {
            if let hash = attachments.resolveHash(forId: prefix) {
                coveredHashes.insert(hash)
                let meta = attachments.meta(forId: hash)
                rows.append(AttachmentInventoryRow(id: hash, name: meta?.name ?? slot.name,
                                                   meta: meta,
                                                   refs: slot.refs.sorted { $0.label < $1.label }))
            } else {
                rows.append(AttachmentInventoryRow(id: prefix, name: slot.name, meta: nil,
                                                   refs: slot.refs.sorted { $0.label < $1.label }))
            }
        }
        for (hash, meta) in attachments.allEntries() where !coveredHashes.contains(hash) {
            rows.append(AttachmentInventoryRow(id: hash, name: meta.name, meta: meta, refs: []))
        }
        // Most-referenced first, then by name — orphans naturally sink to the bottom.
        return rows.sorted {
            $0.refs.count != $1.refs.count ? $0.refs.count > $1.refs.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}