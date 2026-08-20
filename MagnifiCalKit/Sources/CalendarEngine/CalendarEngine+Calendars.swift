// Multiple calendars ("documents"): create / switch / remove / rename, plus the read accessors the File
// menu renders. Switching is built on the existing whole-dataset swap — persist the current calendar,
// repoint the store, and reload — with the session state (undo, selection, imported items, caches) reset
// so nothing bleeds from one calendar into the next. Each calendar is disjoint; only one is open at a time.

import Foundation

/// One row of the File ▸ Calendars submenu: every calendar (the open one ticked), with its item count.
public struct CalendarMenuRow: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let count: Int
    public let active: Bool

    /// The submenu label, e.g. "Main: 325 events" — shared by both shells so they can't drift.
    public var label: String {
        "\(name): \(count) event\(count == 1 ? "" : "s")"
    }
}

public extension CalendarEngine {
    /// ── Read accessors (for the File menu) ────────────────────────────────────────────────────────
    var activeCalendar: CalendarMeta? {
        registry.meta(registry.activeId)
    }

    /// The active calendar's id — the key external-source prefs (Apple selection, ICS feeds) scope by.
    var activeCalendarId: String {
        registry.activeId
    }

    /// A calendar id's user-facing name, read from the on-disk registry — for the engine-less
    /// Settings window (which tracks the active id via UserDefaults, see PrefKeys.currentCalendarId).
    static func calendarDisplayName(_ id: String) -> String {
        CalendarRegistry().meta(id)?.name ?? "Main"
    }

    var activeCalendarName: String {
        activeCalendar?.name ?? "Main"
    }

    var allCalendars: [CalendarMeta] {
        registry.all
    }

    /// Calendars you can switch to (for "Recently Opened Calendars ▸"): the recently-opened ones first,
    /// then any others — so a calendar discovered from another device (never opened here) is still reachable.
    var recentCalendars: [CalendarMeta] {
        let active = registry.activeId
        let recent = registry.recents(excluding: active)
        let seen = Set(recent.map(\.id))
        let others = registry.all.filter { $0.id != active && !seen.contains($0.id) }
        return recent + others
    }

    /// "Remove Current" is disabled when this is the only calendar (there must always be one) —
    /// and ALWAYS for Main: it's the anchor calendar (fixed id, every device's shared iCloud
    /// zone, the legacy-migration target), so it can never be deleted.
    var canRemoveCalendar: Bool {
        registry.all.count > 1 && registry.activeId != CalendarRegistry.mainId
    }

    /// Rows for the File ▸ Calendars submenu — EVERY calendar, the open one flagged `active`.
    /// Called at MENU-OPEN time by both shells (their NSMenuDelegate rebuilds the submenu in
    /// menuNeedsUpdate; SwiftUI Commands can't be trusted to re-render dynamic content). The
    /// active calendar counts its LIVE items; the others' counts come from a one-shot read of
    /// their data.json, cached — an inactive calendar's store can't change while it's closed
    /// (its zone isn't syncing), and the cache entry is refreshed on switch-away.
    func calendarMenuRows() -> [CalendarMenuRow] {
        let active = registry.activeId
        return registry.all.map { m in
            let count: Int
            if m.id == active {
                count = liveItemCount
            } else if let hit = calCountCache[m.id] {
                count = hit
            } else {
                let s = ItemStore(calendarId: m.id).load()
                count = s.map { $0.events.count + $0.bands.count + $0.deadlines.count } ?? 0
                calCountCache[m.id] = count
            }
            return CalendarMenuRow(id: m.id, name: m.name, count: count, active: m.id == active)
        }
    }

    internal var liveItemCount: Int {
        items.events.count + items.bands.count + items.deadlines.count
    }

    /// ── Switch ────────────────────────────────────────────────────────────────────────────────────
    /// Open a different calendar: persist the current one, tear down its sync, reset all session state,
    /// then repoint the store and load the target. No-op if it's already active or doesn't exist.
    /// `persistCurrent: false` is used when the current calendar is being deleted (nothing to save).
    func switchCalendar(to id: String, persistCurrent: Bool = true) {
        guard id != registry.activeId, registry.meta(id) != nil else { return }
        commitTxn() // flush any pending edit on the current calendar
        if persistCurrent {
            persistNow()
        }
        calCountCache[registry.activeId] = liveItemCount // menu count for the calendar we're leaving
        stopCloudSync() // detach cloud from the current calendar

        // Reset everything scoped to the current calendar so nothing bleeds across.
        undoStack.removeAll(); redoStack.removeAll(); pendingUndo = nil
        setSelection([], primary: nil)
        imported = ImportedItems() // read-only Apple items belong to the old calendar
        colorPreview = nil; hover = .none; hoveredEventId = nil
        // Display caches were keyed to the old data — but the gen counters must CARRY FORWARD
        // (+1), not restart at 0: every derived cache in the app keys on them (todo/proj feeds,
        // entity index, panel todoDataStamp snapshots, the events overlay's per-month packing via
        // displayGen), and a reset-to-zero collides with entries stamped by the OLD calendar —
        // fresh counters == cached gens → the old calendar's data served as current forever.
        var fresh = DisplayCaches()
        fresh.editGen = caches.editGen &+ 1
        fresh.noteGen = caches.noteGen &+ 1
        fresh.deadlineGen = caches.deadlineGen &+ 1
        caches = fresh
        // Drop the parsed feeds outright: on a gen MISMATCH todoFeed()/projFeed() still SERVE the
        // stale (old calendar's) rows while a refresh coalesces — a nil cache rebuilds inline on
        // the next read instead, so the panels never flash another calendar's todos/projects.
        todoFeedCache = nil; projFeedCache = nil
        todoFeedWork?.cancel(); todoFeedWork = nil
        entityIdxCache = nil
        entityIdxWork?.cancel(); entityIdxWork = nil

        // Repoint at the target calendar and load it.
        registry.setActive(id)
        store = ItemStore(calendarId: id)
        restoreItemsFromStore()
        migrateAnchors()

        // Re-attach external sources for the NEW calendar (its own Apple selection, its own ICS
        // feed subscriptions, its own iCloud state).
        enableCloudSyncIfEntitled()
        importAppleCalendar()
        importICSFeeds(urls: icsFeedURLs?() ?? []) // per-calendar feed list (see ICSFeeds in CalendarUI)
        onExternalDataChange?() // dismiss any drawer/dialog bound to a now-absent item
        NotificationScheduler.shared.requestResync() // schedule now reflects the NEW calendar's items
        wake()
    }

    /// ── Create ──────────────────────────────────────────────────────────────────────────────────
    /// Create a new empty calendar and switch into it. Returns its id. A blank name falls back to "Untitled".
    @discardableResult
    func createCalendar(named name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = registry.create(name: t.isEmpty ? "Untitled" : t)
        switchCalendar(to: meta.id) // starts item sync for the new zone + registrySync if needed
        registrySync?.upsertCalendar(meta.id) // publish the new calendar to the synced registry
        return meta.id
    }

    /// ── Remove ──────────────────────────────────────────────────────────────────────────────────
    /// Delete the current calendar (and all its data) and switch to the most-recent other one. No-op when
    /// it's the only calendar. The current calendar isn't persisted first — it's being thrown away.
    func removeCurrentCalendar() {
        guard canRemoveCalendar else { return } // never the last calendar, never Main
        let list = registry.all
        let doomed = registry.activeId
        let fallback = recentCalendars.first?.id ?? list.first(where: { $0.id != doomed })!.id
        switchCalendar(to: fallback, persistCurrent: false) // stops the doomed calendar's item sync
        CloudSync.deleteZone(calendarId: doomed) // purge its CloudKit zone (all its records)
        registrySync?.removeCalendar(doomed) // drop it from the synced calendar registry
        registry.remove(doomed) // registry entry + local directory
        calCountCache.removeValue(forKey: doomed)
        wake()
    }

    /// ── Rename ──────────────────────────────────────────────────────────────────────────────────
    /// Rename the active calendar. Empty names are rejected.
    func renameCurrentCalendar(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        registry.rename(registry.activeId, to: t)
        registrySync?.upsertCalendar(registry.activeId) // propagate the new name to other devices
        wake()
    }

    /// ── Inbound registry changes (from RegistrySync on another device) ────────────────────────────
    /// Merge a remote calendar-list change: add/rename entries, and remove deleted ones. If the OPEN
    /// calendar was deleted elsewhere, switch to a fallback first (never persist the doomed calendar).
    func applyRemoteCalendars(upserts: [CalendarMeta], deletes: [String]) {
        // VIRGIN-DEVICE ADOPTION (evaluated BEFORE the upserts land): a fresh install boots on
        // the bootstrap default ("Main" — empty, and typically absent from the cloud registry)
        // and nothing ever activated a real calendar, so the device rendered an empty calendar
        // forever while the data sat in cal-… zones (the 2026-08 phone bring-up). If this
        // device knows ONLY the untouched default, adopt the primary cloud calendar when the
        // registry fetch delivers one.
        let virgin = registry.activeId == CalendarRegistry.mainId
            && registry.all.map(\.id) == [CalendarRegistry.mainId]
            && liveItemCount == 0
        for m in upserts {
            registry.upsertRemote(m)
        }
        for id in deletes where registry.meta(id) != nil {
            if id == registry.activeId {
                let fallback = allCalendars.first { $0.id != id }?.id ?? registry.create(name: "Main").id
                switchCalendar(to: fallback, persistCurrent: false)
            }
            registry.remove(id)
        }
        if virgin,
           let adopt = upserts.filter({ $0.id != CalendarRegistry.mainId })
           .min(by: { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }) {
            cloudLog
                .notice(
                    "Adopting cloud calendar \(adopt.id, privacy: .public) (\(adopt.name, privacy: .public)) — fresh device was on the pristine default"
                )
            switchCalendar(to: adopt.id, persistCurrent: false)
            // The untouched bootstrap default would linger as a dead entry in the switcher.
            // Read-only devices never push, so dropping it locally is free; writable devices
            // keep it (their first-run push may already have offered it to the registry).
            if cloudReadOnly {
                registry.remove(CalendarRegistry.mainId)
            }
        }
        wake()
    }

    /// ── Cloud teardown (switch/remove) ────────────────────────────────────────────────────────────
    /// Stop syncing the current calendar and detach the cloud layer. In the unsigned dev shell `cloud`
    /// is always nil, so this is a no-op there.
    internal func stopCloudSync() {
        cloud?.stop()
        cloud = nil
        onLocalChange = nil
        syncedState = nil
    }
}
