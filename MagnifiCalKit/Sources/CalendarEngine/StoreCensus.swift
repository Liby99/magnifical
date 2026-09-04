// Store census: a category-by-category count of everything this device holds, designed to be
// diffed VERBATIM against the other device's census. The systematic tool for "the phone shows
// fewer events than the Mac" (2026-09-04): stop reasoning by anecdote — count every category
// (per calendar, per id class, per year, store vs import layer vs sync caches), compare, and
// fix the categories that differ, one by one.
//
// Output: one stable-key-ordered JSON document, logged under subsystem dev.magnifical.calendar
// category "census" (filter the Xcode console / `log stream` on "census"), and on iOS also
// written to Documents/census.json (visible in the Files app).

import CalendarGeometry
import Foundation
import os

let censusLog = Logger(subsystem: "dev.magnifical.calendar", category: "census")

public extension CalendarEngine {
    /// The census document. The ACTIVE calendar is counted from memory (includes unsaved
    /// edits); the other calendars are decoded from their on-disk stores.
    func storeCensus() -> [String: Any] {
        var calendars: [[String: Any]] = []
        for meta in registry.all {
            let active = meta.id == registry.activeId
            var entry: [String: Any] = if active {
                Self.censusOf(events: items.events, bands: items.bands,
                              deadlines: items.deadlines, rich: items.richById,
                              dailyNotes: items.dailyNotes,
                              trackNames: items.trackNames)
            } else if let data = try? Data(contentsOf: calendarDir(meta.id).appendingPathComponent("data.json")),
                      let st = try? JSONDecoder().decode(PersistedState.self, from: data) {
                Self.censusOf(events: st.events, bands: st.bands,
                              deadlines: st.deadlines, rich: st.rich ?? [:],
                              dailyNotes: st.dailyNotes ?? [:],
                              trackNames: st.monthTrackNames ?? [])
            } else {
                ["unreadable": true]
            }
            entry["id"] = meta.id
            entry["name"] = meta.name
            entry["active"] = active
            if active {
                // Sync-layer state (active calendar only — that's whose CloudSync is running).
                entry["recordCache"] = cloud?.recordCacheCount ?? -1
                entry["pendingSends"] = cloud?.pendingSendCount ?? -1
                // The import display layer (EventKit/feeds) — per-device by design; the phone
                // reads 0 here until it grows its own importer. Split so store-vs-import
                // discrepancies can't be conflated.
                entry["importedLayer"] = ["events": imported.events.count,
                                          "bands": imported.bands.count]
            }
            calendars.append(entry)
        }
        return [
            "device": Self.censusDeviceLabel,
            "activeCalendar": registry.activeId,
            "cloudReadOnly": cloudReadOnly,
            "calendars": calendars,
        ]
    }

    /// Log the census (category "census"); on iOS also write Documents/census.json for the
    /// Files app. Called at phone launch + after foreground sync, and from the Mac's
    /// Settings ▸ Developer ▸ "Log Store Census".
    func logStoreCensus(reason: String) {
        let doc = storeCensus()
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        // One log line per calendar keeps every entry under os_log's message-size cap
        // (a whole-document line was exactly the truncation trap the sync logs hit).
        censusLog
            .notice(
                "census (\(reason, privacy: .public)) device=\(Self.censusDeviceLabel, privacy: .public) active=\(self.registry.activeId, privacy: .public)"
            )
        for cal in (doc["calendars"] as? [[String: Any]]) ?? [] {
            if let cdata = try? JSONSerialization.data(withJSONObject: cal, options: [.sortedKeys]),
               let cjson = String(data: cdata, encoding: .utf8) {
                censusLog.notice("census \(cjson, privacy: .public)")
            }
        }
        #if os(iOS)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("census.json")
            if let pretty = try? JSONSerialization.data(withJSONObject: doc,
                                                        options: [.prettyPrinted, .sortedKeys]) {
                try? pretty.write(to: url)
            }
        #endif
        _ = json // assembled above to validate the document serializes as one piece
    }

    private static var censusDeviceLabel: String {
        #if os(iOS)
            "iphone"
        #else
            "mac"
        #endif
    }

    /// Counts for one calendar's store. Static + pure so the disk-decoded calendars share the
    /// exact same math as the in-memory active one.
    private static func censusOf(events: [TimedEvent], bands: [BandEvent], deadlines: [Deadline],
                                 rich: [String: RichFields], dailyNotes: [String: String],
                                 trackNames: [[String]]) -> [String: Any] {
        func byClass(_ ids: [String]) -> [String: Int] {
            var out: [String: Int] = [:]
            for id in ids {
                out[idClass(id), default: 0] += 1
            }
            return out
        }
        func byYear(_ ys: [Int]) -> [String: Int] {
            var out: [String: Int] = [:]
            for y in ys {
                out[String(y), default: 0] += 1
            }
            return out
        }
        let importedSeries = rich.filter { hasImportedPrefix($0.key) && applePerOccurrenceSuffix($0.key) == nil }
        let importedOcc = rich.filter { hasImportedPrefix($0.key) && applePerOccurrenceSuffix($0.key) != nil }
        return [
            "events": ["total": events.count,
                       "byClass": byClass(events.map(\.id)),
                       "byYear": byYear(events.map(\.year))],
            "bands": ["total": bands.count,
                      "byClass": byClass(bands.map(\.id)),
                      "byYear": byYear(bands.map(\.year))],
            "deadlines": ["total": deadlines.count,
                          "byYear": byYear(deadlines.map(\.year))],
            "rich": ["total": rich.count,
                     "importedSeriesOverlays": importedSeries.count,
                     "importedOccurrenceOverlays": importedOcc.count,
                     "withNotes": rich.filter { !($0.value.notes ?? "").isEmpty }.count,
                     "userHidden": rich.filter(\.value.userHidden).count],
            "dailyNotes": dailyNotes.count,
            "trackNameRows": trackNames.count,
        ]
    }

    /// Coarse id classes: import sources keep their own buckets; native ids bucket by their
    /// prefix (tev/bev/ddl/new/newb/seg/one…); the web era's dash-less cuids get "cuid".
    private static func idClass(_ id: String) -> String {
        for p in ["apple", "gcal", "ics"] where id.hasPrefix("\(p)-") {
            return p
        }
        if let dash = id.firstIndex(of: "-") {
            return String(id[..<dash])
        }
        return id.count >= 20 ? "cuid" : "other"
    }
}
