// Local JSON persistence for the calendar items, so edits survive a restart without
// a backend. This is an interim store; the sync engine will later reconcile the same
// PersistedState shape with the server.

import CalendarGeometry
import Foundation
import os

public struct PersistedState: Codable, Sendable {
    public var events: [TimedEvent]
    public var bands: [BandEvent]
    public var deadlines: [Deadline]
    public var monthTrackNames: [[String]]? // per-month lane names; nil on older saves
    /// Full-fidelity fields the lean geometry types (TimedEvent/BandEvent/Deadline) don't carry,
    /// keyed by item id. Kept alongside so notes/tags/recurrence survive a round-trip through the
    /// store and CloudKit even though the renderer doesn't surface them yet. nil on older saves.
    public var rich: [String: RichFields]?
    /// The daily-dashboard NOTE tab: one free-form markdown note per day, keyed by ISO date
    /// "YYYY-MM-DD". nil on older saves. (Mirrors the web's `dailyNote` table.)
    public var dailyNotes: [String: String]?

    public init(events: [TimedEvent], bands: [BandEvent], deadlines: [Deadline],
                monthTrackNames: [[String]]? = nil, rich: [String: RichFields]? = nil,
                dailyNotes: [String: String]? = nil) {
        self.events = events; self.bands = bands; self.deadlines = deadlines
        self.monthTrackNames = monthTrackNames; self.rich = rich; self.dailyNotes = dailyNotes
    }
}

/// The item content that the lean render types omit. Carried by the sync layer (persisted +
/// mapped onto the CKRecord) so it isn't lost; opaque to the geometry/renderer for now.
/// `repeatJSON` is the recurrence config serialized (the renderer doesn't expand it yet).
public struct RichFields: Codable, Sendable, Equatable {
    public var notes: String?
    public var tags: [String]
    public var repeatJSON: String?
    public var promoteTrack: Int? // timed/deadline ghost-band lane; nil = not promoted
    public var originTz: String? // deadline origin tz ("AOE"/IANA); nil = main tz canonical
    public var source: String // "manual" | "apple" | "ical"
    public var hidden: Bool // soft-deleted (imported items)
    public var createdByAI: Bool // provenance: created/edited by the AI assistant
    public var occurrenceNotes: [String: String]? // per-occurrence notes (recurring), keyed by box id
    public var colorOverride: String? // user-chosen color for an imported (vendor-colored) event; nil = vendor color
    public var userHidden: Bool // user chose to HIDE this imported series (persists across re-imports,
    // unlike the dedup `hidden`); keyed by the imported series key

    public init(notes: String? = nil, tags: [String] = [], repeatJSON: String? = nil,
                promoteTrack: Int? = nil, originTz: String? = nil,
                source: String = "manual", hidden: Bool = false, createdByAI: Bool = false,
                occurrenceNotes: [String: String]? = nil, colorOverride: String? = nil,
                userHidden: Bool = false) {
        self.notes = notes; self.tags = tags; self.repeatJSON = repeatJSON
        self.promoteTrack = promoteTrack; self.originTz = originTz
        self.source = source; self.hidden = hidden; self.createdByAI = createdByAI
        self.occurrenceNotes = occurrenceNotes; self.colorOverride = colorOverride
        self.userHidden = userHidden
    }

    /// Tolerant decode: a field absent in an OLDER store just takes its default, so adding a field
    /// (like createdByAI) never fails the whole rich-map decode and drops notes/recurrence/etc.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        repeatJSON = try c.decodeIfPresent(String.self, forKey: .repeatJSON)
        promoteTrack = try c.decodeIfPresent(Int.self, forKey: .promoteTrack)
        originTz = try c.decodeIfPresent(String.self, forKey: .originTz)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        createdByAI = try c.decodeIfPresent(Bool.self, forKey: .createdByAI) ?? false
        occurrenceNotes = try c.decodeIfPresent([String: String].self, forKey: .occurrenceNotes)
        colorOverride = try c.decodeIfPresent(String.self, forKey: .colorOverride)
        userHidden = try c.decodeIfPresent(Bool.self, forKey: .userHidden) ?? false
    }
}

/// The CalendarKit data root: a throwaway dir in demo/recording mode (so a recording NEVER touches the
/// user's real calendar), else Application Support/CalendarKit. Shared by the store, the registry, and
/// the cloud record cache so they all agree on where data lives.
func calendarKitBaseDir() -> URL {
    #if os(iOS)
        // On device CC_DEMO_DATADIR can't point at a mac path; without this redirect a CC_DEMO
        // run would fall through to the app's REAL store. BenchStaging fills this dir at launch.
        // (Inlined CC_DEMO check — CalendarEngine.isDemoMode is MainActor-isolated and this
        // function is not.)
        if !(ProcessInfo.processInfo.environment["CC_DEMO"] ?? "").isEmpty {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("bench-store", isDirectory: true)
        }
    #endif
    if let demo = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !demo.isEmpty {
        return URL(fileURLWithPath: demo, isDirectory: true)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    // "CalendarKit" is the ON-DISK data folder every existing install already has. The package
    // directory was renamed MagnifiCalKit (2026-08) but this string must NEVER follow suit —
    // renaming it would orphan every user's local calendars.
    return base.appendingPathComponent("CalendarKit", isDirectory: true)
}

/// The directory holding one calendar's files (data.json / syncState.bin / records.plist).
func calendarDir(_ calendarId: String) -> URL {
    calendarKitBaseDir().appendingPathComponent("calendars/\(calendarId)", isDirectory: true)
}

struct ItemStore {
    private let url: URL
    private let syncStateURL: URL

    /// One calendar's on-disk store, under `calendars/<calendarId>/`. Each calendar is a separate document
    /// (disjoint data + its own iCloud sync state); the engine repoints here when switching calendars.
    init(calendarId: String) {
        let dir = calendarDir(calendarId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("data.json")
        syncStateURL = dir.appendingPathComponent("syncState.bin")
    }

    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) {
        // This is the user's PRIMARY calendar data — a failed write (disk full, permissions)
        // must never be swallowed silently.
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            storeLog
                .error(
                    "calendar store write FAILED (\(self.url.lastPathComponent, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                )
        }
    }

    /// ── CKSyncEngine state serialization ──────────────────────────────────────────
    /// CKSyncEngine hands us an opaque Data blob (its record/zone change-tracking state)
    /// to persist across launches. Kept beside the item cache; nil means "never synced".
    func loadSyncState() -> Data? {
        try? Data(contentsOf: syncStateURL)
    }

    func saveSyncState(_ data: Data?) {
        do {
            if let data {
                try data.write(to: syncStateURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: syncStateURL.path) {
                try FileManager.default.removeItem(at: syncStateURL)
            }
        } catch {
            storeLog.error("sync-state write FAILED: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Persistence failures are logged (visible in Console.app), never silently dropped.
let storeLog = Logger(subsystem: "dev.magnifical.calendar", category: "store")
