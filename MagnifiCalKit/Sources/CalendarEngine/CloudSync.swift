// Phase 2 — CloudKit sync via CKSyncEngine.
//
// The engine's in-memory value arrays stay the source of truth for the running app;
// this layer mirrors them to the CloudKit PRIVATE database (the user's own devices,
// keyed to their Apple ID — no server to run). CKSyncEngine owns scheduling, push
// delivery, retry, and change-tracking state; we own the item↔CKRecord mapping and
// conflict policy (last-writer-wins, favouring the local edit).
//
// Only started when the process actually carries the iCloud entitlement, so the
// unsigned `CalendarMac` dev binary stays local-only and never touches CloudKit.

import CalendarGeometry
import CloudKit
import Foundation
import Security

/// Developer maintenance (Settings ▸ Developer): enumerate every zone in the private database and
/// delete the ones belonging to NO registered calendar — migration leftovers whose records linger
/// invisibly server-side (and, before inbound zone-filtering, resurrected deleted events). Never
/// touches registered calendars' zones, the Registry zone, or CloudKit's default zone. Reports the
/// pruned zone names. Caveat for multi-device users: a calendar created on another device whose
/// registry entry hasn't synced here yet would LOOK orphaned — sync all devices first.
@MainActor public func pruneOrphanCloudZones(completion: @escaping @Sendable (Result<[String], Error>) -> Void) {
    var keep = Set(CalendarRegistry().all.map(\.id))
    keep.insert("Registry") // RegistrySync's zone
    keep.insert(CKRecordZone.default().zoneID.zoneName)
    let db = CKContainer(identifier: CloudSync.containerID).privateCloudDatabase
    db.fetchAllRecordZones { zones, err in
        if let err {
            completion(.failure(err)); return
        }
        let orphans = (zones ?? []).map(\.zoneID).filter { !keep.contains($0.zoneName) }
        guard !orphans.isEmpty else {
            completion(.success([])); return
        }
        let op = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: orphans)
        op.modifyRecordZonesResultBlock = { result in
            switch result {
            case .success: completion(.success(orphans.map(\.zoneName)))
            case let .failure(e): completion(.failure(e))
            }
        }
        db.add(op)
    }
}

@MainActor
final class CloudSync: NSObject, CKSyncEngineDelegate {
    /// DELIBERATELY the legacy id — do NOT "fix" to match the dev.magnifical.calendar bundle id.
    /// Container ids are invisible to users and freely attach to any app id on the same team;
    /// every user's private database lives HERE, and moving containers would mean a client-side
    /// re-upload of all records from every device. The 2026-08 bundle-id rename kept it on purpose.
    static let containerID = "iCloud.dev.libirabu.calendar"

    // WEAK, not unowned: CKSyncEngine retains this delegate (and we retain it back), so CloudSync can
    // outlive the CalendarEngine that created it — a late callback (e.g. saveState) would then read a
    // dangling `unowned` and crash. Weak + guard makes those callbacks no-op once the engine is gone.
    private weak var engine: CalendarEngine?
    private let container: CKContainer
    /// Each MagnifiCal calendar syncs to its OWN CloudKit zone (zoneName = the calendar id), so calendars are
    /// disjoint on the server and deleting one = deleting its zone. The active calendar's CloudSync points
    /// here; switching calendars tears this down and starts a new CloudSync for the new zone.
    private let zoneID: CKRecordZone.ID
    private var syncEngine: CKSyncEngine!
    /// Read-only mode (the iPhone viewer): fetch + apply remote changes, but NEVER send — no
    /// initial full push, no onLocalChange wiring, and nextRecordZoneChangeBatch returns nil so
    /// nothing can reach the server even if a change were enqueued somehow.
    private let readOnly: Bool

    // System-fields cache: id → CKRecord carrying the server change-tag. Materialized
    // records start from these so saves don't spuriously hit `serverRecordChanged`.
    private var knownRecords: [String: CKRecord] = [:]
    private let recordCacheURL: URL

    init(engine: CalendarEngine, calendarId: String, readOnly: Bool = false) {
        self.engine = engine
        self.readOnly = readOnly
        self.container = CKContainer(identifier: CloudSync.containerID)
        self.zoneID = CKRecordZone.ID(zoneName: calendarId, ownerName: CKCurrentUserDefaultName)
        // Per-calendar record cache, beside that calendar's data.json / syncState.bin.
        self.recordCacheURL = calendarDir(calendarId).appendingPathComponent("records.plist")
        super.init()
    }

    /// Delete a calendar's CloudKit zone (and thus all its records) — called when the calendar is removed.
    /// A direct database op (not via a CKSyncEngine) so it doesn't depend on a live sync for that calendar.
    /// No-op / silent on the unentitled dev build or when signed out.
    static func deleteZone(calendarId: String) {
        guard isEntitled else { return }
        let zoneID = CKRecordZone.ID(zoneName: calendarId, ownerName: CKCurrentUserDefaultName)
        let db = CKContainer(identifier: containerID).privateCloudDatabase
        db.delete(withRecordZoneID: zoneID) { _, _ in } // best-effort; server prunes the records
    }

    /// True only when this binary is signed with the iCloud container entitlement.
    /// Reading it via SecTask is crash-safe (unlike constructing a CKContainer for a
    /// container the process isn't entitled to, which throws an uncatchable exception).
    static var isEntitled: Bool {
        #if os(iOS)
            // iOS apps are always signed with their entitlements (a real build carries the
            // iCloud container), and SecTaskCreateFromSelf is macOS-only. So on iOS, sync is on.
            return true
        #else
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            let key = "com.apple.developer.icloud-container-identifiers" as CFString
            return SecTaskCopyValueForEntitlement(task, key, nil) != nil
        #endif
    }

    /// ── Status (for the settings UI) ──────────────────────────────────────────────
    /// Instance-free connectivity probe. Not entitled → `.localOnly` without ever building a
    /// CKContainer (which would throw for an unentitled process). Otherwise map the account status.
    static func iCloudStatus() async -> ICloudStatus {
        guard isEntitled else { return .localOnly }
        let status = await (try? CKContainer(identifier: containerID).accountStatus()) ?? .couldNotDetermine
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .unavailable
        case .couldNotDetermine: return .unknown
        @unknown default: return .unknown
        }
    }

    /// ── Lifecycle ─────────────────────────────────────────────────────────────────
    func startIfAccountAvailable() async {
        let status = await (try? container.accountStatus()) ?? .couldNotDetermine
        guard status == .available else { return } // signed out → stay local, retry on account change
        guard let engine else { return } // engine gone → nothing to sync
        loadRecordCache()

        let savedState = loadState()
        let config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: savedState,
            delegate: self
        )
        syncEngine = CKSyncEngine(config)

        engine.beginSyncTracking()
        if !readOnly {
            engine.onLocalChange = { [weak self] upserts, deletes in
                self?.localChanged(upserts: upserts, deletes: deletes)
            }
        }
        startPeriodicSync()

        // First run on this device: create the zone and push everything we have. On a
        // fresh second device this set is small/empty and the initial fetch fills it in.
        // Read-only: never — the phone contributes nothing; the Mac creates the zone.
        if savedState == nil, !readOnly {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            let snap = engine.syncSnapshot()
            // Standalone overlay records for imported events the user has customized (color/promote/notes/tags).
            // Series overlays AND per-occurrence exclusions (the make-local-copy "exdate") — any
            // imported-key rich entry carrying user-authored data.
            let overlayIDs = (snap.rich ?? [:])
                .filter { CalendarEngine.hasImportedPrefix($0.key) && CalendarEngine.hasUserOverlay($0.value) }
                .map(\.key)
            let ids = snap.events.map(\.id) + snap.bands.map(\.id) + snap.deadlines.map(\.id)
                + overlayIDs + [CalendarEngine.trackNamesRecordID]
            syncEngine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(recordID(for: $0)) })
        }
    }

    /// Nudge a full round-trip (foreground, the 5-min timer, or the Connectivity menu). Fetches remote
    /// changes then flushes any pending local ones. No-op until the engine has started. The monitor's
    /// `lastSyncedAt` is stamped by the `didFetchChanges`/`didSendChanges` delegate events, not here.
    func syncNow() {
        guard let syncEngine else { engine?.syncMonitor.isSyncing = false; return }
        Task { [weak self, readOnly] in
            try? await syncEngine.fetchChanges()
            if !readOnly {
                try? await syncEngine.sendChanges()
            }
            self?.engine?.syncMonitor.isSyncing = false
        }
    }

    /// Detach from the engine and stop syncing — used when the engine switches to a different calendar
    /// (a new CloudSync is started for the new calendar's zone). Late CKSyncEngine callbacks then no-op
    /// because `engine` is nil. Note: the item ZONE is still the shared one until the zone-per-calendar
    /// refactor (Phase 6); this lifecycle hook is where that will slot in.
    func stop() {
        periodicTimer?.invalidate(); periodicTimer = nil
        engine?.onLocalChange = nil
        engine = nil
        syncEngine = nil
    }

    /// CKSyncEngine already syncs on push, but pushes aren't always delivered (no APNs, backgrounded,
    /// throttled). A modest periodic fetch backstops that and keeps "last synced" moving predictably.
    private var periodicTimer: Timer?
    private static let periodInterval: TimeInterval = 300 // 5 minutes
    private func startPeriodicSync() {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: Self.periodInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
    }

    /// ── Outbound: local edits → pending CloudKit changes ──────────────────────────
    private func localChanged(upserts: [String], deletes: [String]) {
        guard let syncEngine else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        pending += upserts.map { .saveRecord(recordID(for: $0)) }
        pending += deletes.map { .deleteRecord(recordID(for: $0)) }
        for id in deletes {
            knownRecords[id] = nil
        }
        syncEngine.state.add(pendingRecordZoneChanges: pending)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        if readOnly {
            return nil
        } // hard block: a read-only client sends NOTHING
        let scope = context.options.scope
        let raw = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        // Dedupe per record id: the same record gets queued repeatedly (edit bursts, conflict
        // re-enqueues), and a batch holding one id twice is rejected WHOLESALE by the server
        // ("You can't save the same record twice") — poisoning every send, so no local edit ever
        // reaches iCloud. One change per id; a pending delete beats a stale save.
        var deletes = Set<CKRecord.ID>()
        for change in raw {
            if case let .deleteRecord(id) = change {
                deletes.insert(id)
            }
        }
        var seen = Set<CKRecord.ID>()
        let pending = raw.filter { change in
            switch change {
            case let .saveRecord(id): !deletes.contains(id) && seen.insert(id).inserted
            case let .deleteRecord(id): seen.insert(id).inserted
            @unknown default: true
            }
        }
        guard !pending.isEmpty, let engine else { return nil }
        let snap = engine.syncSnapshot()
        // Materialize up front on the main actor (touches knownRecords); the provider
        // closure, which CKSyncEngine calls off-actor, only reads the plain dictionary.
        var records: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            if case let .saveRecord(id) = change {
                records[id] = materialize(id, from: snap)
            }
        }
        let resolved = records // immutable capture for the off-actor provider closure
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            resolved[recordID]
        }
    }

    /// ── Delegate event pump ───────────────────────────────────────────────────────
    /// Scope fetches to THIS calendar's zone — the registry has its own engine (RegistrySync),
    /// and other calendars' zones are none of this engine's business (see the zone filter in
    /// applyFetched, which this makes cheap as well as correct).
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var opts = CKSyncEngine.FetchChangesOptions()
        opts.scope = .zoneIDs([zoneID])
        return opts
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(e):
            saveState(e.stateSerialization)
        case let .accountChange(e):
            handleAccountChange(e)
        case let .fetchedRecordZoneChanges(e):
            applyFetched(modifications: e.modifications, deletions: e.deletions)
        case let .sentRecordZoneChanges(e):
            handleSent(e)
        case .didFetchChanges, .didSendChanges:
            engine?.syncMonitor.markSynced() // a fetch/push round-trip completed → stamp "last synced"
        case .fetchedDatabaseChanges, .sentDatabaseChanges,
             .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .willSendChanges:
            break
        @unknown default:
            break
        }
    }

    private func handleAccountChange(_ e: CKSyncEngine.Event.AccountChange) {
        switch e.changeType {
        case .signOut, .switchAccounts:
            // Another user's data must not linger; drop local sync state + record cache.
            engine?.saveSyncState(nil)
            knownRecords.removeAll(); saveRecordCache()
        case .signIn:
            break
        @unknown default:
            break
        }
    }

    /// ── Inbound: server records → engine ──────────────────────────────────────────
    private func applyFetched(
        modifications: [CKDatabase.RecordZoneChange.Modification],
        deletions: [CKDatabase.RecordZoneChange.Deletion]
    ) {
        var events: [TimedEvent] = [], bands: [BandEvent] = [], deadlines: [Deadline] = []
        var rich: [String: RichFields] = [:]
        var trackNames: [[String]]? = nil
        // LOCAL WINS: any record with a pending (un-pushed) local change is NEWER here than on the
        // server — applying the fetched copy would revert the user's edit under their cursor (the
        // "rename keeps reverting" bug: the echo landed inside commitTxn's 0.6s window, turned the
        // edit into a detected no-op, and even suppressed the persist). Skip those records entirely
        // — including their knownRecords tag, so our eventual push conflicts (serverRecordChanged)
        // and re-pushes the local copy over the server's. Display NEVER waits on, nor is dictated
        // by, the cloud; the server converges to us.
        let locallyDirty = Set((syncEngine?.state.pendingRecordZoneChanges ?? []).map { change -> String in
            switch change {
            case let .saveRecord(id), let .deleteRecord(id): id.recordName
            @unknown default: ""
            }
        })
        // ZONE FILTER: a CKSyncEngine fetches the WHOLE private database, but this CloudSync owns
        // exactly ONE calendar zone. Without the filter, records living in OTHER zones (another
        // calendar, or a legacy/migration leftover) merged into this calendar on every fetch —
        // and since deletes target THIS zone (recordID(for:)), the server answered unknownItem
        // and the ghosts resurrected on the next fetch, forever.
        for m in modifications where m.record.recordID.zoneID == zoneID
            && !locallyDirty.contains(m.record.recordID.recordName) {
            let r = m.record
            let name = r.recordID.recordName
            knownRecords[name] = r
            switch r.recordType {
            case "TimedEvent": if let v = decodeEvent(r) {
                    events.append(v); rich[name] = readRich(r)
                }
            case "BandEvent": if let v = decodeBand(r) {
                    bands.append(v); rich[name] = readRich(r)
                }
            case "Deadline": if let v = decodeDeadline(r) {
                    deadlines.append(v); rich[name] = readRich(r)
                }
            case "TrackNames": trackNames = decodeTrackNames(r)
            case "Overlay": rich[name] = readRich(r) // imported-event overlay: no body, merges into richById
            default: break
            }
        }
        // Same local-wins rule for deletions: a server delete of a record we're about to save
        // must not remove it locally — our pending save recreates it server-side.
        let deletedIDs = deletions.filter { $0.recordID.zoneID == zoneID }
            .map(\.recordID.recordName).filter { !locallyDirty.contains($0) }
        for id in deletedIDs {
            knownRecords[id] = nil
        }
        saveRecordCache()
        if !events.isEmpty || !bands.isEmpty || !deadlines.isEmpty || trackNames != nil || !deletedIDs.isEmpty || !rich
            .isEmpty {
            engine?.applyRemote(events: events, bands: bands, deadlines: deadlines,
                                trackNames: trackNames, deletedIDs: deletedIDs, rich: rich)
        }
    }

    private func handleSent(_ e: CKSyncEngine.Event.SentRecordZoneChanges) {
        for saved in e.savedRecords {
            knownRecords[saved.recordID.recordName] = saved
        }
        guard !readOnly else { saveRecordCache(); return } // unreachable (nothing sends) — belt and braces
        for fail in e.failedRecordSaves {
            let name = fail.record.recordID.recordName
            switch fail.error.code {
            case .serverRecordChanged:
                // Adopt the server change-tag, then re-enqueue our save so the local edit
                // wins (last-writer-wins, local-favoured). Rare for a single user.
                if let server = fail.error.serverRecord {
                    knownRecords[name] = server
                }
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(fail.record.recordID)])
            case .zoneNotFound, .userDeletedZone:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(fail.record.recordID)])
            case .serverRejectedRequest, .unknownItem:
                break // give up on this record
            default:
                break // transient — CKSyncEngine retries automatically
            }
        }
        saveRecordCache()
    }

    /// ── Item ⇄ CKRecord mapping ───────────────────────────────────────────────────
    private func recordID(for name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func base(_ name: String, _ type: CKRecord.RecordType) -> CKRecord {
        knownRecords[name] ?? CKRecord(recordType: type, recordID: recordID(for: name))
    }

    /// ── Full-fidelity fields (notes/tags/recurrence/…) the lean item types don't carry ──
    /// Write them onto the record, clearing any that are absent so an edit can't leave a stale value.
    private func writeRich(_ r: CKRecord, _ rf: RichFields?) {
        r["notes"] = rf?.notes as CKRecordValue?
        r["tags"] = ((rf?.tags.isEmpty == false) ? rf?.tags : nil) as CKRecordValue?
        r["repeatJSON"] = rf?.repeatJSON as CKRecordValue?
        r["promoteTrack"] = rf?.promoteTrack.map { NSNumber(value: $0) } as CKRecordValue?
        r["originTz"] = rf?.originTz as CKRecordValue?
        r["source"] = (rf?.source ?? "manual") as NSString
        r["hidden"] = ((rf?.hidden ?? false) ? 1 : 0) as NSNumber
        r["createdByAI"] = ((rf?.createdByAI ?? false) ? 1 : 0) as NSNumber
        r["colorOverride"] = rf?.colorOverride as CKRecordValue?
        r["userHidden"] = ((rf?.userHidden ?? false) ? 1 : 0) as NSNumber
        // Per-occurrence notes (recurring "This Event" notes), as a JSON string field. This was
        // MISSING: the record round-trip dropped them, and since inbound sync replaces richById
        // wholesale, every fetched echo wiped locally-saved occurrence notes.
        r["occurrenceNotesJSON"] = (rf?.occurrenceNotes)
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } as CKRecordValue?
    }

    private func readRich(_ r: CKRecord) -> RichFields {
        var rf = readRichBase(r)
        rf.occurrenceNotes = (r["occurrenceNotesJSON"] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        return rf
    }

    private func readRichBase(_ r: CKRecord) -> RichFields {
        RichFields(
            notes: r["notes"] as? String,
            tags: (r["tags"] as? [String]) ?? [],
            repeatJSON: r["repeatJSON"] as? String,
            promoteTrack: r["promoteTrack"] as? Int,
            originTz: r["originTz"] as? String,
            source: (r["source"] as? String) ?? "manual",
            hidden: ((r["hidden"] as? Int) ?? 0) != 0,
            createdByAI: ((r["createdByAI"] as? Int) ?? 0) != 0,
            colorOverride: r["colorOverride"] as? String,
            userHidden: ((r["userHidden"] as? Int) ?? 0) != 0
        )
    }

    /// Build the CKRecord to save for `recordID` from the current snapshot, or nil if the
    /// item is gone (a stale save that a matching delete will resolve).
    private func materialize(_ id: CKRecord.ID, from snap: PersistedState) -> CKRecord? {
        let name = id.recordName
        if name == CalendarEngine.trackNamesRecordID {
            let r = base(name, "TrackNames")
            r["json"] = jsonString(snap.monthTrackNames ?? []) as CKRecordValue?
            return r
        }
        if let e = snap.events.first(where: { $0.id == name }) {
            let r = base(name, "TimedEvent")
            r["year"] = e.year as NSNumber; r["month"] = e.month as NSNumber; r["day"] = e.day as NSNumber
            r["startHour"] = Double(e.startHour) as NSNumber; r["endHour"] = Double(e.endHour) as NSNumber
            r["title"] = e.title as NSString; r["color"] = e.color as NSString
            r["anchorTz"] = e
                .anchorTz as CKRecordValue? // the event's timezone anchor — must round-trip or it stops converting
            writeRich(r, snap.rich?[name]); return r
        }
        if let b = snap.bands.first(where: { $0.id == name }) {
            let r = base(name, "BandEvent")
            r["year"] = b.year as NSNumber; r["month"] = b.month as NSNumber; r["track"] = b.track as NSNumber
            r["startDay"] = b.startDay as NSNumber; r["endDay"] = b.endDay as NSNumber
            r["title"] = b.title as NSString; r["color"] = b.color as NSString
            writeRich(r, snap.rich?[name]); return r
        }
        if let d = snap.deadlines.first(where: { $0.id == name }) {
            let r = base(name, "Deadline")
            r["year"] = d.year as NSNumber; r["month"] = d.month as NSNumber; r["day"] = d.day as NSNumber
            r["hour"] = Double(d.hour) as NSNumber; r["title"] = d.title as NSString; r["color"] = d.color as NSString
            r["originTz"] = d.originTz as CKRecordValue?
            r["anchorTz"] = d.anchorTz as CKRecordValue? // timezone anchor — must round-trip or it stops converting
            writeRich(r, snap.rich?[name]); return r
        }
        // No body of ours: a user overlay on an imported event — the SERIES key (color / promote /
        // notes / tags / hide) or a PER-OCCURRENCE key (the make-local-copy exclusion, userHidden).
        // Sync it as a standalone "Overlay" record so it reaches the other devices.
        if CalendarEngine.hasImportedPrefix(name), let rf = snap.rich?[name] {
            let r = base(name, "Overlay")
            writeRich(r, rf); return r
        }
        return nil
    }

    private func decodeEvent(_ r: CKRecord) -> TimedEvent? {
        guard let month = r["month"] as? Int, let day = r["day"] as? Int,
              let sh = r["startHour"] as? Double, let eh = r["endHour"] as? Double,
              let title = r["title"] as? String, let color = r["color"] as? String else { return nil }
        return TimedEvent(id: r.recordID.recordName, year: (r["year"] as? Int) ?? 0, month: month, day: day,
                          startHour: CGFloat(sh), endHour: CGFloat(eh), title: title, color: color,
                          // Legacy records (pre-anchor) carried device-local wall-clock → default to the device zone
                          // rather than nil, so a fetched item keeps converting without waiting for an app restart.
                          anchorTz: (r["anchorTz"] as? String) ?? DeadlineTZ.concrete("auto"))
    }

    private func decodeBand(_ r: CKRecord) -> BandEvent? {
        guard let year = r["year"] as? Int, let month = r["month"] as? Int, let track = r["track"] as? Int,
              let sd = r["startDay"] as? Int, let ed = r["endDay"] as? Int,
              let title = r["title"] as? String, let color = r["color"] as? String else { return nil }
        return BandEvent(id: r.recordID.recordName, year: year, month: month, track: track,
                         startDay: sd, endDay: ed, title: title, color: color)
    }

    private func decodeDeadline(_ r: CKRecord) -> Deadline? {
        guard let year = r["year"] as? Int, let month = r["month"] as? Int, let day = r["day"] as? Int,
              let hour = r["hour"] as? Double, let title = r["title"] as? String,
              let color = r["color"] as? String else { return nil }
        return Deadline(id: r.recordID.recordName, year: year, month: month, day: day,
                        hour: CGFloat(hour), title: title, color: color, originTz: r["originTz"] as? String,
                        anchorTz: (r["anchorTz"] as? String) ?? DeadlineTZ.concrete("auto"))
    }

    private func decodeTrackNames(_ r: CKRecord) -> [[String]]? {
        guard let json = r["json"] as? String, let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([[String]].self, from: data) else { return nil }
        return names
    }

    private func jsonString(_ names: [[String]]) -> String {
        (try? String(data: JSONEncoder().encode(names), encoding: .utf8) ?? "") ?? ""
    }

    /// ── Persistence: CKSyncEngine state + record-metadata cache ───────────────────
    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = engine?.loadSyncState() else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ s: CKSyncEngine.State.Serialization) {
        engine?.saveSyncState(try? JSONEncoder().encode(s))
    }

    private func loadRecordCache() {
        guard let data = try? Data(contentsOf: recordCacheURL),
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
              as? [String: Data] else { return }
        for (id, d) in dict {
            guard let coder = try? NSKeyedUnarchiver(forReadingFrom: d) else { continue }
            coder.requiresSecureCoding = true
            if let rec = CKRecord(coder: coder) {
                knownRecords[id] = rec
            }
            coder.finishDecoding()
        }
    }

    private func saveRecordCache() {
        var dict: [String: Data] = [:]
        for (id, rec) in knownRecords {
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            rec.encodeSystemFields(with: coder)
            dict[id] = coder.encodedData
        }
        let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        try? data?.write(to: recordCacheURL, options: .atomic)
    }
}
