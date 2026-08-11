// Display derivation: what the renderer actually draws, expanded from the lean seed data +
// rich fields — recurrence-expanded bands/timed events/deadlines with badges (cached per
// (year, caches.editGen)), Apple-import overlay keying, live color preview, cross-year spillover
// sets, and the offline deadline-label side assignment. Split from CalendarEngine.swift.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// The display-invalidation generation (bumped on every data edit) — lets the UI key its own
    /// derived caches (e.g. the events overlay's per-month packing) without observing internals.
    public var displayGen: UInt64 {
        UInt64(caches.editGen)
    }

    /// ── Derived bands for the year / band view ──────────────────────────────────────────
    /// What the band lane actually draws, expanded from the lean data + rich fields:
    ///   • base bands (a base individually deleted via exdate / past `until` is dropped)
    ///   • recurring band ghosts — the same span shifted to each occurrence date (holes = exdates)
    ///   • timed/deadline events promoted (rich.promoteTrack) to 1-day ghost bands on their lane,
    ///     on the base day AND every recurrence occurrence
    /// Read-only copies get a synthetic occKey id; the base band / promoted base keep their real id
    /// (so a click still resolves to the source item). Cached per (year, caches.editGen) — recurrence is
    /// only re-expanded when the data changes, not on navigation frames.
    /// ── Color preview (hovering a drawer swatch previews the color live on the item) ───────────
    public func setColorPreview(_ id: String, _ color: String) {
        wake(); colorPreview = (id, color)
    }

    /// Clear the preview. If `color` is given, only clears when it's still the active preview — so a
    /// swatch's mouse-leave doesn't wipe a preview a newer swatch just set.
    public func clearColorPreview(_ color: String? = nil) {
        if let color, colorPreview?.color != color {
            return
        }
        wake()
        colorPreview = nil
    }

    /// Overlay the preview color on any box of the previewed series (applied after the cache, so it
    /// never persists or invalidates recurrence expansion).
    private func withPreview<T>(_ items: [T], _ id: (T) -> String, _ setColor: (inout T, String) -> Void) -> [T] {
        guard let pv = colorPreview else { return items }
        return items.map {
            var x = $0; if sourceId(of: id(x)) == pv.id {
                setColor(&x, pv.color)
            }; return x
        }
    }

    public func displayBands(for year: Int) -> [BandEvent] {
        withPreview(ensureBandCache(year).bands, { $0.id }, { $0.color = $1 })
    }

    /// Provenance/kind markers per band box id (recurrent / promoted / ai / imported), for the badge
    /// glyphs the overlay draws. Same cache as displayBands.
    public func bandBadges(for year: Int) -> [String: EventBadges] {
        ensureBandCache(year).badges
    }

    /// Bands (base + recurrence/promoted ghosts) in a specific month — O(1) index lookup, with the live
    /// color preview applied like `displayBands`. Used by the band hit-test to skip other months.
    public func bandsInMonth(_ year: Int, _ month: Int) -> [BandEvent] {
        let items = ensureBandCache(year).byMonth[month] ?? []
        return withPreview(items, { $0.id }, { $0.color = $1 })
    }

    /// Provenance/kind markers for a box, from its SOURCE item's rich fields + the box's nature.
    /// Shared by the band and timed-event caches so both show the same glyphs.
    private func itemBadges(_ src: String, recurrent: Bool, promoted: Bool) -> EventBadges {
        var b: EventBadges = []
        if recurrent {
            b.insert(.recurrent)
        }
        if promoted {
            b.insert(.promoted)
        }
        if isImported(src) {
            b.insert(.imported)
        }
        if let rf = items.richById[src] {
            if rf.createdByAI {
                b.insert(.ai)
            }
            if rf.source != "manual" {
                b.insert(.imported)
            }
        }
        return b
    }

    /// True for a box that came from an external calendar (Apple, …). Imported ids are minted with an
    /// `apple-` prefix; `sourceId` strips occurrence/promoted suffixes so promoted imported bars match too.
    public func isImported(_ id: String) -> Bool {
        Self.hasImportedPrefix(sourceId(of: id))
    }

    /// A non-"manual" rich source ("ical", "apple") on an EDITABLE item — e.g. a one-shot .ics file
    /// import, which is a fully-editable local copy that still wears the imported badge. The drawer
    /// explains those with an informational banner (no vendor buttons). nil for manual items.
    public func editableImportSource(_ id: String) -> String? {
        guard !isImported(id) else { return nil }
        let src = items.richById[overlayKey(id)]?.source
        return src == nil || src == "manual" ? nil : src
    }

    /// Read-only imported id namespaces: "apple-" (EventKit) and "gcal-" (ICS feed subscriptions).
    static func hasImportedPrefix(_ id: String) -> Bool {
        id.hasPrefix("apple-") || id.hasPrefix("gcal-")
    }

    /// ── Overlay keying for imported events ─────────────────────────────────────────────────────
    /// An imported event's own id is per-occurrence + time-derived: `apple-<uid>-<YYYYMMDD-HHMM>`. The
    /// `hidden` dedup flag keys on that full id (it shadows one specific occurrence). But USER-authored
    /// overlays — a chosen color, promote-to-band, extra notes/tags — key on the SERIES (`apple-<uid>`,
    /// datestamp stripped) so they survive the event being rescheduled in Apple Calendar and apply to the
    /// whole series. `sourceId` first, so a promoted/occurrence box resolves back to its imported id.
    static func applePerOccurrenceSuffix(_ id: String) -> Range<String.Index>? {
        // Manual scan for `-[0-9]{8}-[0-9]{4}$` — called per imported event on every display-cache
        // rebuild (overlayKey / importedDisplayColor), where an uncached regex search is a hot spot.
        var s = id[...]
        func eatDigits(_ n: Int) -> Bool {
            for _ in 0 ..< n {
                guard let c = s.last, ("0" ... "9").contains(c) else { return false }
                s = s.dropLast()
            }
            return true
        }
        guard eatDigits(4), s.last == "-" else { return nil }
        s = s.dropLast()
        guard eatDigits(8), s.last == "-" else { return nil }
        s = s.dropLast()
        return s.endIndex ..< id.endIndex
    }

    /// A full per-occurrence imported id → its series key; any other id unchanged.
    static func appleSeriesKey(_ id: String) -> String {
        guard hasImportedPrefix(id), let r = applePerOccurrenceSuffix(id) else { return id }
        return String(id[..<r.lowerBound])
    }

    /// True for an imported SERIES key (`apple-<uid>`, no datestamp) — the id user overlays sync under.
    static func isAppleSeriesKey(_ id: String) -> Bool {
        hasImportedPrefix(id) && applePerOccurrenceSuffix(id) == nil
    }

    /// True for an imported PER-OCCURRENCE key (`apple-<uid>-<datestamp>`) — the local-only `hidden` flag.
    static func isApplePerOccurrenceKey(_ id: String) -> Bool {
        id
            .hasPrefix("apple-") && applePerOccurrenceSuffix(id) != nil // apple-only: the dedup hidden flag
    }

    /// The rich-fields storage key for an item's user overlays: an imported box → its series key; else itself.
    func overlayKey(_ id: String) -> String {
        Self.appleSeriesKey(sourceId(of: id))
    } // internal: +AppleImport
    /// True if a rich entry carries USER-authored overlay data (color / promote / tags / a note the user
    /// typed) — as opposed to only an auto-derived managed block. Gates whether a series overlay is kept
    /// after its event disappears upstream, and whether it's worth syncing to iCloud.
    static func hasUserOverlay(_ rf: RichFields) -> Bool {
        rf.colorOverride != nil || rf.promoteTrack != nil || !rf.tags.isEmpty || rf.userHidden
            || !ManagedNote.splitNote(rf.notes).user.isEmpty
    }

    func hasUserOverlay(_ rf: RichFields) -> Bool {
        Self.hasUserOverlay(rf)
    } // internal: +AppleImport
    /// An imported event's effective color: the user's series-level override, else the FEED's
    /// default color (Settings ▸ Account, per subscribed calendar), else the vendor calendar's.
    /// The override IS the "user changed this one" bit — items without it follow the feed default,
    /// so changing the default in Settings propagates exactly to the untouched items.
    func importedDisplayColor(_ e: TimedEvent) -> String { // internal: +AppleImport
        items.richById[Self.appleSeriesKey(e.id)]?.colorOverride
            ?? Self.feedDefaultColor(e.id) ?? e.color
    }

    /// The band twin of importedDisplayColor (imported all-day events).
    func importedBandDisplayColor(_ b: BandEvent) -> String {
        items.richById[Self.appleSeriesKey(b.id)]?.colorOverride
            ?? Self.feedDefaultColor(b.id) ?? b.color
    }

    /// ── View ▸ Filter by Tags (ported from the web's "Tag Filter" flyout) ──────────────────────
    /// Sentinel key for the "Untagged" row — the leading space can't collide with a real (trimmed) tag.
    public static let untaggedKey = " untagged"
    /// The persisted set of HIDDEN tag keys (trimmed+lowercased). Empty = no filtering.
    public static var hiddenTagKeys: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: PrefKeys.hiddenTags) ?? [])
    }

    /// Web-parity "If Any" visibility: with a filter active, an item shows if at least one of its tags is
    /// NOT hidden; an untagged item shows unless the Untagged row is hidden. `id` may be any derived box id
    /// (occurrence / promoted / segment) — richTags resolves it to the source item's tags via overlayKey.
    func tagVisible(_ id: String, _ hidden: Set<String>) -> Bool {
        if hidden.isEmpty {
            return true
        }
        let ts = richTags(id).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if ts.isEmpty {
            return !hidden.contains(Self.untaggedKey)
        }
        return ts.contains { !hidden.contains($0) }
    }

    /// Every tag in use, for the View ▸ Filter by Tags submenu: key (trimmed+lowercased identity), label
    /// (first-seen original casing), and the count of items carrying it (distinct per item — a tag repeated
    /// on one item counts once). Sorted by count desc, then label. `untagged` = items with no tags.
    public func tagUniverse() -> (rows: [(key: String, label: String, count: Int)], untagged: Int) {
        // Served from the cache until the next edit (editGen bump) invalidates it — so opening the filter,
        // typing in its search field, and re-rendering never re-scan every event.
        if let c = caches.tag, c.gen == caches.editGen {
            return (c.rows, c.untagged)
        }
        var counts: [String: (label: String, count: Int)] = [:]
        var untagged = 0
        func tally(_ id: String) {
            let tags = richTags(id)
            var seen = Set<String>()
            for t in tags {
                let key = t.trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                if var e = counts[key] {
                    e.count += 1; counts[key] = e
                } else {
                    counts[key] = (t.trimmingCharacters(in: .whitespaces), 1)
                }
            }
            if seen.isEmpty {
                untagged += 1
            }
        }
        for e in items.events {
            tally(e.id)
        }
        for b in items.bands {
            tally(b.id)
        }
        for d in items.deadlines {
            tally(d.id)
        }
        for e in imported.events where items.richById[e.id]?.hidden != true {
            tally(e.id)
        }
        for b in imported.bands {
            tally(b.id)
        }
        var rows: [(key: String, label: String, count: Int)] = []
        for (key, v) in counts {
            rows.append((key: key, label: v.label, count: v.count))
        }
        rows.sort { a, b in
            if a.count != b.count {
                return a.count > b.count
            }
            return a.label < b.label
        }
        caches.tag = (caches.editGen, rows, untagged)
        return (rows, untagged)
    }

    private func ensureBandCache(_ year: Int)
        -> (bands: [BandEvent], badges: [String: EventBadges], byMonth: [Int: [BandEvent]]) {
        if let c = caches.band[year], c.gen == caches.editGen {
            return (c.bands, c.badges, c.byMonth)
        }
        func repeatOf(_ id: String) -> Repeat? {
            Repeat.parse(items.richById[id]?.repeatJSON)
        }
        /// Markers for a box, from its SOURCE item's rich fields + the box's nature.
        func badges(_ src: String, recurrent: Bool, promoted: Bool) -> EventBadges {
            var b: EventBadges = []
            if recurrent {
                b.insert(.recurrent)
            }
            if promoted {
                b.insert(.promoted)
            }
            if isImported(src) {
                b.insert(.imported)
            }
            if let rf = items.richById[src] {
                if rf.createdByAI {
                    b.insert(.ai)
                }
                if rf.source != "manual" {
                    b.insert(.imported)
                }
            }
            return b
        }
        var out: [BandEvent] = []
        var badgeMap: [String: EventBadges] = [:]
        let hiddenT = Self.hiddenTagKeys // View ▸ Filter by Tags (applies to sources → ghosts follow)

        for b in items.bands where b.year == year {
            if baseHidden(occDate(YMD(b.year, b.month, b.startDay)), repeatOf(b.id)) {
                continue
            }
            guard tagVisible(b.id, hiddenT) else { continue }
            out.append(b)
            badgeMap[b.id] = badges(b.id, recurrent: repeatOf(b.id) != nil, promoted: false)
        }
        for b in items.bands {
            guard let r = repeatOf(b.id), tagVisible(b.id, hiddenT) else { continue }
            let total = b.endDay - b.startDay + 1 // inclusive number of days the band covers
            for o in occurrenceDates(YMD(b.year, b.month, b.startDay), r, year) {
                // A shifted occurrence can run past the end of its start month — render one bar PER month
                // it spans (Jan 30–Feb 2 → a Jan 30–31 bar AND a Feb 1–2 bar) instead of clamping it flat
                // at the boundary. All segments share the occurrence's start-date key; tail segments get a
                // distinct box id via SEGMENT_MARKER (ignored by sourceId, stripped by occurrenceKey).
                let key = occKey(b.id, o)
                var y = year, m = o.month, d = o.day, left = total, seg = 0
                while left > 0, y == year { // stop at the year edge (this cache is year-scoped)
                    let dim = daysInMonth(y, m)
                    let daysHere = min(left, dim - d + 1)
                    let segId = seg == 0 ? key : "\(key)\(SEGMENT_MARKER)\(seg)"
                    out.append(BandEvent(id: segId, year: year, month: m, track: b.track,
                                         startDay: d, endDay: d + daysHere - 1, title: b.title, color: b.color))
                    badgeMap[segId] = badges(b.id, recurrent: true, promoted: false)
                    left -= daysHere
                    if m == 11 {
                        m = 0; y += 1
                    } else {
                        m += 1
                    }
                    d = 1; seg += 1
                }
            }
        }
        // Promoted bars sit on the LOCAL (main-tz) day of their source's MOMENT — an AOE deadline at
        // 23:59 on day A lands on day A+1 in EST, and the ghost band must agree with the timeline box
        // (which converts via displayEvent/displayDeadline the same way). Identity (occKey) and the
        // hide/exdate checks stay on the STORED anchor-tz date, so selection sync and per-occurrence
        // hides keep matching the source item.
        func localYMD(_ ymd: YMD, _ hour: CGFloat, _ anchor: String?) -> YMD {
            guard let anchor,
                  !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(ymd.year, ymd.month, ymd.day, hour))
            else { return ymd }
            let w = DeadlineTZ.convertWall(ymd.year, ymd.month, ymd.day, hour, from: anchor, to: mainTz)
            return YMD(w.year, w.month, w.day)
        }
        func promote(_ id: String, _ y: Int, _ m: Int, _ day: Int, _ title: String, _ color: String,
                     hidden: Bool = false, localize: (YMD) -> YMD = { $0 }) {
            guard let track = items.richById[overlayKey(id)]?.promoteTrack, tagVisible(id, hiddenT) else { return }
            let r = repeatOf(id)
            func badgesP(recurrent: Bool) -> EventBadges {
                var bg = badges(id, recurrent: recurrent, promoted: true)
                if hidden {
                    bg.insert(.hidden) // revealed user-hidden source → dotted, like its timed box
                }
                return bg
            }
            let base = YMD(y, m, day)
            let w = localize(base)
            // Gate on the DISPLAY year: a Dec-31 anchor day can land in this year's January locally
            // (and vice versa) — the bar belongs to the year it's SEEN in.
            if w.year == year && !baseHidden(occDate(base), r) {
                // A distinct occurrence-key id (not the raw source id) so the promoted bar is its own
                // box: selecting the original timeline event highlights it (same source) without also
                // making it the focused box, and vice-versa. sourceId() maps both back to `id`.
                // `~p` so this promoted bar is a DISTINCT box from the timeline occurrence `id@Y-M-D`.
                let key = occKey(id, base) + PROMOTED_SUFFIX
                out.append(BandEvent(
                    id: key,
                    year: year,
                    month: w.month,
                    track: track,
                    startDay: w.day,
                    endDay: w.day,
                    title: title,
                    color: color
                ))
                badgeMap[key] = badgesP(recurrent: r != nil)
            }
            for o in occurrenceDates(base, r, year) {
                let wo = localize(o)
                guard wo.year == year else { continue }
                let key = occKey(id, o) + PROMOTED_SUFFIX
                out.append(BandEvent(id: key, year: year, month: wo.month, track: track,
                                     startDay: wo.day, endDay: wo.day, title: title, color: color))
                badgeMap[key] = badgesP(recurrent: true)
            }
        }
        for e in items.events {
            promote(e.id, e.year, e.month, e.day, e.title, e.color,
                    localize: { localYMD($0, e.startHour, e.anchorTz) })
        }
        for d in items.deadlines {
            promote(d.id, d.year, d.month, d.day, d.title, d.color,
                    localize: { localYMD($0, d.hour, d.anchorTz) })
        }
        // Imported events the user promoted (rich.promoteTrack on the series key) → one ghost band per
        // visible occurrence, in its overridden color. Skip hidden (deduped-shadow) occurrences, and
        // honor the user's series-level hide EXACTLY like the timed box does (hidden unless "Show
        // Hidden Imported Events" reveals it, then dotted) — the promoted bar is the same event.
        let revealHidden = showHiddenImported
        for e in imported.events where e.year == year && items.richById[e.id]?.hidden != true {
            let userHidden = items.richById[Self.appleSeriesKey(e.id)]?.userHidden == true
                || items.richById[e.id]?.userHidden == true // per-occurrence exdate (make-local-copy)
            if userHidden && !revealHidden {
                continue
            }
            promote(e.id, e.year, e.month, e.day, e.title, importedDisplayColor(e), hidden: userHidden,
                    localize: { localYMD($0, e.startHour, e.anchorTz) })
        }
        for b in imported.bands where b.year == year { // Apple Calendar all-day events (read-only)
            guard tagVisible(b.id, hiddenT) else { continue }
            let userHidden = items.richById[Self.appleSeriesKey(b.id)]?.userHidden == true
            if userHidden && !revealHidden {
                continue
            } // user hid this series → hidden unless "Show Hidden" is on
            var bv = b
            bv.color = importedBandDisplayColor(b) // user override / feed default, like timed events
            out.append(bv)
            var bg = badges(b.id, recurrent: false, promoted: false)
            if userHidden {
                bg.insert(.hidden)
            }
            badgeMap[b.id] = bg
        }

        var byMonth: [Int: [BandEvent]] = [:]
        for b in out {
            byMonth[b.month, default: []].append(b)
        }
        caches.band = caches.band.filter { $0.value.gen == caches.editGen }
        caches.band[year] = (caches.editGen, out, badgeMap, byMonth)
        return (out, badgeMap, byMonth)
    }

    /// ── Derived timed events for the day / detail timeline ──────────────────────────────
    /// Base timed events (a base deleted via exdate / past `until` is dropped) + recurring "ghost"
    /// occurrences on their occurrence days (holes = exdates), each a copy with the same hours and a
    /// synthetic occKey id. The timeline only draws the focused day's items, so off-day occurrences
    /// are culled downstream; the ghosts just make a recurring event appear on every occurrence day.
    /// Cached per (year, caches.editGen) — like displayBands.
    /// `byDay` indexes the expanded events (base + ghosts) by `month*100+day` so hit-testing and per-day
    /// layout packing are O(1) lookups instead of a full-array filter on every hover / rect solve.
    public func displayEvents(for year: Int) -> [TimedEvent] {
        withPreview(ensureEventCache(year).events, { $0.id }, { $0.color = $1 })
    }

    public func eventBadges(for year: Int) -> [String: EventBadges] {
        ensureEventCache(year).badges
    }

    /// Timed events (base + recurrence ghosts) on a specific calendar day — O(1) index lookup, with the
    /// live color preview applied like `displayEvents`. Used by hit-testing + per-day layout packing.
    public func eventsOn(_ year: Int, _ month: Int, _ day: Int) -> [TimedEvent] {
        let items = ensureEventCache(year).byDay[month * 100 + day] ?? []
        return withPreview(items, { $0.id }, { $0.color = $1 })
    }

    /// Re-express a stored (anchor-tz) timed event as a DISPLAY copy in the current main tz: the start
    /// date/time is converted (normalized across midnight, so year/month/day may change), and the end
    /// preserves the original duration — so `endHour` may exceed 24 for a span that now crosses midnight
    /// (the renderer splits it; see cross-midnight handling). A nil anchor (demo/sample data) is treated
    /// as already-in-main-tz → identity. The id and anchorTz are preserved (hit-testing + secondary label).
    public func displayEvent(_ e: TimedEvent) -> TimedEvent {
        guard let anchor = e.anchorTz,
              !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(e.year, e.month, e.day, e.startHour))
        else { return e }
        let dur = max(0, e.endHour - e.startHour)
        let w = DeadlineTZ.convertWall(e.year, e.month, e.day, e.startHour, from: anchor, to: mainTz)
        var out = e
        out.year = w.year; out.month = w.month; out.day = w.day
        out.startHour = w.hour; out.endHour = w.hour + dur
        return out
    }

    /// The deadline analog: convert the single moment into the main tz (day/month/year normalized).
    public func displayDeadline(_ d: Deadline) -> Deadline {
        guard let anchor = d.anchorTz,
              !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(d.year, d.month, d.day, d.hour))
        else { return d }
        let w = DeadlineTZ.convertWall(d.year, d.month, d.day, d.hour, from: anchor, to: mainTz)
        var out = d
        out.year = w.year; out.month = w.month; out.day = w.day; out.hour = w.hour
        return out
    }

    /// Inverse of `displayEvent`: fold a DISPLAY (main-tz) event back into its stored anchor zone. Mouse
    /// drags work in the on-screen (main-tz) grid, so a moved/resized event is converted back here before
    /// it's written to `items.events`. Preserves the anchorTz and the (tz-invariant) duration.
    func anchorEvent(_ e: TimedEvent) -> TimedEvent {
        guard let anchor = e.anchorTz,
              !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(e.year, e.month, e.day, e.startHour))
        else { return e }
        let dur = max(0, e.endHour - e.startHour)
        let w = DeadlineTZ.convertWall(e.year, e.month, e.day, e.startHour, from: mainTz, to: anchor)
        var out = e
        out.year = w.year; out.month = w.month; out.day = w.day
        out.startHour = w.hour; out.endHour = w.hour + dur
        return out
    }

    func anchorDeadline(_ d: Deadline) -> Deadline {
        guard let anchor = d.anchorTz,
              !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(d.year, d.month, d.day, d.hour))
        else { return d }
        let w = DeadlineTZ.convertWall(d.year, d.month, d.day, d.hour, from: mainTz, to: anchor)
        var out = d
        out.year = w.year; out.month = w.month; out.day = w.day; out.hour = w.hour
        return out
    }

    private func ensureEventCache(_ year: Int)
        -> (events: [TimedEvent], badges: [String: EventBadges], byDay: [Int: [TimedEvent]]) {
        if let c = caches.event[year], c.gen == caches.editGen {
            return (c.events, c.badges, c.byDay)
        }
        func repeatOf(_ id: String) -> Repeat? {
            Repeat.parse(items.richById[id]?.repeatJSON)
        }
        var out: [TimedEvent] = []
        var badgeMap: [String: EventBadges] = [:]
        // Anchor→main conversion can push an event across the year boundary (±1 day), so we consider
        // seeds anchored in the neighbor years too and keep those whose DISPLAY date lands in `year`.
        // When an anchor equals the main tz (the common case) conversion is the identity, so a neighbor
        // event just converts back to its own year and is dropped here — same result as the old filter.
        let hiddenT = Self.hiddenTagKeys // View ▸ Filter by Tags
        func take(_ e: TimedEvent, _ badge: EventBadges) {
            let d = displayEvent(e)
            guard d.year == year, tagVisible(d.id, hiddenT) else { return }
            out.append(d); badgeMap[d.id] = badge
        }
        for e in items.events where abs(e.year - year) <= 1 {
            if baseHidden(occDate(YMD(e.year, e.month, e.day)), repeatOf(e.id)) {
                continue
            }
            take(e, itemBadges(e.id, recurrent: repeatOf(e.id) != nil, promoted: false))
        }
        for e in items.events {
            guard let r = repeatOf(e.id) else { continue }
            for yy in (year - 1) ... (year + 1) {
                for o in occurrenceDates(YMD(e.year, e.month, e.day), r, yy) {
                    take(TimedEvent(id: occKey(e.id, o), year: yy, month: o.month, day: o.day,
                                    startHour: e.startHour, endHour: e.endHour, title: e.title,
                                    color: e.color, anchorTz: e.anchorTz),
                         itemBadges(e.id, recurrent: true, promoted: false))
                }
            }
        }
        let revealHidden = showHiddenImported
        for e in imported.events where abs(e.year - year) <= 1 { // Apple Calendar (read-only, already expanded)
            if items.richById[e.id]?.hidden == true {
                continue
            } // deduped shadow of the user's own event → not drawn
            let userHidden = items.richById[Self.appleSeriesKey(e.id)]?.userHidden == true
                || items.richById[e.id]?.userHidden == true // per-occurrence exdate (make-local-copy)
            if userHidden && !revealHidden {
                continue
            } // user hid this series/occurrence → hidden unless "Show Hidden" is on
            var ev = e
            ev.color = importedDisplayColor(e) // apply the user's color override, if any
            var b = itemBadges(e.id, recurrent: false, promoted: false)
            if userHidden {
                b.insert(.hidden)
            } // revealed hidden event → dotted accent bar
            take(ev, b)
        }
        // Bucket by day for O(1) hit-testing + per-day layout packing. A cross-midnight span (endHour > 24)
        // is split into per-day CLAMPED segment copies so its tail is hit-testable + packs on the next day,
        // matching how the overlay renders it. `out` itself stays whole (search / scroll want the full span).
        var byDay: [Int: [TimedEvent]] = [:]
        for e in out {
            for s in timedSegments(e) {
                byDay[s.event.month * 100 + s.event.day, default: []].append(s.event)
            }
        }
        caches.event = caches.event.filter { $0.value.gen == caches.editGen }
        caches.event[year] = (caches.editGen, out, badgeMap, byDay)
        return (out, badgeMap, byDay)
    }

    /// ── Derived deadlines for the deadline layer ────────────────────────────────────────
    /// Base deadlines (a base deleted via exdate / past `until` is dropped) + recurring ghost
    /// occurrences on their occurrence days (holes = exdates), each a copy at the same hour with a
    /// synthetic occKey id. Cached per (year, caches.editGen) — like displayEvents / displayBands.
    public func displayDeadlines(for year: Int) -> [Deadline] {
        if let c = caches.ddl[year], c.gen == caches.editGen {
            return withPreview(
                c.deadlines,
                { $0.id },
                { $0.color = $1 }
            )
        }
        func repeatOf(_ id: String) -> Repeat? {
            Repeat.parse(items.richById[id]?.repeatJSON)
        }
        var out: [Deadline] = []
        let hiddenT = Self.hiddenTagKeys // View ▸ Filter by Tags
        /// Same neighbor-year scan + convert-then-filter as ensureEventCache: a moment near midnight can
        /// land in an adjacent display year when the anchor differs from the main tz. Identity otherwise.
        func take(_ d: Deadline) {
            let dd = displayDeadline(d)
            if dd.year == year, tagVisible(dd.id, hiddenT) {
                out.append(dd)
            }
        }
        for d in items.deadlines where abs(d.year - year) <= 1 {
            if baseHidden(occDate(YMD(d.year, d.month, d.day)), repeatOf(d.id)) {
                continue
            }
            take(d)
        }
        for d in items.deadlines {
            guard let r = repeatOf(d.id) else { continue }
            for yy in (year - 1) ... (year + 1) {
                for o in occurrenceDates(YMD(d.year, d.month, d.day), r, yy) {
                    take(Deadline(id: occKey(d.id, o), year: yy, month: o.month, day: o.day,
                                  hour: d.hour, title: d.title, color: d.color, anchorTz: d.anchorTz))
                }
            }
        }
        caches.ddl = caches.ddl.filter { $0.value.gen == caches.editGen }
        caches.ddl[year] = (caches.editGen, out)
        return withPreview(out, { $0.id }, { $0.color = $1 })
    }

    /// ── View-scoped item sets (include cross-year-boundary spillover) ────────────────────
    /// The scene is year-scoped, but a week/day-view window at a month edge can show a neighbor month
    /// that lives in the ADJACENT year (Dec↔Jan). Merge those neighbor-year items ONLY in week/day
    /// view — in year/month view a neighbor-year event would wrongly render in the current year's band
    /// (the non-weekish path positions by month alone). Other focuses' neighbors are the same year.
    private var boundaryYears: [Int] {
        guard z > 1 else { return [] } // spillover columns only appear past pure month level
        if focus == 0 {
            return [year - 1]
        }
        if focus == 11 {
            return [year + 1]
        }
        return []
    }

    /// The common case (mid-year focus) has no boundary years, so hand back the cached array directly —
    /// `cached + []` would copy it every frame. Only concatenate when a Jan/Dec spillover column exists.
    public func viewEvents() -> [TimedEvent] {
        let b = boundaryYears; return b
            .isEmpty ? displayEvents(for: year) : displayEvents(for: year) + b.flatMap { displayEvents(for: $0) }
    }

    public func viewBands() -> [BandEvent] {
        let b = boundaryYears; return b
            .isEmpty ? displayBands(for: year) : displayBands(for: year) + b.flatMap { displayBands(for: $0) }
    }

    public func viewDeadlines() -> [Deadline] {
        let b = boundaryYears; return b
            .isEmpty ? displayDeadlines(for: year) : displayDeadlines(for: year) + b
            .flatMap { displayDeadlines(for: $0) }
    }

    public func viewBandBadges() -> [String: EventBadges] {
        var m = bandBadges(for: year); for y in boundaryYears {
            m.merge(bandBadges(for: y)) { a, _ in a }
        }; return m
    }

    public func viewEventBadges() -> [String: EventBadges] {
        var m = eventBadges(for: year); for y in boundaryYears {
            m.merge(eventBadges(for: y)) { a, _ in a }
        }; return m
    }

    /// ── Offline deadline-label side assignment (left/right, overlap-minimising) ──────────
    /// Recomputed only when the month (focus/year), detail-visibility, or the deadline set changes;
    /// cached otherwise (NOT per frame / not on scroll). The overlay + hit-test use this as each
    /// label's base side; the runtime hover-flip can still override one on top.
    public func deadlineSides() -> [String: Bool] {
        let detail = z >= ViewConst.detailZ
        // Solve at the level's RESTING z (1 month / 2 week / 3 day), never the mid-tween z:
        // a zoom-in from year crossed detailZ MID-ANIMATION, computed the assignment on
        // in-between geometry (day widths still interpolating), and CACHED it for the whole
        // stay — labels only got their proper sides after a month slide re-solved at rest
        // (the "directionality only triggers while sliding between months" bug). The resting
        // level is also the cache key, so EVERY arrival at a month/week/day solves once, at
        // that level's rest layout, and stays cached until the month or deadline set changes.
        let zRest = CGFloat(max(1, min(3, Int(z.rounded()))))
        // During a month page-turn, `focus` is the anchor and `focus+dir` is the incoming month —
        // known the moment scrolling starts. Solve for BOTH so the incoming labels are already
        // assigned when the turn settles (no post-scroll flip). incoming = -1 when not turning.
        let incoming = anim.monthAnim
            .flatMap { a -> Int? in let m = focus + a.dir; return (0 ... 11).contains(m) ? m : nil } ?? -1
        if let k = caches.ddlSidesKey, k.focus == focus, k.incoming == incoming, k.year == year,
           k.gen == caches.deadlineGen, k.detail == detail, k.zRest == zRest {
            return caches.ddlSides
        }
        if detail {
            var s = deadlineSidesForMonth(focus, atZ: zRest)
            if incoming >= 0 {
                for (id, v) in deadlineSidesForMonth(incoming, atZ: zRest) where s[id] == nil {
                    s[id] = v
                }
            }
            caches.ddlSides = s
        } else {
            caches.ddlSides = [:]
        }
        caches.ddlSidesKey = (focus, incoming, year, caches.deadlineGen, detail, zRest)
        return caches.ddlSides
    }

    /// Overlap-minimising side assignment for ONE month's deadlines, at that month's resting layout.
    private func deadlineSidesForMonth(_ month: Int, atZ zRest: CGFloat) -> [String: Bool] {
        var g = snapshot(); g.focus = month; g.monthAnim = nil; g.z = zRest
        return deadlineSideAssignment(displayDeadlines(for: year), g)
    }

    public func update(_ id: String, _ mutate: (inout TimedEvent) -> Void) {
        guard let i = items.events.firstIndex(where: { $0.id == id }) else { return }
        beginTxn(); mutate(&items.events[i]); scheduleCommit()
    }

    public func updateBand(_ id: String, _ mutate: (inout BandEvent) -> Void) {
        guard let i = items.bands.firstIndex(where: { $0.id == id }) else { return }
        beginTxn(); mutate(&items.bands[i]); scheduleCommit()
    }

    public func updateDeadline(_ id: String, _ mutate: (inout Deadline) -> Void) {
        guard let i = items.deadlines.firstIndex(where: { $0.id == id }) else { return }
        beginTxn(); mutate(&items.deadlines[i]); scheduleCommit()
    }

    /// ── Rich fields (tags / repeat / promote / color), keyed by the item's OVERLAY id ──────────
    /// The drawer opens with the source (base) id, so these read/write the same key. For imported events
    /// the overlay id is the series key (see `overlayKey`), so a color/promote/note applies series-wide
    /// and survives rescheduling. Not on the undo stack yet (EditState only snapshots the lean arrays);
    /// they persist + invalidate the display cache.
    public func richTags(_ id: String) -> [String] {
        items.richById[overlayKey(id)]?.tags ?? []
    }

    public func notes(_ id: String) -> String {
        items.richById[overlayKey(id)]?.notes ?? ""
    }

    /// The item's repeat rule (nil = one-off) — read through the overlay key like notes/tags.
    /// Public for the iPhone detail sheet's "Repeats …" row.
    public func repeatRule(_ id: String) -> Repeat? {
        Repeat.parse(items.richById[overlayKey(id)]?.repeatJSON)
    }

    /// ── Tags are markdown ─────────────────────────────────────────────────────────────
    /// `rich.tags` is a CACHE of the note's `#tokens` (the drawer's tags UI is gone): recompute it
    /// whenever the note changes. Vendor-imported items keep the system "imported" tag (it isn't
    /// note-authored), and only their USER-typed postfix mints tags — a vendor description's
    /// stray "#word" must not become one. Bumps editGen only when the set actually changed:
    /// tag-keyed consumers (filter universe, visibility) are display caches, but plain note
    /// keystrokes must stay off the display-cache path (the setNotes noteGen rule).
    func syncTagCache(_ key: String) {
        guard var rf = items.richById[key] else { return }
        let body = rf.source == "manual" ? (rf.notes ?? "") : ManagedNote.splitNote(rf.notes).user
        var tags = TodoIndex.noteTags(body)
        if rf.source != "manual", rf.tags.contains("imported"), !tags.contains("imported") {
            tags.append("imported")
        }
        guard rf.tags != tags else { return }
        rf.tags = tags
        items.richById[key] = rf
        caches.editGen &+= 1
    }

    /// Idempotent tags→markdown migration + cache heal, run on every store load: any UI-era tag
    /// missing from its note is appended as a `#token` line (never the system "imported" tag),
    /// then every cache is recomputed from the notes — which also heals divergence from code
    /// paths that wrote notes without syncing.
    func migrateTagsIntoNotes() {
        var appended = false
        for (key, rf) in items.richById where !rf.tags.isEmpty {
            let body = rf.source == "manual" ? (rf.notes ?? "") : ManagedNote.splitNote(rf.notes).user
            let present = Set(TodoIndex.noteTags(body).map { $0.lowercased() })
            let missing = rf.tags
                .filter { !(rf.source != "manual" && $0.lowercased() == "imported") }
                .compactMap { TodoIndex.tagToken($0) }
                .filter { !present.contains($0.lowercased()) }
            guard !missing.isEmpty else { continue }
            var rf2 = rf
            let line = missing.map { "#" + $0 }.joined(separator: " ")
            rf2.notes = (rf.notes?.isEmpty == false) ? rf.notes! + "\n\n" + line : line
            items.richById[key] = rf2
            appended = true
        }
        for key in items.richById.keys {
            syncTagCache(key)
        }
        if appended {
            schedulePersist()
        }
    }

    public func setNotes(_ id: String, _ v: String) {
        let key = overlayKey(id)
        var rf = items.richById[key] ?? RichFields()
        guard rf.notes != v else { return }
        rf.notes = v; items.richById[key] = rf
        syncTagCache(key) // tags live IN the markdown; rich.tags is a cache of the note's #tokens
        // NOT in the calendar undo stack: notes are edited in the drawer's CodeMirror, which owns its
        // own undo (Cmd+Z while it's focused). Recording here would let its internal undo re-post the
        // note and pollute the calendar stack. Matches the web (notes are a separate lower layer).
        // noteGen (never editGen — display caches must not churn on note edits): the dashboards'
        // todo feed + JSON payload key on it. Without the bump, toggling an EVENT-note todo updated
        // the store but no generation — the native panel's Equatable gate saw "unchanged" and the
        // row's checkbox sat stale until an unrelated edit/sync bumped a gen minutes later.
        caches.noteGen &+= 1
        noteEdits.gen &+= 1 // OBSERVABLE: at-rest panels repaint through Observation (no tick needed)
        schedulePersist()
    }

    /// The user's chosen color for an imported event (nil = use the vendor calendar's color).
    public func colorOverride(_ id: String) -> String? {
        items.richById[overlayKey(id)]?.colorOverride
    }

    public func setColorOverride(_ id: String, _ color: String?) {
        mutateRich(overlayKey(id)) { $0.colorOverride = color }
    }

    /// Per-occurrence note (recurring events), keyed by the focused box id.
    public func occNote(_ id: String, _ key: String) -> String {
        items.richById[id]?.occurrenceNotes?[key] ?? ""
    }

    public func setOccNote(_ id: String, _ key: String, _ v: String) {
        var rf = items.richById[id] ?? RichFields()
        var occ = rf.occurrenceNotes ?? [:]
        guard occ[key] != v else { return }
        occ[key] = v.isEmpty ? nil : v
        rf.occurrenceNotes = occ.isEmpty ? nil : occ
        items.richById[id] = rf
        caches.noteGen &+= 1 // same freshness contract as setNotes
        noteEdits.gen &+= 1 // observable — see setNotes
        schedulePersist() // per-occurrence note: CodeMirror-owned undo, not the calendar stack (see setNotes)
    }
}
