// CalendarEngine+Persistence — the data lifecycle: store save/load deltas, the cloud-sync
// seam (CKSyncEngine control + inbound applyRemote), anchor migration, and bulk
// import/export (.mdc backups, .ics, replaceAll).

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// Start CloudKit sync when this build carries the iCloud entitlement (the signed
    /// CalendarApp). The unsigned CalendarMac dev binary isn't entitled → no-op, local-only.
    func enableCloudSyncIfEntitled() {
        // NEVER sync in a recording/demo session: it would pull the user's real iCloud calendar into the
        // throwaway store (a privacy leak into GIFs), defeating the isolation. Mirrors importAppleCalendar's
        // demo guard.
        guard CloudSync.isEntitled, !Self.isDemoMode else { return }
        let c = CloudSync(engine: self, calendarId: registry.activeId, // sync the ACTIVE calendar's zone
                          readOnly: cloudReadOnly)
        cloud = c
        Task { await c.startIfAccountAvailable() }
        // The calendar LIST syncs independently of which calendar is open — started once, kept across
        // switches (stopCloudSync leaves it alone).
        if registrySync == nil {
            let rs = RegistrySync(engine: self, readOnly: cloudReadOnly)
            registrySync = rs
            Task { await rs.start() }
        }
    }

    /// Nudge a cloud fetch/push (foreground, periodic, or the Connectivity menu's "Sync Now").
    public func syncNow() {
        cloud?.syncNow()
        registrySync?.syncNow()
    }

    /// "Sync Now" from the Connectivity menu: refresh BOTH external sources — re-import Apple Calendar and
    /// fetch/push iCloud — and reflect progress in the monitor. No-op cloud in the local-only dev build.
    public func refreshConnectivity() {
        importAppleCalendar()
        importICSFeeds(urls: icsFeedURLs?() ?? [])
        guard cloud != nil else { return }
        syncMonitor.isSyncing = true
        cloud?.syncNow()
    }

    /// Current iCloud connectivity, for the settings UI. Instance-free (the settings window
    /// doesn't share the running engine) — reads the entitlement + CloudKit account status.
    /// CloudKit types stay contained in CloudSync; this just re-exports the module enum.
    public static func iCloudStatus() async -> ICloudStatus {
        await CloudSync.iCloudStatus()
    }

    /// A fixed anchor for a freshly created item: the current view (main) zone, resolved to a concrete
    /// id so it never drifts with the device (a stored anchor must not be "auto").
    var anchorNow: String {
        DeadlineTZ.concrete(mainTz)
    } // internal: +Extensions files stamp anchors

    /// One-time backfill so every timed event and deadline carries an explicit `anchorTz` — the display
    /// pipeline needs it to convert into the current view zone. Legacy items stored their wall-clock in
    /// the main tz, so the anchor IS the (resolved) main tz and the stored hours stay valid untouched.
    /// A deadline that carried a legacy `originTz` is RE-ANCHORED to that origin (its `hour` was the
    /// main-tz equivalent, so we re-express it as the origin wall-clock), preserving both the instant and
    /// the "(AOE 23:59)" label. Idempotent — items that already have an anchor are skipped.
    func migrateAnchors() {
        let main = DeadlineTZ.concrete(mainTz)
        var changed = false
        for i in items.events.indices where items.events[i].anchorTz == nil {
            items.events[i].anchorTz = main; changed = true
        }
        for i in items.deadlines.indices where items.deadlines[i].anchorTz == nil {
            let d = items.deadlines[i]
            if let origin = d.originTz,
               !DeadlineTZ.sameOffset(origin, mainTz, at: DeadlineTZ.instant(d.year, d.month, d.day, d.hour)) {
                let w = DeadlineTZ.convertWall(d.year, d.month, d.day, d.hour, from: mainTz, to: origin)
                items.deadlines[i].year = w.year; items.deadlines[i].month = w.month
                items.deadlines[i].day = w.day; items.deadlines[i].hour = w.hour
                items.deadlines[i].anchorTz = DeadlineTZ.concrete(origin)
            } else {
                items.deadlines[i].anchorTz = main
            }
            items.deadlines[i].originTz = nil // folded into anchorTz; the legacy field is retired
            changed = true
        }
        if changed {
            persistNow()
        }
    }

    /// ── Persistence ─────────────────────────────────────────────────────────────
    func persistNow() {
        let state = PersistedState(
            events: items.events,
            bands: items.bands,
            deadlines: items.deadlines,
            monthTrackNames: items.trackNames,
            rich: items.richById,
            dailyNotes: items.dailyNotes
        )
        store.save(state)
        emitDelta(to: state)
        NotificationScheduler.shared.requestResync() // data changed → re-plan the pending window
    }

    /// Diff the freshly-persisted state against what the sync layer last saw and emit the
    /// changed record ids. Before the cloud layer attaches, just track the baseline.
    private func emitDelta(to state: PersistedState) {
        guard let onLocalChange else { syncedState = state; return }
        let (up, del) = Self.recordDelta(from: syncedState, to: state)
        syncedState = state
        if !up.isEmpty || !del.isEmpty {
            onLocalChange(up, del)
        }
    }

    static func recordDelta(from old: PersistedState?,
                            to new: PersistedState) -> (upserts: [String], deletes: [String]) {
        var upserts: [String] = [], deletes: [String] = []
        func diff<T: Equatable>(_ o: [T], _ n: [T], _ id: (T) -> String) {
            let oldByID = Dictionary(o.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
            let newByID = Dictionary(n.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
            for (k, v) in newByID where oldByID[k] != v {
                upserts.append(k)
            }
            for k in oldByID.keys where newByID[k] == nil {
                deletes.append(k)
            }
        }
        diff(old?.events ?? [], new.events, \.id)
        diff(old?.bands ?? [], new.bands, \.id)
        diff(old?.deadlines ?? [], new.deadlines, \.id)
        if (old?.monthTrackNames ?? []) != (new.monthTrackNames ?? []) {
            upserts.append(trackNamesRecordID)
        }
        // Rich-field changes that DIDN'T move a body (a note/tag/promote/color edit) still need to sync:
        //   • a normal item id → re-save its body record (rich rides on it)
        //   • an imported SERIES key → its own standalone "Overlay" record (no body of ours to ride on)
        //   • an imported PER-OCCURRENCE key → the `hidden` dedup flag alone is local churn, but a
        //     USER-authored exclusion (userHidden — the make-local-copy "exdate") must reach other
        //     devices too, as its own Overlay record, or the occurrence resurrects there.
        let oldRich = old?.rich ?? [:], newRich = new.rich ?? [:]
        for k in Set(oldRich.keys).union(newRich.keys) {
            let o = oldRich[k], n = newRich[k]
            if o == n {
                continue
            }
            if isApplePerOccurrenceKey(k) {
                let keepO = o.map(hasUserOverlay) ?? false
                let keepN = n.map(hasUserOverlay) ?? false
                guard keepO || keepN else { continue } // dedup-only churn stays local
                if keepN {
                    upserts.append(k)
                } else {
                    deletes.append(k)
                }
            } else if isAppleSeriesKey(k) {
                // Only user-authored overlays are worth an iCloud record (skip managed-note-only churn).
                let keep = n.map(hasUserOverlay) ?? false
                if keep {
                    upserts.append(k)
                } else {
                    deletes.append(k)
                }
            } else {
                upserts.append(k) // normal item: re-materialize its body with the new rich
            }
        }
        let delSet = Set(deletes)
        upserts = Array(Set(upserts).subtracting(delSet))
        deletes = Array(delSet)
        return (upserts, deletes)
    }

    /// ── Cloud-sync seam: inbound + accessors (Phase 1) ────────────────────────────
    /// Snapshot of everything the sync layer needs to materialize records.
    public func syncSnapshot() -> PersistedState {
        PersistedState(
            events: items.events,
            bands: items.bands,
            deadlines: items.deadlines,
            monthTrackNames: items.trackNames,
            rich: items.richById,
            dailyNotes: items.dailyNotes
        )
    }

    /// Capture the current state as the sync baseline (call when the cloud layer attaches,
    /// so the first local edit emits an incremental delta rather than the whole store).
    public func beginSyncTracking() {
        syncedState = syncSnapshot()
    }

    public func loadSyncState() -> Data? {
        store.loadSyncState()
    }

    public func saveSyncState(_ data: Data?) {
        store.saveSyncState(data)
    }

    /// ── Bulk import / export (File menu: .ics / .mdc) ──────────────────────────────────
    /// The full local dataset, for writing a .mdc backup. (Same shape the sync layer snapshots.)
    public func exportState() -> PersistedState {
        syncSnapshot()
    }

    /// Append imported items (e.g. from an .ics file) as editable seed items — ONE undoable step.
    public func importItems(events: [TimedEvent] = [], bands: [BandEvent] = [],
                            deadlines: [Deadline] = [], rich: [String: RichFields] = [:]) {
        guard !events.isEmpty || !bands.isEmpty || !deadlines.isEmpty else { return }
        beginTxn()
        items.events.append(contentsOf: events)
        items.bands.append(contentsOf: bands)
        items.deadlines.append(contentsOf: deadlines)
        for (k, v) in rich {
            items.richById[k] = v
        }
        commitTxn()
    }

    /// Replace the ENTIRE local dataset (restoring a .mdc backup) — ONE undoable step, so an accidental
    /// import can be undone. Bumps the caches + persists, exactly like `restore`.
    public func replaceAll(_ s: PersistedState) {
        commitTxn()
        undoStack.append(editState); if undoStack.count > 100 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        wake(); caches.editGen &+= 1; caches.deadlineGen &+= 1
        items.events = s.events; items.bands = s.bands; items.deadlines = s.deadlines
        items.richById = s.rich ?? [:]
        if let tn = s.monthTrackNames {
            items.trackNames = tn
        }
        items.dailyNotes = s.dailyNotes ?? [:]
        selectedId = nil
        schedulePersist()
    }

    /// Write the whole calendar to a `.mdc` backup (a zip mirroring the web export). Throws on I/O error.
    public func exportMDC(to url: URL) throws {
        let files = try MDCBackup.encode(exportState(), exportedAt: Date())
        try Zipper.write(files, to: url)
    }

    /// Restore a `.mdc` (or the web's `.zip`) backup — replaces the entire local dataset (undoable).
    public func importMDC(from url: URL) throws {
        let state = try MDCBackup.decode(Zipper.read(url))
        replaceAll(state)
    }

    /// Import an `.ics` file's events as editable items. Returns how many were added.
    @discardableResult
    public func importICS(from url: URL) throws -> Int {
        try importICS(text: String(contentsOf: url, encoding: .utf8), provenance: url.lastPathComponent)
    }

    /// Import `.ics` TEXT (e.g. from the clipboard) as editable items. Returns how many were added.
    @discardableResult
    public func importICS(text: String, provenance: String) throws -> Int {
        let (events, bands, rich) = ICSImport.items(from: text, provenance: provenance)
        importItems(events: events, bands: bands, rich: rich)
        return events.count + bands.count
    }

    /// Apply records fetched from the cloud. Upserts replace/insert by id; deletes remove.
    /// Deliberately bypasses undo history and the local-delta emit — this IS the synced
    /// state, so it must not echo back out or land on the undo stack.
    public func applyRemote(events: [TimedEvent] = [], bands: [BandEvent] = [],
                            deadlines: [Deadline] = [], trackNames newNames: [[String]]? = nil,
                            deletedIDs: [String] = [], rich: [String: RichFields] = [:]) {
        wake() // remote data landed → a render must run
        caches.editGen &+= 1
        caches.deadlineGen &+= 1 // remote change may add/move/remove deadlines
        for e in events {
            Self.upsert(&items.events, e)
        }
        for b in bands {
            Self.upsert(&items.bands, b)
        }
        for d in deadlines {
            Self.upsert(&items.deadlines, d)
        }
        for (id, rf) in rich {
            items.richById[id] = rf
        }
        if let newNames, newNames.count == 12, newNames.allSatisfy({ $0.count == 4 }) {
            items.trackNames = newNames
        }
        for id in deletedIDs {
            items.events.removeAll { $0.id == id }
            items.bands.removeAll { $0.id == id }
            items.deadlines.removeAll { $0.id == id }
            items.richById[id] = nil
            if selectedId == id {
                selectedId = nil
            }
        }
        let state = PersistedState(
            events: items.events,
            bands: items.bands,
            deadlines: items.deadlines,
            monthTrackNames: items.trackNames,
            rich: items.richById,
            dailyNotes: items.dailyNotes
        )
        store.save(state)
        syncedState = state // adopt as baseline so the merge doesn't re-emit as a local delta
        NotificationScheduler.shared.requestResync() // remote merge bypasses persistNow → hook here too
        if !deletedIDs.isEmpty {
            onExternalDataChange?()
        } // a remote delete may have removed an open item
    }

    private static func upsert<T: Identifiable>(_ arr: inout [T], _ item: T) where T.ID == String {
        if let i = arr.firstIndex(where: { $0.id == item.id }) {
            arr[i] = item
        } else {
            arr.append(item)
        }
    }
}
