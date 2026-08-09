// Batch modifications over a multi-selection. Each op is ALL-OR-NOTHING (if any selected item can't make
// the move it's a no-op) and kind-gated per the spec, and runs in ONE txn (a single undo step). Ops only
// touch EDITABLE items (imported/read-only excluded); a mixed-kind selection is a no-op for move/expand.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// The deduped, editable SOURCE ids of the selection (imported/ghost boxes collapse to their source),
    /// or nil if any selected item is read-only (imported) or unknown — move/expand/rename need all-editable.
    private func editableSources() -> [String]? {
        let srcs = Array(Set(selectedIds.map { sourceId(of: $0) }))
        guard !srcs.isEmpty, srcs.allSatisfy({ !isImported($0) && kind(of: $0) != nil }) else { return nil }
        return srcs
    }

    private func allBands(_ s: [String]) -> Bool {
        s.allSatisfy { kind(of: $0) == .band }
    }

    private func allTimeline(_ s: [String]) -> Bool {
        s
            .allSatisfy { kind(of: $0) == .timed || kind(of: $0) == .deadline }
    }

    private func allTimed(_ s: [String]) -> Bool {
        s.allSatisfy { kind(of: $0) == .timed }
    }

    /// ── Move (⌘-arrows) ────────────────────────────────────────────────────────────
    /// ⌘←/→ = ±1 day, ⌘↑/↓ = ±1 lane (bands) or ±15 min (timed/deadline). Bands and timeline items don't mix.
    public func batchMove(dx: Int, dy: Int) {
        guard let srcs = editableSources() else { return }
        let set = Set(srcs)
        if allBands(srcs) {
            if dx != 0 {
                batchBandDay(set, dx)
            } else if dy != 0 {
                batchBandTrack(set, dy)
            }
        } else if allTimeline(srcs) {
            if dx != 0 {
                batchTimelineDay(set, dx)
            } else if dy != 0 {
                batchTimelineVert(set, dy)
            }
        }
        scrollToSelected()
    }

    private func batchBandDay(_ set: Set<String>, _ dx: Int) { // stay within the month, all-or-nothing
        let bands = items.bands.filter { set.contains($0.id) }
        guard !bands.isEmpty, bands.allSatisfy({ $0.startDay + dx >= 1 && $0.endDay + dx <= daysInMonth(
            $0.year,
            $0.month
        ) }) else { return }
        beginTxn()
        for i in items.bands.indices
            where set.contains(items.bands[i].id) {
            items.bands[i].startDay += dx; items.bands[i].endDay += dx
        }
        commitTxn()
    }

    private func batchBandTrack(_ set: Set<String>, _ dy: Int) { // lanes 0…3, all-or-nothing
        let bands = items.bands.filter { set.contains($0.id) }
        guard !bands.isEmpty, bands.allSatisfy({ $0.track + dy >= 0 && $0.track + dy <= 3 }) else { return }
        beginTxn()
        for i in items.bands.indices where set.contains(items.bands[i].id) {
            items.bands[i].track += dy
        }
        commitTxn()
    }

    private func batchTimelineDay(_ set: Set<String>, _ dx: Int) { // ±1 day, NOT across the month, all-or-nothing
        var ev: [(Int, (Int, Int, Int))] = [], dl: [(Int, (Int, Int, Int))] = []
        for i in items.events.indices where set.contains(items.events[i].id) {
            let nd = addDays(items.events[i].year, items.events[i].month, items.events[i].day, dx)
            if nd.1 != items.events[i].month {
                return
            } // crossed the month → abort the whole batch
            ev.append((i, nd))
        }
        for i in items.deadlines.indices where set.contains(items.deadlines[i].id) {
            let nd = addDays(items.deadlines[i].year, items.deadlines[i].month, items.deadlines[i].day, dx)
            if nd.1 != items.deadlines[i].month {
                return
            }
            dl.append((i, nd))
        }
        beginTxn()
        for (i, nd) in ev {
            items.events[i].year = nd.0; items.events[i].month = nd.1; items.events[i].day = nd.2
        }
        for (i, nd) in dl {
            items.deadlines[i].year = nd.0; items.deadlines[i].month = nd.1; items.deadlines[i].day = nd.2
        }
        commitTxn()
    }

    private func batchTimelineVert(_ set: Set<String>, _ dy: Int) { // ±15 min, ROLLS across days (few limits)
        let step = CGFloat(dy) * 0.25
        beginTxn()
        for i in items.events.indices where set.contains(items.events[i].id) {
            var e = items.events[i]; let dur = e.endHour - e.startHour
            var s = e.startHour + step
            while s < 0 {
                let nd = addDays(e.year, e.month, e.day, -1); (e.year, e.month, e.day) = nd; s += 24
            }
            while s >= 24 {
                let nd = addDays(e.year, e.month, e.day, 1); (e.year, e.month, e.day) = nd; s -= 24
            }
            e.startHour = s; e.endHour = s + dur
            items.events[i] = e
        }
        for i in items.deadlines.indices where set.contains(items.deadlines[i].id) {
            var d = items.deadlines[i]; var h = d.hour + step
            while h < 0 {
                let nd = addDays(d.year, d.month, d.day, -1); (d.year, d.month, d.day) = nd; h += 24
            }
            while h >= 24 {
                let nd = addDays(d.year, d.month, d.day, 1); (d.year, d.month, d.day) = nd; h -= 24
            }
            d.hour = h
            items.deadlines[i] = d
        }
        commitTxn()
    }

    /// ── Expand / shrink (⇧-arrows) ─────────────────────────────────────────────────
    /// ⇧←/→ resize the day-span of all-band selections; ⇧↑/↓ resize the duration of all-timed selections.
    /// All-or-nothing: no-op unless EVERY item can actually change (not already at its min/max).
    public func batchResize(dx: Int, dy: Int) {
        guard let srcs = editableSources() else { return }
        let set = Set(srcs)
        if allBands(srcs), dx != 0 {
            let bands = items.bands.filter { set.contains($0.id) }
            func ne(_ b: BandEvent) -> Int {
                max(b.startDay, min(daysInMonth(b.year, b.month), b.endDay + dx))
            }
            guard !bands.isEmpty, bands.allSatisfy({ ne($0) != $0.endDay }) else { return }
            beginTxn()
            for i in items.bands.indices
                where set.contains(items.bands[i].id) {
                items.bands[i].endDay = ne(items.bands[i])
            }
            commitTxn()
        } else if allTimed(srcs), dy != 0 { // deadlines have no duration → require ALL-timed
            let evs = items.events.filter { set.contains($0.id) }
            let step = CGFloat(dy) * 0.25
            func ne(_ e: TimedEvent) -> CGFloat {
                max(e.startHour + 0.25, min(24, e.endHour + step))
            }
            guard !evs.isEmpty, evs.allSatisfy({ ne($0) != $0.endHour }) else { return }
            beginTxn()
            for i in items.events.indices
                where set.contains(items.events[i].id) {
                items.events[i].endHour = ne(items.events[i])
            }
            commitTxn()
        }
    }

    /// ── Delete ─────────────────────────────────────────────────────────────────────
    /// A classification of what a batch delete would do, for the confirm dialog's summary.
    public struct BatchDeleteSummary: Equatable, Sendable {
        public var toDelete = 0, toHide = 0, alreadyHidden = 0, recurring = 0, promoted = 0
        public var isEmpty: Bool {
            toDelete + toHide == 0
        }

        public var title: String {
            let n = toDelete + toHide
            return n == 0 ? "Nothing to delete" : "Delete \(n) selected item\(n == 1 ? "" : "s")?"
        }

        public var note: String {
            var p: [String] = []
            if toDelete > 0 {
                p.append("\(toDelete) \(toDelete == 1 ? "event" : "events") will be permanently deleted.")
            }
            if recurring > 0 {
                p
                    .append(
                        "\(recurring) of \(recurring == 1 ? "these is a recurring series" : "these are recurring series") and will be removed in full, including every occurrence."
                    )
            }
            if promoted > 0 {
                p
                    .append(
                        "\(promoted) \(promoted == 1 ? "is a promoted event" : "are promoted events") and will be removed along with \(promoted == 1 ? "its" : "their") promotion."
                    )
            }
            if toHide > 0 {
                p
                    .append(
                        "\(toHide) imported \(toHide == 1 ? "event" : "events") cannot be deleted and will be hidden instead."
                    )
            }
            if alreadyHidden > 0 {
                p
                    .append(
                        "\(alreadyHidden) imported \(alreadyHidden == 1 ? "event is" : "events are") already hidden and will be skipped."
                    )
            }
            return p.joined(separator: " ")
        }
    }

    /// Classify the current selection for the confirm dialog (originals of recurring/promoted are deleted;
    /// imported are hidden; already-hidden imported are skipped).
    public func batchDeleteSummary() -> BatchDeleteSummary {
        var s = BatchDeleteSummary()
        for src in Set(selectedIds.map { sourceId(of: $0) }) {
            if isImported(src) {
                if isUserHidden(src) {
                    s.alreadyHidden += 1
                } else {
                    s.toHide += 1
                }
            } else {
                s.toDelete += 1
                if repeatConfig(src) != nil {
                    s.recurring += 1
                }
                if promoteTrack(src) != nil {
                    s.promoted += 1
                }
            }
        }
        return s
    }

    /// Execute the batch delete in ONE undo step: editable sources removed (whole series for recurring),
    /// imported hidden. Clears the selection.
    public func performBatchDelete() {
        let srcs = Set(selectedIds.map { sourceId(of: $0) })
        guard !srcs.isEmpty else { return }
        beginTxn()
        for s in srcs {
            if isImported(s) {
                if !isUserHidden(s) {
                    hideImportedSeries(s)
                }
            } else {
                items.events.removeAll { $0.id == s }
                items.bands.removeAll { $0.id == s }
                items.deadlines.removeAll { $0.id == s }
            }
        }
        setSelection([], primary: nil)
        commitTxn()
    }

    /// ── Rename ─────────────────────────────────────────────────────────────────────
    /// Set the title of every editable selected item to `title` (imported ones skipped). Live-callable per
    /// keystroke — the whole rename is one undo step because a burst of these coalesces (scheduleCommit).
    public func batchSetTitle(_ title: String) {
        let set = Set(selectedIds.map { sourceId(of: $0) }).filter { !isImported($0) && kind(of: $0) != nil }
        guard !set.isEmpty else { return }
        beginTxn()
        for i in items.events.indices where set.contains(items.events[i].id) {
            items.events[i].title = title
        }
        for i in items.bands.indices where set.contains(items.bands[i].id) {
            items.bands[i].title = title
        }
        for i in items.deadlines.indices where set.contains(items.deadlines[i].id) {
            items.deadlines[i].title = title
        }
        scheduleCommit()
    }

    /// The current selection's titles by source id — captured when the batch-rename panel opens,
    /// so Cancel/Esc can put them back (typing renames LIVE via batchSetTitle).
    public func batchTitlesSnapshot() -> [String: String] {
        let set = Set(selectedIds.map { sourceId(of: $0) })
        var out: [String: String] = [:]
        for e in items.events where set.contains(e.id) {
            out[e.id] = e.title
        }
        for b in items.bands where set.contains(b.id) {
            out[b.id] = b.title
        }
        for d in items.deadlines where set.contains(d.id) {
            out[d.id] = d.title
        }
        return out
    }

    /// Cancel of a live batch rename: restore every captured title verbatim.
    public func batchRestoreTitles(_ titles: [String: String]) {
        guard !titles.isEmpty else { return }
        beginTxn()
        for i in items.events.indices {
            if let t = titles[items.events[i].id] {
                items.events[i].title = t
            }
        }
        for i in items.bands.indices {
            if let t = titles[items.bands[i].id] {
                items.bands[i].title = t
            }
        }
        for i in items.deadlines.indices {
            if let t = titles[items.deadlines[i].id] {
                items.deadlines[i].title = t
            }
        }
        scheduleCommit()
    }
}
