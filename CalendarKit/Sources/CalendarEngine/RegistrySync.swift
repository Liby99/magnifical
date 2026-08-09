// Cross-device sync of the CALENDAR LIST (not any calendar's contents). Each calendar's events live in
// its own zone (see CloudSync); this is a separate, always-on CKSyncEngine on a shared "Registry" zone
// holding one small record per calendar (id / name / createdAt / order). It lets a second device DISCOVER
// which calendars exist and their names even while those calendars are closed — opening one then syncs its
// items from its own zone. Local create/rename/remove enqueue an upsert/delete here; inbound changes merge
// into calendars.json (CalendarRegistry) and refresh the menu.
//
// Only started on the entitled signed build; the unsigned dev binary never touches CloudKit.

import CloudKit
import Foundation

@MainActor
final class RegistrySync: NSObject, CKSyncEngineDelegate {
    private static let recordType = "Calendar"
    private weak var engine: CalendarEngine?
    private let container: CKContainer
    private let zoneID = CKRecordZone.ID(zoneName: "Registry", ownerName: CKCurrentUserDefaultName)
    private var syncEngine: CKSyncEngine!
    private var knownRecords: [String: CKRecord] = [:]
    private let stateURL: URL
    private let recordCacheURL: URL
    /// Read-only mode (the iPhone viewer): discover calendars, never push the local list. Mirrors
    /// CloudSync.readOnly — see there for the policy.
    private let readOnly: Bool

    init(engine: CalendarEngine, readOnly: Bool = false) {
        self.engine = engine
        self.readOnly = readOnly
        self.container = CKContainer(identifier: CloudSync.containerID)
        let base = calendarKitBaseDir() // beside calendars.json — the registry is app-wide, not per-calendar
        self.stateURL = base.appendingPathComponent("registrySync.bin")
        self.recordCacheURL = base.appendingPathComponent("registryRecords.plist")
        super.init()
    }

    /// Start when signed in. On first run, create the zone + push every local calendar; always fetch so a
    /// fresh device discovers calendars created elsewhere.
    func start() async {
        let status = await (try? container.accountStatus()) ?? .couldNotDetermine
        guard status == .available, let engine else { return }
        loadRecordCache()
        let savedState = loadState()
        let config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: savedState, delegate: self
        )
        syncEngine = CKSyncEngine(config)
        if savedState == nil, !readOnly {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            syncEngine.state
                .add(pendingRecordZoneChanges: engine.allCalendars.map { .saveRecord(recordID(for: $0.id)) })
        }
        Task { [weak self] in try? await self?.syncEngine.fetchChanges() }
    }

    func syncNow() {
        guard let syncEngine else { return }
        Task { [readOnly] in
            try? await syncEngine.fetchChanges()
            if !readOnly {
                try? await syncEngine.sendChanges()
            }
        }
    }

    /// ── Local mutations ────────────────────────────────────────────────────────────────────────────
    func upsertCalendar(_ id: String) {
        guard !readOnly else { return }
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(for: id))])
    }

    func removeCalendar(_ id: String) {
        knownRecords[id] = nil
        guard !readOnly else { return }
        syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(for: id))])
    }

    /// ── Outbound: materialize a calendar's record from the local registry ────────────────────────────
    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        if readOnly {
            return nil
        } // hard block: a read-only client sends NOTHING
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        var records: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            if case let .saveRecord(id) = change {
                records[id] = materialize(id)
            }
        }
        let resolved = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { resolved[$0] }
    }

    private func materialize(_ id: CKRecord.ID) -> CKRecord? {
        let name = id.recordName
        guard let meta = engine?.registry.meta(name)
        else { return nil } // deleted locally → matching delete resolves it
        let r = knownRecords[name] ?? CKRecord(recordType: Self.recordType, recordID: id)
        r["name"] = meta.name as NSString
        r["createdAt"] = meta.createdAt as NSDate
        r["order"] = meta.order as NSNumber
        return r
    }

    /// ── Delegate event pump ──────────────────────────────────────────────────────────────────────
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(e): saveState(e.stateSerialization)
        case let .accountChange(e): handleAccountChange(e)
        case let .fetchedRecordZoneChanges(e): applyFetched(modifications: e.modifications, deletions: e.deletions)
        case let .sentRecordZoneChanges(e): handleSent(e)
        default: break
        }
    }

    private func handleAccountChange(_ e: CKSyncEngine.Event.AccountChange) {
        switch e.changeType {
        case .signOut, .switchAccounts:
            clearState(); knownRecords.removeAll(); saveRecordCache()
        default: break
        }
    }

    /// ── Inbound: server records → local registry ──────────────────────────────────────────────────
    private func applyFetched(
        modifications: [CKDatabase.RecordZoneChange.Modification],
        deletions: [CKDatabase.RecordZoneChange.Deletion]
    ) {
        var upserts: [CalendarMeta] = []
        for m in modifications {
            let r = m.record
            knownRecords[r.recordID.recordName] = r
            guard r.recordType == Self.recordType, let name = r["name"] as? String else { continue }
            upserts.append(CalendarMeta(
                id: r.recordID.recordName, name: name,
                createdAt: (r["createdAt"] as? Date) ?? .distantPast,
                order: (r["order"] as? Int) ?? 0
            ))
        }
        let deletes = deletions.map(\.recordID.recordName)
        for id in deletes {
            knownRecords[id] = nil
        }
        saveRecordCache()
        if !upserts.isEmpty || !deletes.isEmpty {
            engine?.applyRemoteCalendars(upserts: upserts, deletes: deletes)
        }
    }

    private func handleSent(_ e: CKSyncEngine.Event.SentRecordZoneChanges) {
        for saved in e.savedRecords {
            knownRecords[saved.recordID.recordName] = saved
        }
        for fail in e.failedRecordSaves {
            let id = fail.record.recordID
            switch fail.error.code {
            case .serverRecordChanged:
                if let server = fail.error.serverRecord {
                    knownRecords[id.recordName] = server
                }
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .zoneNotFound, .userDeletedZone:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            default: break
            }
        }
        saveRecordCache()
    }

    /// ── Persistence ────────────────────────────────────────────────────────────────────────────────
    private func recordID(for name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ s: CKSyncEngine.State.Serialization) {
        try? JSONEncoder().encode(s).write(to: stateURL, options: .atomic)
    }

    private func clearState() {
        try? FileManager.default.removeItem(at: stateURL)
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
