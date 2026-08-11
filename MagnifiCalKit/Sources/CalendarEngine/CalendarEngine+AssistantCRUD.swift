// Programmatic CRUD for the AI assistant — parameterized create/update/reshape the
// cursor-driven UI methods (createEventAtBlock etc.) don't offer. Each wraps beginTxn/commitTxn
// so it's one undo step, invalidates the display cache, and persists. `byAI` stamps
// RichFields.createdByAI for provenance. Split from CalendarEngine.swift (the god-file diet).

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    // ── Programmatic CRUD for the AI assistant ─────────────────────────────────────────
    // Parameterized create/update the cursor-driven UI methods (createEventAtBlock etc.) don't
    // offer. Each wraps beginTxn/commitTxn so it's one undo step, invalidates the display cache
    // (beginTxn bumps caches.editGen), and persists (commitTxn → schedulePersist). `byAI` stamps
    // RichFields.createdByAI for provenance. The assistant's create/update tools call these.

    /// The kind an item id resolves to, for the tools' routing + the auditor's context.
    public enum ItemKind: String, Sendable { case timed, band, deadline }
    public func kind(of id: String) -> ItemKind? {
        if items.events.contains(where: { $0.id == id }) {
            return .timed
        }
        if items.bands.contains(where: { $0.id == id }) {
            return .band
        }
        if items.deadlines.contains(where: { $0.id == id }) {
            return .deadline
        }
        return nil
    }

    /// `kind(of:)` extended to the read-only imported bucket — for UI (context menu) that offers
    /// kind-gated overlay actions (Promote, Paste Here) on imported boxes too. Kept separate so the
    /// assistant CRUD paths (which use `kind(of:)` as an "editable item exists" gate) don't start
    /// treating vendor-owned items as writable.
    public func kindIncludingImported(_ id: String) -> ItemKind? {
        if let k = kind(of: id) {
            return k
        }
        let sid = sourceId(of: id)
        if imported.events.contains(where: { $0.id == sid }) {
            return .timed
        }
        if imported.bands.contains(where: { $0.id == sid }) {
            return .band
        }
        return nil
    }

    private func setRich(_ id: String, notes: String?, tags: [String], byAI: Bool,
                         promoteTrack: Int? = nil) {
        guard notes != nil || !tags.isEmpty || byAI || promoteTrack != nil else { return }
        var rf = items.richById[id] ?? RichFields()
        if let notes {
            rf.notes = notes
        }
        if !tags.isEmpty {
            // Tags are markdown: write them INTO the note as #tokens (rich.tags is a cache
            // recomputed below — an assistant-set tag must survive the next note save).
            rf.notes = Self.appendingMissingTags(tags, to: rf.notes)
        }
        if let promoteTrack {
            rf.promoteTrack = max(0, min(3, promoteTrack))
        }
        if byAI {
            rf.createdByAI = true
        }
        items.richById[id] = rf
        syncTagCache(id)
    }

    @discardableResult
    public func createTimedEvent(year: Int, month: Int, day: Int, startHour: CGFloat, endHour: CGFloat,
                                 title: String, color: String, notes: String? = nil,
                                 tags: [String] = [], promoteTrack: Int? = nil,
                                 anchorTz: String? = nil, byAI: Bool = false) -> String {
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        // An explicit anchor zone (e.g. a JST broadcast) stores the coords as THAT zone's wall
        // clock verbatim — the original time is preserved and display converts, never the caller.
        items.events.append(TimedEvent(id: id, year: year, month: month, day: day,
                                       startHour: startHour, endHour: endHour, title: title, color: color,
                                       anchorTz: anchorTz.map(DeadlineTZ.concrete) ?? anchorNow))
        setRich(id, notes: notes, tags: tags, byAI: byAI, promoteTrack: promoteTrack)
        selectedId = id
        commitTxn()
        return id
    }

    @discardableResult
    public func createBand(year: Int, month: Int, track: Int, startDay: Int, endDay: Int,
                           title: String, color: String, notes: String? = nil,
                           tags: [String] = [], byAI: Bool = false) -> String {
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        items.bands.append(BandEvent(id: id, year: year, month: month, track: max(0, min(3, track)),
                                     startDay: startDay, endDay: max(startDay, endDay),
                                     title: title, color: color))
        setRich(id, notes: notes, tags: tags, byAI: byAI)
        selectedId = id
        commitTxn()
        return id
    }

    @discardableResult
    public func createDeadline(year: Int, month: Int, day: Int, hour: CGFloat, title: String,
                               color: String, originTz: String? = nil, notes: String? = nil,
                               tags: [String] = [], promoteTrack: Int? = nil,
                               anchorTz: String? = nil, byAI: Bool = false) -> String {
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        // Anchor precedence: an explicit `anchorTz` means the coords ARE that zone's wall clock —
        // store verbatim (no conversion; the original time survives). A legacy `originTz` means the
        // caller passed MAIN-zone coords: re-express them as the origin wall-clock and anchor there.
        var (dy, dm, dd, dh) = (year, month, day, hour)
        let anchor: String
        if let atz = anchorTz {
            anchor = DeadlineTZ.concrete(atz)
        } else if let otz = originTz,
                  !DeadlineTZ.sameOffset(otz, mainTz, at: DeadlineTZ.instant(year, month, day, hour)) {
            let w = DeadlineTZ.convertWall(year, month, day, hour, from: mainTz, to: otz)
            (dy, dm, dd, dh) = (w.year, w.month, w.day, w.hour); anchor = DeadlineTZ.concrete(otz)
        } else {
            anchor = anchorNow
        }
        items.deadlines.append(Deadline(id: id, year: dy, month: dm, day: dd, hour: dh,
                                        title: title, color: color, anchorTz: anchor))
        setRich(id, notes: notes, tags: tags, byAI: byAI, promoteTrack: promoteTrack)
        selectedId = id
        commitTxn()
        return id
    }

    /// The one cross-month band segmentation walk (bands are stored per-month, so a range is split
    /// into one BandEvent per month, clamped to each month's days). Shared by createBandSpan and
    /// reshapeBand — must run inside an open txn. `seed` stamps per-segment extras (rich fields).
    private func appendBandSegments(from start: (Int, Int, Int), to end: (Int, Int, Int),
                                    track: Int, title: String, color: String,
                                    seed: (String) -> Void) -> [String] {
        // Order the endpoints so start ≤ end regardless of how they were passed.
        var (sy, sm, sd) = start
        var (ey, em, ed) = end
        if (ey, em, ed) < (sy, sm, sd) {
            swap(&sy, &ey); swap(&sm, &em); swap(&sd, &ed)
        }

        var ids: [String] = []
        var (y, m) = (sy, sm)
        while (y, m) <= (ey, em) {
            let segStart = (y == sy && m == sm) ? max(1, sd) : 1
            let segEnd = (y == ey && m == em) ? min(daysInMonth(y, m), ed) : daysInMonth(y, m)
            let id = "new-\(UUID().uuidString)"
            items.bands.append(BandEvent(id: id, year: y, month: m, track: max(0, min(3, track)),
                                         startDay: segStart, endDay: max(segStart, segEnd),
                                         title: title, color: color))
            seed(id)
            ids.append(id)
            m += 1; if m > 11 {
                m = 0; y += 1
            }
        }
        if let last = ids.last {
            selectedId = last
        }
        return ids
    }

    /// Create an all-day band that may span multiple months (one segment per month, shared
    /// title/color/lane). Returns the segment ids in chronological order; a single-month range
    /// yields one id (same as `createBand`).
    @discardableResult
    public func createBandSpan(startYear: Int, startMonth: Int, startDay: Int,
                               endYear: Int, endMonth: Int, endDay: Int, track: Int,
                               title: String, color: String, notes: String? = nil,
                               tags: [String] = [], byAI: Bool = false) -> [String] {
        beginTxn()
        let ids = appendBandSegments(from: (startYear, startMonth, startDay),
                                     to: (endYear, endMonth, endDay),
                                     track: track, title: title, color: color) { id in
            setRich(id, notes: notes, tags: tags, byAI: byAI)
        }
        commitTxn()
        return ids
    }

    /// Re-span an existing band to a new (possibly cross-month) range in ONE undo step, preserving
    /// its title/color/track and rich fields (notes/tags/…). The old id is retired; returns the new
    /// segment ids in chronological order. Empty if `id` isn't a band.
    @discardableResult
    public func reshapeBand(id: String, startYear: Int, startMonth: Int, startDay: Int,
                            endYear: Int, endMonth: Int, endDay: Int) -> [String] {
        guard let b = items.bands.first(where: { $0.id == id }) else { return [] }
        let rich = items.richById[id]
        beginTxn()
        items.bands.removeAll { $0.id == id }
        items.richById[id] = nil
        if selectedId == id {
            selectedId = nil
        }
        let ids = appendBandSegments(from: (startYear, startMonth, startDay),
                                     to: (endYear, endMonth, endDay),
                                     track: b.track, title: b.title, color: b.color) { nid in
            if let rich {
                items.richById[nid] = rich
            }
        }
        commitTxn()
        return ids
    }

    /// Patch an existing item — only the non-nil fields change. Returns false if `id` is unknown.
    /// `byAI` stamps provenance on edited items too (matches the web's `"ai"` actor).
    @discardableResult
    public func updateItem(id: String, title: String? = nil, color: String? = nil,
                           year: Int? = nil, month: Int? = nil, day: Int? = nil,
                           startHour: CGFloat? = nil, endHour: CGFloat? = nil,
                           track: Int? = nil, startDay: Int? = nil, endDay: Int? = nil,
                           hour: CGFloat? = nil, notes: String? = nil, tags: [String]? = nil,
                           promoteTrack: Int? = nil, clearPromote: Bool = false,
                           byAI: Bool = false) -> Bool {
        beginTxn()
        var found = true
        if let i = items.events.firstIndex(where: { $0.id == id }) {
            if let title {
                items.events[i].title = title
            }
            if let color {
                items.events[i].color = color
            }
            if let year {
                items.events[i].year = year
            }
            if let month {
                items.events[i].month = month
            }
            if let day {
                items.events[i].day = day
            }
            if let startHour {
                items.events[i].startHour = startHour
            }
            if let endHour {
                items.events[i].endHour = endHour
            }
        } else if let i = items.bands.firstIndex(where: { $0.id == id }) {
            if let title {
                items.bands[i].title = title
            }
            if let color {
                items.bands[i].color = color
            }
            if let year {
                items.bands[i].year = year
            }
            if let month {
                items.bands[i].month = month
            }
            if let track {
                items.bands[i].track = max(0, min(3, track))
            }
            if let startDay {
                items.bands[i].startDay = startDay
            }
            if let endDay {
                items.bands[i].endDay = max(items.bands[i].startDay, endDay)
            }
        } else if let i = items.deadlines.firstIndex(where: { $0.id == id }) {
            if let title {
                items.deadlines[i].title = title
            }
            if let color {
                items.deadlines[i].color = color
            }
            if let year {
                items.deadlines[i].year = year
            }
            if let month {
                items.deadlines[i].month = month
            }
            if let day {
                items.deadlines[i].day = day
            }
            if let hour {
                items.deadlines[i].hour = hour
            }
        } else {
            found = false
        }
        if found {
            if notes != nil || tags != nil || byAI || promoteTrack != nil || clearPromote {
                var rf = items.richById[id] ?? RichFields()
                if let notes {
                    rf.notes = notes
                }
                if let tags {
                    // Tags are markdown (see setRich): ADD the requested tags as #tokens in the
                    // note; removing one means editing the note text, which stays the user's move.
                    rf.notes = Self.appendingMissingTags(tags, to: rf.notes)
                }
                if clearPromote {
                    rf.promoteTrack = nil
                } else if let promoteTrack {
                    rf.promoteTrack = max(0, min(3, promoteTrack))
                }
                if byAI {
                    rf.createdByAI = true
                }
                items.richById[id] = rf
                syncTagCache(id)
            }
        }
        commitTxn()
        return found
    }

    /// Append `#token`s for any of `tags` the note doesn't already carry (case-insensitive; UI-era
    /// characters sanitized by tagToken). Shared by the assistant's create/update paths — the
    /// markdown is the tag source of truth, so a tag that isn't in the note doesn't exist.
    static func appendingMissingTags(_ tags: [String], to notes: String?) -> String? {
        let present = Set(TodoIndex.noteTags(notes).map { $0.lowercased() })
        let missing = tags.compactMap { TodoIndex.tagToken($0) }
            .filter { !present.contains($0.lowercased()) }
        guard !missing.isEmpty else { return notes }
        let line = missing.map { "#" + $0 }.joined(separator: " ")
        return (notes?.isEmpty == false) ? notes! + "\n\n" + line : line
    }

    /// The (year, month0, day) an item sits on — for the auditor's trusted date context.
    /// Bands report their start day.
    public func dateOf(_ id: String) -> (Int, Int, Int)? {
        if let e = items.events.first(where: { $0.id == id }) {
            return (e.year, e.month, e.day)
        }
        if let b = items.bands.first(where: { $0.id == id }) {
            return (b.year, b.month, b.startDay)
        }
        if let d = items.deadlines.first(where: { $0.id == id }) {
            return (d.year, d.month, d.day)
        }
        return nil
    }

    /// One-line summaries of every item on a date — the auditor's trusted "what's already here".
    public func itemsOn(year: Int, month: Int, day: Int) -> [String] {
        var out: [String] = []
        for e in displayEvents(for: year) where e.month == month && e.day == day {
            out.append("timed: \(e.title) \(String(format: "%.0f", e.startHour))–\(String(format: "%.0f", e.endHour))h")
        }
        for b in displayBands(for: year) where b.month == month && day >= b.startDay && day <= b.endDay {
            out.append("band: \(b.title) (lane \(b.track + 1))") // 1-based for the AI/auditor
        }
        for d in displayDeadlines(for: year) where d.month == month && d.day == day {
            out.append("deadline: \(d.title)")
        }
        return out
    }
}
