// Apple Calendar import (EventKit): enabled-state + per-calendar selection, the read-only
// imported item merge (kept OUT of the seed arrays so imports never persist/sync or get edited),
// managed-note rendering, hidden-import handling, local-copy promotion, and nearest-color
// matching. Split from CalendarEngine.swift (the god-file diet).

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    // ── Apple Calendar import (EventKit) ──────────────────────────────────────────────
    // Enabled-state + selected calendars live in UserDefaults so the (separate) Settings window and the
    // running engine share them without a direct reference; Settings posts `.appleCalendarSettingsChanged`
    // to nudge an immediate re-import. Imported events are read-only + kept out of persistence/iCloud.

    /// Keyed per ACTIVE calendar: each MagnifiCal calendar subscribes to its own external calendars.
    public var appleSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: PrefKeys.appleEnabled(registry.activeId)) }
        set { UserDefaults.standard.set(newValue, forKey: PrefKeys.appleEnabled(registry.activeId)) }
    }

    public var appleCalendarIds: [String] {
        get { (UserDefaults.standard.array(forKey: PrefKeys.appleCalendars(registry.activeId)) as? [String]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: PrefKeys.appleCalendars(registry.activeId)) }
    }

    /// Access probe + the calendar list + the TCC prompt — for the Settings picker. Access status is
    /// static so the isolated Settings window can read it without the engine.
    public static var appleAccess: AppleCalendarImporter.Access {
        AppleCalendarImporter.access
    }

    public func appleCalendars() -> [AppleCalendarInfo] {
        appleImporter.calendars()
    }

    /// Re-fetch the enabled Apple calendars for the visible year ±1 and merge them in as read-only
    /// events (full-window re-fetch; Apple has no incremental cursor). Disabled/unauthorized → clears
    /// any previously-imported set. Cheap to call on launch, foreground, and settings change.
    public func importAppleCalendar() {
        if Self.isDemoMode {
            return
        } // recording session → never touch the user's Apple Calendar
        // Proceed unless disabled or access is explicitly DENIED. We don't require `.authorized` here:
        // the status lags for a beat after a fresh grant, but `fetch()` asks the store directly and
        // returns real events during that window (empty if truly no access), so the first import right
        // after connecting isn't lost.
        guard appleSyncEnabled, AppleCalendarImporter.access != .denied else {
            if !imported.events.isEmpty || !imported.bands.isEmpty {
                imported.events.removeAll { !$0.id.hasPrefix("gcal-") }
                imported.bands.removeAll { !$0.id.hasPrefix("gcal-") }
                caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
            }
            return
        }
        let cal = Calendar.current
        let from = cal.date(from: DateComponents(year: year - 1, month: 1, day: 1)) ?? Date()
        let to = cal.date(from: DateComponents(year: year + 3, month: 1, day: 1)) ?? Date()
        mergeAppleEvents(appleImporter.fetch(from: from, to: to, calendarIds: appleCalendarIds))
    }

    /// Case/punctuation/whitespace-insensitive title key (ported from the web's `normTitle`).
    static func normTitle(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Exact dedup key for a timed event: normalized title + calendar day + exact start minute.
    private func timedKey(_ title: String, _ y: Int, _ m: Int, _ d: Int, _ startHour: CGFloat) -> String {
        "\(Self.normTitle(title))|\(y)-\(m)-\(d)@\(Int((startHour * 60).rounded()))"
    }

    /// Store an imported event's `hidden` flag (a deduped shadow of the user's own event). Returns
    /// whether it changed, so the caller can persist. Only mints a rich-fields entry when actually hiding.
    private func setImportedHidden(_ id: String, _ hidden: Bool) -> Bool {
        if hidden {
            var rf = items.richById[id] ?? RichFields()
            if rf.hidden {
                return false
            }
            rf.hidden = true; items.richById[id] = rf; return true
        } else if var rf = items.richById[id], rf.hidden {
            rf.hidden = false; items.richById[id] = rf; return true
        }
        return false
    }

    /// Set an imported event's note to `fresh` managed block composed with any existing user postfix
    /// (a blank `fresh` drops the managed block, keeping the user's text). Returns whether it changed.
    private func setImportedNote(_ id: String, _ fresh: String) -> Bool {
        let composed = ManagedNote.replaceManaged(items.richById[id]?.notes, fresh)
        let newVal: String? = composed.isEmpty ? nil : composed
        if (items.richById[id]?.notes ?? "") == (newVal ?? "") {
            return false
        }
        var rf = items.richById[id] ?? RichFields()
        rf.notes = newVal
        items.richById[id] = rf
        return true
    }

    func mergeAppleEvents(_ fetched: [FetchedAppleEvent]) { // internal for tests (re-import survival)
        let cal = Calendar.current
        // Dedup: the user's OWN timed events (exact key), so an imported event that shadows one can be
        // hidden. displayEvents includes recurrence occurrences; exclude imported ids so we compare only
        // against the user's real calendar, not a prior Apple import.
        var ownTimed = Set<String>()
        for y in (year - 1) ... (year + 2) {
            for e in displayEvents(for: y) where !isImported(e.id) {
                ownTimed.insert(timedKey(
                    e.title,
                    e.year,
                    e.month,
                    e.day,
                    e.startHour
                ))
            }
        }
        var events: [TimedEvent] = []
        var seen = Set<String>() // self-dedup: a copied event can share a UID → collides on our id
        var richChanged = false
        var seriesNote: [String: String] = [:] // series key → freshly-rendered managed block (computed once)
        var seriesVisible = Set<String>() // series keys with ≥1 non-hidden occurrence this import
        imported.appleEventIds.removeAll(keepingCapacity: true)
        for e in fetched.sorted(by: { $0.start < $1.start }) {
            if e.allDay {
                continue
            } // never import all-day events (product decision)
            let sc = cal.dateComponents([.year, .month, .day, .hour, .minute], from: e.start)
            guard let y = sc.year, let mo1 = sc.month, let d = sc.day else { continue }
            let m = mo1 - 1
            let sh = CGFloat(sc.hour ?? 0) + CGFloat(sc.minute ?? 0) / 60
            let ec = cal.dateComponents([.year, .month, .day, .hour, .minute], from: e.end)
            var eh = CGFloat(ec.hour ?? 0) + CGFloat(ec.minute ?? 0) / 60
            if ec.year != y || ec.month != mo1 || ec
                .day != d || eh <= sh {
                eh = 24
            } // multi-day / past midnight → clamp to day end
            let id = "apple-\(e.uid)-\(String(format: "%04d%02d%02d-%02d%02d", y, mo1, d, sc.hour ?? 0, sc.minute ?? 0))"
            guard seen.insert(id).inserted else { continue }
            if let eid = e.eventId {
                imported.appleEventIds[id] = eid
            }
            // Exact-match dedup: an imported event that shadows one of the user's OWN events (same title +
            // same day + same start) is still imported, but flagged HIDDEN on its entry — we prefer the
            // editable event and don't draw the shadow. The flag is stored/persisted, so re-imports keep it.
            let hidden = ownTimed.contains(timedKey(e.title, y, m, d, sh))
            if setImportedHidden(id, hidden) {
                richChanged = true
            } // per-occurrence flag (local-only)
            // Vendor "managed note" is SERIES-level (provenance, meeting link, location, organizer,
            // attendees, description don't vary per occurrence). Compute it once per series and remember
            // whether any occurrence is visible; a fully-shadowed series drops its managed block below.
            let sk = Self.appleSeriesKey(id)
            if !hidden {
                seriesVisible.insert(sk)
            }
            if seriesNote[sk] == nil, ManagedNote.hasDetail(
                url: e.url,
                location: e.location,
                organizer: e.organizer,
                attendees: e.attendees.count,
                description: e.notes
            ) {
                seriesNote[sk] = ManagedNote.render(
                    provenance: "Apple · \(e.sourceTitle) · \(e.calendarTitle)",
                    meetingUrl: e.url,
                    location: e.location,
                    organizer: e.organizer,
                    attendees: e.attendees.map { ($0.name, $0.status) },
                    description: e.notes
                )
            }
            events.append(TimedEvent(
                id: id,
                year: y,
                month: m,
                day: d,
                startHour: sh,
                endHour: max(sh + 0.25, eh),
                title: e.title,
                color: Self.nearestEventColor(e.colorHex),
                anchorTz: DeadlineTZ.concrete("auto")
            ))
        }
        // Refresh each series' managed note at its series key, preserving the user's postfix; a series with
        // no visible occurrence drops the managed block (keeps any user text). Only series that already have
        // an overlay entry, or that carry detail this import, are touched.
        for sk in Set(seriesNote.keys).union(items.richById.keys.filter { Self.isAppleSeriesKey($0) }) {
            let block = seriesVisible.contains(sk) ? (seriesNote[sk] ?? "") : ""
            if setImportedNote(sk, block) {
                richChanged = true
            }
        }
        // Prune imported overlays no longer backed upstream: per-occurrence `hidden` flags whose occurrence
        // is gone; series overlays only when NO live occurrence remains AND they carry no user-authored data.
        // USER-authored per-occurrence entries (the make-local-copy exclusion) are NEVER pruned here:
        // this device's fetch window/calendar selection may simply not see that occurrence, and the
        // prune would sync as a DELETE that resurrects the event on every other device.
        let live = Set(events.map(\.id))
        let liveSeries = Set(events.map { Self.appleSeriesKey($0.id) })
        for id in items.richById.keys where id.hasPrefix("apple-") {
            if Self.isAppleSeriesKey(id) {
                if !liveSeries.contains(id), let rf = items.richById[id],
                   !hasUserOverlay(rf) {
                    items.richById[id] = nil; richChanged = true
                }
            } else if !live.contains(id), let rf = items.richById[id], !hasUserOverlay(rf) {
                items.richById[id] = nil; richChanged = true
            }
        }
        // Replace only the APPLE contribution — ICS feed items ("gcal-…") share this bucket.
        imported.events = imported.events.filter { $0.id.hasPrefix("gcal-") } + events
        imported.bands = imported.bands.filter { $0.id.hasPrefix("gcal-") }
        if richChanged {
            schedulePersist()
        } // the hidden flags are stored state (see setImportedHidden)
        caches.editGen &+= 1; caches.deadlineGen &+= 1
        if let s = selectedId, !itemExists(sourceId(of: s)) {
            selectedId = nil
        } // selection's event gone
        onExternalDataChange?() // an open drawer on a now-removed imported event should close
        wake()
    }

    /// Deep-link that reveals an imported event back in Calendar.app ("Edit original"). The `ical://ekevent/`
    /// scheme opens Calendar.app and selects the event by its EKEvent identifier. Nil if we don't hold the
    /// identifier (older import) — the UI hides the button then. The UI layer opens it (this module has no AppKit).
    public func appleOriginalURL(_ id: String) -> URL? {
        guard let eid = imported.appleEventIds[sourceId(of: id)] else { return nil }
        return URL(string: "ical://ekevent/\(eid)?method=show&options=more")
    }

    /// "Make local copy": clone an imported (read-only) event into our own editable calendar, carrying its
    /// title / time / color / notes / tags, and hide the imported original so the two don't both show. The
    /// dedup pass on the next import would hide it anyway (same title+day+start now lives in our own set) — we
    /// just do it immediately. Returns the new editable event's id so the drawer can re-point at it.
    @discardableResult
    public func makeLocalCopy(_ id: String) -> String? {
        guard isImported(id), let e = imported.events.first(where: { $0.id == id }) else { return nil }
        beginTxn()
        let newId = "new-\(UUID().uuidString)"
        items.events.append(TimedEvent(id: newId, year: e.year, month: e.month, day: e.day,
                                       startHour: e.startHour, endHour: e.endHour, title: e.title,
                                       color: importedDisplayColor(e),
                                       anchorTz: DeadlineTZ
                                           .concrete("auto"))) // imported events are device-local wall-clock
        // Carry the user overlays — notes (managed block + any typed text), tags, promote lane — into a
        // fresh, manual rich-fields entry. They live at the imported SERIES key; the copy is a normal local
        // event from here on (source defaults to "manual"; the vendor color is baked into the event above).
        if let src = items.richById[overlayKey(id)] {
            items.richById[newId] = RichFields(notes: src.notes, tags: src.tags, promoteTrack: src.promoteTrack)
        }
        // The copied occurrence gets a STICKY per-occurrence exclusion — userHidden on the FULL
        // occurrence id, i.e. an exdate in our system. The dedup `hidden` flag is NOT enough: it is
        // recomputed on every import, so as soon as the copy is deleted (the documented way to
        // "delete an occurrence" of an imported series!) or edited off its exact title+day+start,
        // the next re-import would UN-hide the original — deleted events resurrected on relaunch.
        // The sticky flag survives re-imports; only an explicit Unhide clears it.
        var rf = items.richById[id] ?? RichFields()
        rf.userHidden = true
        items.richById[id] = rf
        selectedId = newId
        commitTxn()
        return newId
    }

    /// Nearest named palette color to a `#RRGGBB` hex — imported events adopt their calendar's color.
    static func nearestEventColor(_ hex: String) -> String {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = Int(s, radix: 16) else { return "blue" }
        let r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF
        let palette: [(String, Int, Int, Int)] = [
            ("blue", 74, 142, 232), ("indigo", 92, 92, 214), ("cyan", 80, 200, 220),
            ("green", 76, 200, 120), ("darkgreen", 40, 120, 70), ("yellow", 230, 200, 70),
            ("orange", 240, 150, 70), ("red", 240, 96, 96), ("purple", 170, 100, 220),
        ]
        var best = "blue"; var bestD = Int.max
        for (name, pr, pg, pb) in palette {
            let dist = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb)
            if dist < bestD {
                bestD = dist; best = name
            }
        }
        return best
    }
}
