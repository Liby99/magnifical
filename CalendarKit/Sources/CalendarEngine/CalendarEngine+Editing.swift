// Pointer-drag EDITING: hit-testing the timeline/lanes (eventAt/bandAt/deadlineAt), the drag
// apply steps (move/resize/create for timed events, bands, and deadlines, with snapping and
// cross-day/lane clamps), and the inline band/deadline title editing entry points.
// Split from CalendarEngine.swift (the god-file diet).

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// ── Editing helpers ───────────────────────────────────────────────────────────
    private func snap(_ h: CGFloat, _ stepMin: CGFloat) -> CGFloat {
        let step = stepMin / 60
        return max(0, min(24, (h / step).rounded() * step))
    }

    /// Topmost event under the cursor + which zone (body vs top/bottom resize edge).
    /// Timed-event box internal layout — mirrors BandStyle / EventsOverlay.TimedBox (CalendarUI) so the
    /// hit-test can tell the TITLE region (I-beam) from the accent bar / time / body (grab). Keep in sync.
    private enum EventBox {
        static let accentInset: CGFloat = 6
        static let accentWidth: CGFloat = 1
        static let accentWidthSelected: CGFloat = 3
        static let barTextGap: CGFloat = 5
        static let titleTrailing: CGFloat = 6
        static let vPad: CGFloat = 3
        static let titleLineH: CGFloat = 17 // ~one line of the 13pt title
        static let edge: CGFloat = 5 // top/bottom resize hot-zone
    }

    func eventAt(_ p: CGPoint, _ g: SceneInput) -> (id: String, zone: PointerKind, overTitle: Bool)? {
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return nil }
        // Timed events live ONLY in the hour timeline. A scrolled-up event's rect can extend above the
        // timeline top (into the band/track lanes), but the drawn sticker is clipped there — so clip the
        // hit-test too, else hovering/dragging empty track space would grab the off-screen event.
        guard p.y >= tl.tlTop, p.y <= tl.tlBottom else { return nil }
        if z > 2 && p.x >= tl.x0 + CGFloat(daily.dom) * tl.colW {
            return nil
        } // under dashboard
        guard tl.colW > 0 else { return nil }
        // Only the day column under the cursor can contain the point. Resolve that column and hit-test
        // just that one day — packing it once. The old code re-filtered the full list and re-ran
        // layoutDay for EVERY event (O(N²) per mouse-move); with hundreds of events that stalled the
        // hover/cursor pipeline, so the mouse-driven cursor line lagged while everything else stayed
        // smooth. Pack against the same ghost-inclusive same-day set the overlay renders → hit rects
        // match the drawn rects.
        let relCursor = Int(floor((p.x - tl.x0) / tl.colW)) + 1
        if dailyFade(relCursor, g) <= 0.02 {
            return nil
        }
        // The column maps to one calendar day (resolveDate handles Dec↔Jan spillover into the neighbor
        // year); the per-day index then returns exactly that day's events (base + ghosts).
        guard let rd = resolveDate(year, focus, relCursor) else { return nil }
        let sameDay = eventsOn(rd.year, rd.month, rd.day)
        guard !sameDay.isEmpty else { return nil }
        let layout = layoutDay(sameDay)
        var found: (String, PointerKind, Bool)?
        for e in sameDay {
            guard let r = eventRect(e, year, focus, tl, g.vp, layout[e.id]) else { continue }
            let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
            if rect.contains(p) {
                let nearTop = p.y - rect.minY < EventBox.edge
                let nearBot = rect.maxY - p.y < EventBox.edge
                // A multi-day event is drawn as per-day segments; only its REAL first-top and last-bottom
                // are resize handles — an internal midnight (continuation) edge is not. Detect via the whole
                // event's span (endHour may exceed 24), computed only when the cursor is actually near an edge.
                var zone: PointerKind = .move
                if nearTop || nearBot {
                    let span = viewEvents().first { $0.id == e.id }
                    let offset = span.map { dayDiff($0.year, $0.month, $0.day, rd.year, rd.month, rd.day) } ?? 0
                    let topReal = offset == 0
                    let botReal = span.map { $0.endHour <= CGFloat(offset + 1) * 24 + 0.001 } ?? true
                    if nearTop && topReal {
                        zone = .resizeTop
                    } else if nearBot && botReal {
                        zone = .resizeBottom
                    }
                }
                // Title text region: right of the accent bar, the top line — where a second click edits it.
                let barW = (e.id == selectedId) ? EventBox.accentWidthSelected : EventBox.accentWidth
                let leftInset = EventBox.accentInset + barW + EventBox.barTextGap
                let overTitle = p.x >= rect.minX + leftInset && p.x <= rect.maxX - EventBox.titleTrailing
                    && p.y >= rect.minY + EventBox.vPad && p.y <= rect.minY + EventBox.vPad + EventBox.titleLineH
                found = (e.id, zone, overTitle) // keep last → topmost drawn
            }
        }
        return found
    }

    func createSpot(at p: CGPoint, _ g: SceneInput) -> (year: Int, month: Int, day: Int, anchor: CGFloat)? {
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0, p.y >= tl.tlTop, p.y <= tl.tlBottom else { return nil }
        if z > 2 && p.x >= tl.x0 + CGFloat(daily.dom) * tl.colW {
            return nil
        }
        let (domOpt, hf) = pointToSlot(p.x, p.y, tl)
        guard let dom = domOpt, let r = resolveDate(year, focus, dom) else { return nil }
        return (r.year, r.month, r.day, snap(hf, 30))
    }

    /// Classify an empty-space point for the right-click menu: a week/day timeline slot
    /// (create timed events / deadlines there) or a band-lane cell (create bands there).
    public enum EmptySpot: Equatable {
        case timeline(year: Int, month: Int, day: Int, hour: CGFloat)
        case bandLane(year: Int, month: Int, track: Int, day: Int)
    }

    public func emptySpot(at p: CGPoint) -> EmptySpot? {
        let g = snapshot()
        if z >= 1.5, let s = createSpot(at: p, g) {
            return .timeline(year: s.year, month: s.month, day: s.day, hour: s.anchor)
        }
        if let slot = bandSlotAtPoint(p.x, p.y, g) {
            return .bandLane(year: year, month: slot.month, track: slot.track, day: slot.day)
        }
        return nil
    }

    /// ⌘L — create a deadline at the block cursor's timeline slot (keyboard mode, week/day) or at
    /// the mouse pointer's slot, then open its drawer with the title selected. No-op off the timeline.
    public func createDeadlineViaShortcut() {
        guard !drawerOpen else { return }
        var target: (year: Int, month: Int, day: Int, hour: CGFloat)?
        if cursor.keyboardActive, level(z) >= 2 {
            let d = level(z) == 2 ? cursor.blockDay : daily.dom // mirrors createEventAtBlock
            target = (year, focus, d, cursor.blockHour)
        } else if let pp = pointerPos, let s = createSpot(at: pp, snapshot()) {
            target = (s.year, s.month, s.day, s.anchor)
        }
        guard let t = target else { return }
        let id = createDeadline(year: t.year, month: t.month, day: t.day, hour: min(t.hour, 23.75),
                                title: "New Deadline", color: "default")
        onRequestOpenDrawer?(id, true)
    }

    /// The quick-add "+" affordance for a deadline: when the cursor hovers near a day column's LEFT edge
    /// (hover.nearLeft, within ADD_EDGE_THRESHOLD) in week/day view, offer to create a deadline snapped to
    /// the nearest hour line. Returns its screen point + the target date/hour, or nil when it shouldn't
    /// show (not near-left, off the timeline, or an existing deadline already sits on that day+hour).
    public func deadlineAddSpot(_ g: SceneInput) -> DeadlineAddSpot? {
        guard g.z >= 1.5, hover.nearLeft == true, let dom = hover.dom, let hf = hover.hourFrac else { return nil }
        let hour = min(23, max(0, Int(hf.rounded()))) // snap to the nearest hour line
        guard let r = resolveDate(year, focus, dom) else { return nil }
        if displayDeadlines(for: r.year)
            .contains(where: { $0.month == r.month && $0.day == r.day && abs($0.hour - CGFloat(hour)) < 1e-6 }) {
            return nil // already a deadline there — don't offer to add
        }
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return nil }
        let x = tl.x0 + CGFloat(dom - 1) * tl.colW // day column's left edge
        let y = tl.tlTop + CGFloat(hour) * tl.hourH - tl.scroll // the hour line
        guard y >= tl.tlTop, y <= tl.tlBottom, x >= Layout.labelW - 1, x <= g.vp.w else { return nil }
        let hovering = pointerPos.map { hypot($0.x - x, $0.y - y) <= 10 } ?? false // cursor over the 15px "+"
        return DeadlineAddSpot(x: x, y: y, year: r.year, month: r.month, day: r.day, hour: hour, hovering: hovering)
    }

    func applyMove(_ d: Drag, _ p: CGPoint, _ tl: TimelineInfo) {
        guard let orig = d.orig, let idx = items.events.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        // The grid is in the main (view) timezone, so compute the move in DISPLAY space against the
        // display-converted original, then fold the result back into the event's anchor zone to store.
        var ev = displayEvent(orig)
        let dur = ev.endHour - ev.startHour
        let ns = max(0, min(24 - dur, snap(ev.startHour + (p.y - d.startPoint.y) / tl.hourH, 15)))
        ev.startHour = ns; ev.endHour = ns + dur
        if let dom = pointToSlot(p.x, p.y, tl).dom,
           let r = resolveDate(year, focus, dom) {
            ev.year = r.year; ev.month = r.month; ev.day = r.day
        }
        items.events[idx] = anchorEvent(ev)
    }

    func applyResize(_ d: Drag, _ p: CGPoint, _ tl: TimelineInfo, top: Bool) {
        guard let idx = items.events.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let slot = pointToSlot(p.x, p.y, tl)
        var ev = displayEvent(items.events[idx])
        // Day-column aware: the pointer's hour is relative to WHICH day it's over, so `abs` is hours since
        // the event's start-day midnight — it may be <0 (edge dragged into an earlier day) or >24 (dragged
        // into a later day), letting a resize span midnight instead of collapsing to the minimum.
        let ptDayDiff: Int = {
            guard let dom = slot.dom, let r = resolveDate(year, focus, dom) else { return 0 }
            return dayDiff(ev.year, ev.month, ev.day, r.year, r.month, r.day)
        }()
        let abs = CGFloat(ptDayDiff) * 24 + snap(slot.hourFrac, 15)
        if top {
            // Move the START edge, keep the end fixed. Rebase the start day when it crosses midnight(s) so
            // startHour stays in [0,24) and endHour stays pinned to the same absolute moment.
            let ns = min(ev.endHour - 0.25, abs)
            let k = Int(floor(ns / 24)) // whole-day shift of the start day (≤0 = earlier)
            let nd = addDays(ev.year, ev.month, ev.day, k)
            ev.year = nd.0; ev.month = nd.1; ev.day = nd.2
            ev.startHour = ns - CGFloat(k) * 24
            ev.endHour -= CGFloat(k) * 24
        } else {
            ev.endHour = max(ev.startHour + 0.25, abs) // may exceed 24 → multi-day span (drawn as segments)
        }
        items.events[idx] = anchorEvent(ev)
    }

    func applyCreate(_ p: CGPoint, _ tl: TimelineInfo) {
        guard var d = drag else { return }
        beginTxn() // snapshot pre-create so undo removes the new event
        if d.eventId == nil {
            guard let mo = d.createMonth, let dy = d.createDay, let a = d.anchorHour else { return }
            // UUID (not the counter) so ids are globally unique — two devices creating
            // offline must never mint the same recordName. Prefix kept for readability.
            let id = "new-\(UUID().uuidString)"
            items.events.append(TimedEvent(
                id: id,
                year: d.createYear ?? year,
                month: mo,
                day: dy,
                startHour: a,
                endHour: min(24, a + 0.25),
                title: "New event",
                color: "blue",
                anchorTz: anchorNow
            ))
            d.eventId = id; drag = d; selectedId = id
        }
        guard let id = d.eventId, let idx = items.events.firstIndex(where: { $0.id == id }), let a = d.anchorHour,
              let cm = d.createMonth, let cd = d.createDay else { return }
        // Day-column aware create: the drag anchor sits at (createDate, anchorHour); the pointer may now be
        // over another day. Measure both endpoints as hours since the create-day midnight, so dragging into
        // the next/previous day makes a multi-day event. Rebase the start day so startHour stays in [0,24).
        let cy = d.createYear ?? year
        let slot = pointToSlot(p.x, p.y, tl)
        let ptDayDiff: Int = {
            guard let dom = slot.dom, let r = resolveDate(year, focus, dom) else { return 0 }
            return dayDiff(cy, cm, cd, r.year, r.month, r.day)
        }()
        let curAbs = CGFloat(ptDayDiff) * 24 + snap(slot.hourFrac, 15)
        var lo = min(a, curAbs), hi = max(a, curAbs)
        if hi - lo < 0.25 {
            hi = lo + 0.25
        }
        let k = Int(floor(lo / 24))
        let nd = addDays(cy, cm, cd, k)
        var ev = items.events[idx]
        ev.year = nd.0; ev.month = nd.1; ev.day = nd.2
        ev.startHour = lo - CGFloat(k) * 24
        ev.endHour = hi - CGFloat(k) * 24
        items.events[idx] = ev
    }

    /// ── Band + deadline editing ─────────────────────────────────────────────────
    private func bandDay(_ px: CGFloat, _ month: Int, _ g: SceneInput) -> Int {
        let f = frameFor(month, g)
        return f.dayW > 0 ? Int((px - f.x0) / f.dayW) + 1 : 1
    }

    /// Months whose band lanes could contain point `p` — a conservative superset that prunes the band
    /// hit-test to a handful of months instead of the whole year. Week/day view (z≥1.5) positions bands
    /// relative to the focus window, so the focus month and its two neighbors can spill in. Year/month
    /// view positions each band in its own month row, so only the row(s) under `p.y` qualify (frameFor is
    /// anim-aware, so a month page-turn's two overlapping rows are both included).
    private func candidateBandMonths(_ p: CGPoint, _ g: SceneInput) -> [Int] {
        if g.z >= 1.5 {
            return [g.focus - 1, g.focus, g.focus + 1].filter { $0 >= 0 && $0 <= 11 }
        }
        var months: [Int] = []
        for m in 0 ..< 12 {
            let f = frameFor(m, g, anim: g.monthAnim)
            if f.opacity >= 0.02, p.y >= f.bandY, p.y < f.bandY + 4 * f.trackH {
                months.append(m)
            }
        }
        return months
    }

    func bandAt(_ p: CGPoint, _ g: SceneInput) -> (id: String, zone: PointerKind)? {
        /// Return the TOP-most band under the cursor, matching the draw order: selected and
        /// hovered are raised to the front; otherwise later start > shorter length > higher id.
        func tier(_ b: BandEvent) -> Int {
            b.id == selectedId ? 2 : (b.id == hoveredEventId ? 1 : 0)
        }
        var best: (b: BandEvent, r: BandRect, rect: CGRect)?
        // Only the candidate months' bands can be under the cursor — skip the rest of the year's ghosts.
        for b in candidateBandMonths(p, g).flatMap({ bandsInMonth(year, $0) }) { // recurrence + promoted ghosts too
            guard let r = bandEventRect(b, g, anim: g.monthAnim) else { continue }
            let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            guard rect.contains(p) else { continue }
            guard let cur = best else { best = (b, r, rect); continue }
            let tb = tier(b), tc = tier(cur.b)
            let onTop: Bool
            if tb != tc {
                onTop = tb > tc
            } else {
                let bl = b.endDay - b.startDay, cl = cur.b.endDay - cur.b.startDay
                onTop = b.startDay > cur.b.startDay
                    || (b.startDay == cur.b.startDay && bl < cl)
                    || (b.startDay == cur.b.startDay && bl == cl && b.id > cur.b.id)
            }
            if onTop {
                best = (b, r, rect)
            }
        }
        guard let bb = best else { return nil }
        // Ghost / promoted bars aren't in items.bands → they're read-only (move/resize no-op); only a
        // real, already-selected band exposes resize edges. Otherwise it's a move/select.
        let isReal = items.bands.contains { $0.id == bb.b.id }
        let zone: PointerKind = (isReal && bb.b.id == selectedId)
            ? ((p.x - bb.rect.minX < 6 && !bb.r.clipStart) ? .bandResizeL
                : (bb.rect.maxX - p.x < 6 && !bb.r.clipEnd ? .bandResizeR : .bandMove))
            : .bandMove
        return (bb.b.id, zone)
    }

    func applyBandMove(_ d: Drag, _ p: CGPoint, _ g: SceneInput) {
        guard let orig = d.origBand, let idx = items.bands.firstIndex(where: { $0.id == d.eventId }),
              let slot = bandSlotAtPoint(p.x, p.y, g) else { return } // follow the lane under the cursor
        beginTxn()
        let len = orig.endDay - orig.startDay
        // Keep the grab offset (day within the band where the drag started), so a band can be
        // dragged across months/tracks in year view — not just within its own month.
        let grab = (bandSlotAtPoint(d.startPoint.x, d.startPoint.y, g)?.day ?? orig.startDay) - orig.startDay
        let start = max(1, min(daysInMonth(year, slot.month) - len, slot.day - grab))
        var b = items.bands[idx]
        b.month = slot.month; b.track = slot.track; b.startDay = start; b.endDay = start + len
        items.bands[idx] = b
    }

    /// Drag a PROMOTED ghost band: the ghost mirrors its source event's DATE, so only the LANE follows the
    /// cursor — the drag just re-homes `rich.promoteTrack` on the SOURCE (timed event or deadline). The
    /// ghost's date/month never change (drag horizontally all you like — it stays put), and the source's
    /// own time is untouched. mutateRich opens the txn; pointer-up commits → one undo step per drag.
    func applyPromotedLaneMove(_ d: Drag, _ p: CGPoint, _ g: SceneInput) {
        guard let boxId = d.eventId, let slot = bandSlotAtPoint(p.x, p.y, g) else { return }
        let src = sourceId(of: boxId)
        guard items.richById[overlayKey(src)]?.promoteTrack != slot.track else { return }
        setPromoteTrack(src, slot.track)
    }

    func applyBandResize(_ d: Drag, _ p: CGPoint, _ g: SceneInput, left: Bool) {
        guard let orig = d.origBand, let idx = items.bands.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let day = max(1, min(daysInMonth(year, orig.month), bandDay(p.x, orig.month, g)))
        var b = items.bands[idx]
        if left {
            b.startDay = min(b.endDay, day)
        } else {
            b.endDay = max(b.startDay, day)
        }
        items.bands[idx] = b
    }

    func applyBandCreate(_ p: CGPoint, _ g: SceneInput) {
        guard var d = drag else { return }
        beginTxn()
        if d.eventId == nil {
            guard let mo = d.bandMonth, let tr = d.bandTrack, let a = d.bandAnchorDay else { return }
            let id = "newb-\(UUID().uuidString)" // globally unique (see applyCreate)
            items.bands.append(BandEvent(
                id: id,
                year: year,
                month: mo,
                track: tr,
                startDay: a,
                endDay: a,
                title: "New event",
                color: "blue"
            ))
            d.eventId = id; drag = d; selectedId = id
        }
        guard let id = d.eventId, let idx = items.bands.firstIndex(where: { $0.id == id }), let mo = d.bandMonth,
              let a = d.bandAnchorDay else { return }
        let cur = max(1, min(daysInMonth(year, mo), bandDay(p.x, mo, g)))
        var b = items.bands[idx]
        b.startDay = min(a, cur); b.endDay = max(a, cur)
        items.bands[idx] = b
    }

    func deadlineAt(_ p: CGPoint, _ g: SceneInput) -> String? {
        let tl = timelineInfo(g)
        guard p.y >= tl.tlTop, p.y <= tl.tlBottom else { return nil } // clip to the timeline (see eventAt)
        let dls = displayDeadlines(for: year) // includes recurrence ghosts (selectable, read-only)
        let sides = deadlineSides() // same base sides the overlay uses
        var hit: String?
        for d in dls {
            guard let pos = deadlinePos(d, g) else { continue }
            // Hit the LABEL pill (at its base side) or the moment line itself.
            let onLine = p.x >= pos.x && p.x <= pos.x + pos.w && abs(p.y - pos.y) < 8
            let info = deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, g)
            if info.rect(onLeft: sides[d.id] ?? info.defaultOnLeft).contains(p) || onLine {
                hit = d.id
            }
        }
        return hit
    }

    func applyDdlMove(_ d: Drag, _ p: CGPoint, _ g: SceneInput) {
        guard let orig = d.origDdl, let idx = items.deadlines.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let tl = timelineInfo(g)
        // Delta-based, in DISPLAY (main-tz) space: move relative to where the deadline was shown at
        // mouse-down, by the mouse delta — never jump to the absolute pointer (important when dragging the
        // side label, not the line). The result is folded back into the deadline's anchor zone to store.
        var dd = displayDeadline(orig)
        dd.hour = max(0, min(24, snap(dd.hour + (p.y - d.startPoint.y) / tl.hourH, 15)))
        let dayDelta = tl.colW > 0 ? Int(((p.x - d.startPoint.x) / tl.colW).rounded()) : 0
        if dayDelta != 0, let origRd = relDomOf(year, focus, dd.year, dd.month, dd.day),
           let r = resolveDate(year, focus, origRd + dayDelta) {
            dd.year = r.year; dd.month = r.month; dd.day = r.day
        }
        items.deadlines[idx] = anchorDeadline(dd)
    }

    public func onEscape() {
        cancelTween()
        cursor.trackNameCursor = nil // leaving month view drops the track-name stops
        clearDashStop() // leaving day view drops the dashboard stops
        let dest = max(0, level(z) - 1)
        tweenZ(to: CGFloat(dest))
        syncBlockToView(dest) // carry the block cursor to the view we're zooming out to
    }

    /// Land the block cursor on the sensible cell for a view level (used on zoom-out and mouse→keyboard
    /// hand-off): year → the focused month; month → the focused day.
    func syncBlockToView(_ lvl: Int) {
        switch lvl {
        case 0: cursor.blockMonth = focus
        case 1: cursor.blockMonth = focus; cursor.blockDay = min(daysInMonth(year, focus), max(1, daily.dom))
        case 2: cursor.blockDay = min(daysInMonth(year, focus), max(1, daily.dom)) // week: keep the day + hour
        default: break
        }
    }

    /// Step the block cursor's hour (week/day), clamped to the 0…23 grid, gliding the timeline to follow.
    func stepHour(_ dy: Int) {
        let h = max(0, min(23, Int(cursor.blockHour.rounded()) + dy))
        if CGFloat(h) != cursor.blockHour {
            cursor.blockHour = CGFloat(h); ensureHourVisible()
        }
    }

    /// Week view: glide the 7-day focus window (`week`) so day `d` stays visible (shifts a day at the edge).
    func ensureDayVisibleWeek(_ d: Int) {
        let target = anim.weekTween?.to ?? week
        let startDOM = 1 - CGFloat(firstDOW(year, focus)) + target * 7 // the window's Sunday, in DOM
        var newWeek = target
        if CGFloat(d) < startDOM {
            newWeek = target - (startDOM - CGFloat(d)) / 7
        } else if CGFloat(d) > startDOM + 6 {
            newWeek = target + (CGFloat(d) - (startDOM + 6)) / 7
        }
        newWeek = clamp(newWeek, 0, CGFloat(max(0, weeksInMonth(year, focus) - 1)))
        if abs(newWeek - week) < 0.001 {
            return
        }
        // Pace-locked: ~0.25s per day-step (a day = 1/7 of a week) so the glide covers the SAME distance
        // per second no matter how many presses are queued — a fixed duration over a growing gap would
        // keep accelerating. ease OUT (not in-out) so a rapid re-press kicks forward at full speed instead
        // of restarting in the slow ease-IN ramp. `week` is already live per-frame, so retargets seamlessly.
        let dur = max(0.12, (0.25 * 7) * Double(abs(newWeek - week)))
        anim.weekTween = Tween(from: week, to: newWeek, start: Date(), duration: dur, ease: easeOut)
    }

    /// Day view: glide to the prev/next day (same hour). Month boundary is deferred (clamped for now).
    func swipeDay(_ dx: Int) {
        let dim = daysInMonth(year, focus)
        let base = anim.dayTween.map { Int($0.to.rounded()) } ?? daily.dom // chain rapid presses off the target
        let nd = base + dx
        guard nd >= 1, nd <= dim else { return }
        cursor.blockDay = nd
        // Retarget from the LIVE fractional position mid-glide, NOT the last committed integer day: a
        // rapid second press otherwise snaps the viewport back to `daily.dom` before gliding on (a visible
        // jump). One animator continuously chases whatever target the latest press set.
        let current = anim.dayTween?.value(at: Date()) ?? CGFloat(daily.dom)
        // Duration scales with the remaining distance so the PACE stays constant however many presses are
        // queued (a fixed duration over a growing gap would keep speeding up). ease OUT, not in-out: it
        // starts at full speed, so a rapid re-press doesn't restart in the slow ease-IN ramp (which, over
        // the now-longer duration, would crawl) — it kicks forward immediately and eases into the target.
        let dur = max(0.14, 0.3 * Double(abs(CGFloat(nd) - current)))
        anim.dayTween = Tween(from: current, to: CGFloat(nd), start: Date(), duration: dur, ease: easeOut)
    }

    /// Glide the timeline scroll so the SELECTED event is fully on screen (week/day view). A timed event
    /// uses its hour span; a deadline a small window around its moment; a band needs no timeline scroll.
    func ensureSelectedEventVisible() {
        guard level(z) >= 2, let sel = selectedId else { return }
        let top: CGFloat, bot: CGFloat
        if let e = displayEvents(for: year).first(where: { $0.id == sel }) {
            // A cross-midnight event has a slice on each day; reveal the one on the currently-focused day
            // (the segment the cursor is on), falling back to the head. A same-day event has one segment.
            let segs = timedSegments(e)
            let seg = segs.first { $0.event.month == focus && $0.event.day == daily.dom } ?? segs[0]
            top = seg.event.startHour; bot = seg.event.endHour
        } else if let d = displayDeadlines(for: year)
            .first(where: { $0.id == sel }) {
            top = d.hour - 0.25; bot = d.hour + 0.25
        } else {
            return
        }
        scrollTimelineTo(topHour: top, botHour: bot)
    }

    /// Glide `tlScroll` so the hour range [topHour, botHour] fits in the timeline, preferring to show the
    /// TOP when the range is taller than the viewport. Animated (anim.tlScrollTween) — never teleports.
    private func scrollTimelineTo(topHour: CGFloat, botHour: CGFloat) {
        let tl = timelineInfo(snapshot())
        guard tl.hourH > 0 else { return }
        let cellTop = topHour * tl.hourH, cellBot = botHour * tl.hourH
        let viewH = tl.tlBottom - tl.tlTop
        var s = anim.tlScrollTween?.to ?? tlScroll
        if s < cellBot - viewH {
            s = cellBot - viewH
        } // bring the bottom into view…
        if s > cellTop {
            s = cellTop
        } // …but prefer the top if the range is tall
        s = clamp(s, 0, tl.maxScroll)
        if abs(s - tlScroll) < 0.5 {
            return
        }
        anim.tlScrollTween = Tween(from: tlScroll, to: s, start: Date(), duration: Motion.tlScrollDur, ease: easeInOut)
    }

    /// Glide the timeline scroll so the block cursor's hour cell is fully on screen (week/day view).
    func ensureHourVisible() {
        let g = snapshot()
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return }
        let cellTop = cursor.blockHour * tl.hourH, cellBot = cellTop + tl.hourH // content-space (pre-scroll)
        let viewH = tl.tlBottom - tl.tlTop
        var s = anim.tlScrollTween?.to ?? tlScroll // head toward the in-flight target if any
        if s > cellTop {
            s = cellTop
        } // cell would clip above → bring to top
        if s < cellBot - viewH {
            s = cellBot - viewH
        } // cell below the fold → scroll up
        s = clamp(s, 0, tl.maxScroll)
        if abs(s - tlScroll) < 0.5 {
            return
        }
        anim.tlScrollTween = Tween(from: tlScroll, to: s, start: Date(), duration: Motion.tlScrollDur, ease: easeInOut)
    }

    /// ── Clipboard: copy / cut / paste ──────────────────────────────────────────────
    /// A copied/cut event. `move` is present only for CUT — a full-fidelity move that carries recurrence,
    /// promotion, and per-occurrence notes so paste reproduces the whole thing. A plain copy has move==nil
    /// and pastes as a single isolated event (repeat/promotion dropped).
    public struct ClipPayload: Codable, Sendable {
        public var kind: String // ItemKind rawValue: "timed" | "band" | "deadline"
        public var title: String
        public var color: String
        public var notes: String
        public var tags: [String]
        public var durationHours: CGFloat // timed span
        public var spanDays: Int // band length (endDay - startDay)
        public var move: MovePayload?
    }

    public struct MovePayload: Codable, Sendable {
        public var repeatJSON: String?
        public var promoteTrack: Int?
        public var occurrenceNotes: [String: String]?
        public var baseYear: Int, baseMonth: Int, baseDay: Int // the source's date → the move's offset origin
    }

    /// True when a box may be CUT: only a base/source box (no occurrence `@`, promoted `~p`, or segment
    /// `#seg` marker) that isn't imported (read-only). Cutting the SOURCE of a recurring series moves the
    /// whole series in one step; a ghost occurrence / promoted mirror / imported event is not cuttable.
    public func cutEligible(_ boxId: String) -> Bool {
        sourceId(of: boxId) == boxId && !isImported(boxId)
    }

    /// Build a clipboard payload from a selected box. `full` (cut) captures recurrence + promotion + per-
    /// occurrence notes so paste reproduces the whole thing; a copy captures only title/color/notes/tags.
    /// Resolves through `sourceId`, so copying a ghost/promoted box copies its SOURCE's data.
    public func clipPayload(of boxId: String, full: Bool) -> ClipPayload? {
        let sid = sourceId(of: boxId)
        let kind: String, title: String, color: String
        var dur: CGFloat = 1, span = 0, by = year, bm = focus, bd = 1
        if let e = event(sid) {
            kind = "timed"; title = e.title; color = colorOverride(sid) ?? e.color; dur = max(
                0.25,
                e.endHour - e.startHour
            ); by = e.year; bm = e.month; bd = e.day
        } else if let b = band(sid) {
            kind = "band"; title = b.title; color = colorOverride(sid) ?? b.color; span = max(
                0,
                b.endDay - b.startDay
            ); by = b.year; bm = b.month; bd = b.startDay
        } else if let d = deadline(sid) {
            kind = "deadline"; title = d.title; color = colorOverride(sid) ?? d.color; by = d.year; bm = d.month; bd = d
                .day
        } else {
            return nil
        }
        var move: MovePayload? = nil
        if full {
            let rf = items.richById[sid]
            move = MovePayload(repeatJSON: rf?.repeatJSON, promoteTrack: rf?.promoteTrack,
                               occurrenceNotes: rf?.occurrenceNotes, baseYear: by, baseMonth: bm, baseDay: bd)
        }
        return ClipPayload(kind: kind, title: title, color: color, notes: notes(sid), tags: richTags(sid),
                           durationHours: dur, spanDays: span, move: move)
    }

    /// Paste the clipboard at the active cursor (keyboard block/band cursor, else the mouse pointer),
    /// kind-gated: timed/deadline drop onto the week/day hourly timeline, bands onto the month band lanes.
    /// Returns the new id, or nil when there's no valid target for that kind. One undo step; selects it.
    @discardableResult
    public func paste(_ clip: ClipPayload) -> String? {
        switch clip.kind {
        case "timed", "deadline":
            guard let t = timelinePasteTarget() else { return nil }
            let delta = clip.move.map { dayDiff($0.baseYear, $0.baseMonth, $0.baseDay, t.year, t.month, t.day) } ?? 0
            beginTxn()
            let id = "new-\(UUID().uuidString)"
            if clip.kind == "timed" {
                let d = max(0.25, clip.durationHours)
                let start = max(0, min(24 - d, snap(t.hour, 30)))
                items.events.append(TimedEvent(
                    id: id,
                    year: t.year,
                    month: t.month,
                    day: t.day,
                    startHour: start,
                    endHour: start + d,
                    title: clip.title,
                    color: clip.color,
                    anchorTz: anchorNow
                ))
            } else {
                let hour = max(0, min(23.75, snap(t.hour, 30)))
                items.deadlines.append(Deadline(
                    id: id,
                    year: t.year,
                    month: t.month,
                    day: t.day,
                    hour: hour,
                    title: clip.title,
                    color: clip.color,
                    anchorTz: anchorNow
                ))
            }
            items.richById[id] = pasteRich(clip, newId: id, delta: delta)
            selectedId = id; commitTxn()
            return id
        case "band":
            guard let t = bandPasteTarget() else { return nil }
            let end = min(daysInMonth(t.year, t.month), t.startDay + max(0, clip.spanDays))
            let delta = clip.move
                .map { dayDiff($0.baseYear, $0.baseMonth, $0.baseDay, t.year, t.month, t.startDay) } ?? 0
            beginTxn()
            let id = "new-\(UUID().uuidString)"
            items.bands.append(BandEvent(
                id: id,
                year: t.year,
                month: t.month,
                track: t.track,
                startDay: t.startDay,
                endDay: end,
                title: clip.title,
                color: clip.color
            ))
            items.richById[id] = pasteRich(clip, newId: id, delta: delta)
            selectedId = id; commitTxn()
            return id
        default: return nil
        }
    }

    /// Paste at an EXPLICIT timeline slot — the event menu's "Paste Here" (timed/deadline
    /// clips only). No snapping: the pasted item starts exactly at `hour`.
    @discardableResult
    public func paste(_ clip: ClipPayload, atYear y: Int, month m: Int, day d: Int, hour: CGFloat) -> String? {
        guard clip.kind == "timed" || clip.kind == "deadline" else { return nil }
        let delta = clip.move.map { dayDiff($0.baseYear, $0.baseMonth, $0.baseDay, y, m, d) } ?? 0
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        if clip.kind == "timed" {
            let dur = max(0.25, clip.durationHours)
            let start = max(0, min(24 - dur, hour))
            items.events.append(TimedEvent(id: id, year: y, month: m, day: d, startHour: start,
                                           endHour: start + dur, title: clip.title, color: clip.color,
                                           anchorTz: anchorNow))
        } else {
            items.deadlines.append(Deadline(id: id, year: y, month: m, day: d, hour: max(0, min(23.75, hour)),
                                            title: clip.title, color: clip.color, anchorTz: anchorNow))
        }
        items.richById[id] = pasteRich(clip, newId: id, delta: delta)
        selectedId = id; commitTxn()
        return id
    }

    /// "Paste Here" on a clicked TIMED event box: land the clip exactly at that box's start time
    /// (occurrence-aware — a ghost pastes on its own day, not the series base).
    @discardableResult
    public func pasteHere(_ clip: ClipPayload, on boxId: String) -> String? {
        let src = sourceId(of: boxId)
        guard let e = event(src) else { return nil }
        let day = occurrenceStart(of: boxId) ?? YMD(e.year, e.month, e.day)
        return paste(clip, atYear: day.year, month: day.month, day: day.day, hour: e.startHour)
    }

    private func pasteRich(_ clip: ClipPayload, newId: String, delta: Int) -> RichFields {
        // A copy carries no `move` → notes+tags only; a cut carries recurrence/promotion/occ-notes, with
        // the recurrence dates and occurrence-note keys shifted by the move's day offset ("preserving offset").
        RichFields(notes: clip.notes.isEmpty ? nil : clip.notes,
                   tags: clip.tags,
                   repeatJSON: clip.move.flatMap { shiftedRepeat($0.repeatJSON, byDays: delta) },
                   promoteTrack: clip.move?.promoteTrack,
                   source: "manual",
                   occurrenceNotes: clip.move
                       .flatMap { shiftedOccNotes($0.occurrenceNotes, newId: newId, byDays: delta) })
    }

    /// Timeline (week/day) paste target — the keyboard block cursor if it's active, else the mouse pointer.
    /// nil unless we're on an hourly timeline (week/day view / a pointer over the timeline).
    private func timelinePasteTarget() -> (year: Int, month: Int, day: Int, hour: CGFloat)? {
        if cursor.keyboardActive {
            guard level(z) >= 2 else { return nil }
            let day = level(z) == 2 ? cursor.blockDay : daily.dom
            return (year, focus, day, cursor.blockHour)
        }
        guard let p = pointerPos, let s = createSpot(at: p, snapshot()) else { return nil }
        return (s.year, s.month, s.day, s.anchor)
    }

    /// Band paste target — the keyboard band cursor if active, else the mouse pointer over a band lane.
    private func bandPasteTarget() -> (year: Int, month: Int, track: Int, startDay: Int)? {
        if cursor.keyboardActive {
            guard cursor.bandCursorActive else { return nil }
            let m = level(z) == 0 ? cursor.blockMonth : focus
            return (year, m, cursor.bandCurTrack, min(daysInMonth(year, m), max(1, cursor.blockDay)))
        }
        guard let p = pointerPos else { return nil }
        let g = snapshot()
        for m in candidateBandMonths(p, g) {
            let f = frameFor(m, g)
            guard f.trackH > 0, f.dayW > 0, p.y >= f.bandY, p.y < f.bandY + 4 * f.trackH else { continue }
            let track = max(0, min(3, Int((p.y - f.bandY) / f.trackH)))
            let day = max(1, min(daysInMonth(year, m), Int((p.x - f.x0) / f.dayW) + 1))
            return (year, m, track, day)
        }
        return nil
    }

    private func shiftedRepeat(_ json: String?, byDays delta: Int) -> String? {
        guard var r = Repeat.parse(json) else { return nil }
        if delta != 0 {
            r.until = r.until.map { shiftDateString($0, delta) }
            r.exdates = r.exdates?.map { shiftDateString($0, delta) }
        }
        return (try? JSONEncoder().encode(r)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func shiftDateString(_ s: String, _ delta: Int) -> String { // "YYYY-MM-DD" (1-based month)
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return s }
        let nd = addDays(p[0], p[1] - 1, p[2], delta)
        return String(format: "%04d-%02d-%02d", nd.0, nd.1 + 1, nd.2)
    }

    private func shiftedOccNotes(_ notes: [String: String]?, newId: String, byDays delta: Int) -> [String: String]? {
        guard let notes, !notes.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (key,
             val) in notes { // key = "sourceId@Y-M-D" (occKey month is 0-based); sourceId has no '@' (non-imported
            // base)
            let comps = key.components(separatedBy: "@")
            guard comps.count == 2, let d = Optional(comps[1].split(separator: "-").compactMap { Int($0) }),
                  d.count == 3 else { out[key] = val; continue }
            let nd = addDays(d[0], d[1], d[2], delta)
            out["\(newId)@\(nd.0)-\(nd.1)-\(nd.2)"] = val
        }
        return out
    }
}
