// Keyboard navigation over EVENTS + the day-view dashboard stops: arrow-key movement between
// visible event boxes (with one-step reverse memory), nudge/resize of the selection, and the
// TODO/NOTE dashboard cursor dispatched to the WebView bridge. Split from CalendarEngine.swift.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// ── Day-view dashboard keyboard stops (TODO / NOTE) — dispatched to the WebView bridge ─────────
    /// ⌘B / ⌘E at day view: land keyboard focus directly on a dashboard stop. These stops are NOT
    /// part of the Tab cycle (their interactions are self-contained; Tab exits back to the
    /// timeline's block cursor — see navTab). ⌘E goes straight into the markdown editor.
    public func dashFocusEntry(_ stop: DashStop) {
        guard level(z) == 3 else { return }
        let wasKeyboard = cursor.keyboardActive // ring policy below — read BEFORE entering
        wake(); enterKeyboardMode()
        if selectedId != nil {
            deselect()
        }
        cursor.dashStop = stop
        cursor.dashNoteEditing = false // ⌘B during note editing: the TODO state, not the editor's
        onDashCommand?(.focus(stop))
        if stop == .note {
            cursor.dashNoteEditing = true
            // Focus the live editor. If keyboard mode was already on (a ring was showing), keep
            // the dashed ring around the editor too — the focus visibly MOVED there.
            onDashCommand?(.editNote(ring: wasKeyboard))
        }
    }

    /// Drop any dashboard keyboard focus from outside the engine (⌘J switches to the PROJ tab,
    /// which has no keyboard stop yet — a lingering TODO/NOTE ring would target hidden content).
    public func dashExitFocus() {
        clearDashStop()
    }

    /// Move the TODO row cursor (↑/↓). No-op unless the TODO stop is focused.
    public func dashMove(_ d: Int) {
        guard cursor.dashStop == .todo else { return }; enterKeyboardMode(); onDashCommand?(.move(d))
    }

    /// Space/Enter on a dashboard stop: TODO → toggle the focused row; NOTE → focus the editor (edit mode).
    public func dashActivate() {
        enterKeyboardMode()
        switch cursor.dashStop {
        case .todo: onDashCommand?(.activate)
        case .note: cursor.dashNoteEditing = true; onDashCommand?(.activate)
        case nil: break
        }
    }

    /// Enter on the TODO stop → open the focused row's event (or fly to its daily note).
    public func dashOpen() {
        guard cursor.dashStop == .todo else { return }; enterKeyboardMode(); onDashCommand?(.open)
    }

    /// ←/→ on the TODO stop: fold / unfold the focused row's sub-tasks (no-op on a leaf row).
    public func dashFold(_ open: Bool) {
        guard cursor.dashStop == .todo else { return }; enterKeyboardMode(); onDashCommand?(.fold(open))
    }

    /// The note editor handed focus back (Esc or ⌘S in the WebView) → return to the NOTE ring.
    public func dashNoteExit() {
        guard cursor.dashStop == .note else { return }; cursor.dashNoteEditing = false; onDashCommand?(.focus(.note))
    }

    /// Drop any dashboard focus (leaving day view via Esc / ⌘−). Idempotent.
    func clearDashStop() {
        guard cursor.dashStop != nil else { return }
        cursor.dashStop = nil; cursor.dashNoteEditing = false; cursor.dashReturnEvent = nil; onDashCommand?(.focus(nil))
    }

    /// Land the block cursor on an event's earliest anchor (band → startDay; timed/deadline → day+hour).
    func setBlockToEventAnchor(_ id: String) {
        if let b = displayBands(for: year).first(where: { $0.id == id }) {
            cursor.blockMonth = b.month; cursor.blockDay = min(daysInMonth(b.year, b.month), max(1, b.startDay))
        } else if let e = displayEvents(for: year).first(where: { $0.id == id }) {
            cursor.blockMonth = e.month; cursor.blockDay = e.day; cursor.blockHour = e.startHour
        } else if let d = displayDeadlines(for: year).first(where: { $0.id == id }) {
            cursor.blockMonth = d.month; cursor.blockDay = d.day; cursor.blockHour = d.hour
        }
    }

    /// Carry-over: the nearest event to the block cursor, per view.
    func nearestEventToBlock() -> String? {
        switch level(z) {
        case 0: // year: a band in/near the cursor month, topmost lane
            return viewBands().min(by: {
                (abs($0.month - cursor.blockMonth), $0.track, $0.startDay) < (
                    abs($1.month - cursor.blockMonth),
                    $1.track,
                    $1.startDay
                )
            })?.id
        case 1: // month: a band covering/near the cursor day, topmost lane
            return viewBands().filter { $0.month == focus }
                .min(by: { (bandDayDist($0, cursor.blockDay), $0.track) < (bandDayDist($1, cursor.blockDay), $1.track)
                })?.id
        case 2, 3: // week/day: nearest timed/deadline on the day by hour, else a band covering it
            let d = level(z) == 2 ? cursor.blockDay : daily.dom
            let timeline = viewEvents().filter { $0.month == focus && $0.day == d }.map { ($0.id, $0.startHour) }
                + viewDeadlines().filter { $0.month == focus && $0.day == d }.map { ($0.id, $0.hour) }
            if let best = timeline
                .min(by: { abs($0.1 - cursor.blockHour) < abs($1.1 - cursor.blockHour) }) {
                return best.0
            }
            return viewBands().first { $0.month == focus && $0.startDay <= d && $0.endDay >= d }?.id
        default:
            return nil
        }
    }

    func bandDayDist(_ b: BandEvent, _ d: Int) -> Int {
        d < b.startDay ? b.startDay - d : (d > b.endDay ? d - b.endDay : 0)
    }

    func syncBlockVisible() {
        switch level(z) {
        case 0: ensureMonthVisible(cursor.blockMonth, animated: true)
        case 2, 3: ensureHourVisible()
        default: break
        }
    }

    // Plain-arrow navigation between events (event cursor). Day view: ↑/↓ step through the day's events
    // top-to-bottom (bands first, then timed/deadlines by time). Year/month/week use the 2-D focus
    // engine — a later increment.

    public func navigateEvent(_ dx: Int, _ dy: Int) {
        enterKeyboardMode()
        guard let sel = selectedId else { return }
        if level(z) == 3 {
            // Day view: ↑/↓ step by TIME row; ←/→ switch between side-by-side overlaps.
            if dy != 0 {
                let ids = dayEventOrder()
                guard !ids.isEmpty else { return }
                guard let i = ids.firstIndex(of: sel) else {
                    selectedId = ids[dy > 0 ? 0 : ids.count - 1]; ensureSelectedEventVisible(); return
                }
                var j = i + dy
                // Skip side-by-side colliders of the current TIMED event — same-time overlaps are reached
                // with ←/→, so ↑/↓ moves to the next DISTINCT time row (A/B at 10–11 → C at 11–12). General
                // over any number of colliders and partial overlaps; a no-move is left as-is (no clamp onto
                // a collider). Bands / deadlines aren't timed boxes, so they end the skip.
                let evs = viewEvents()
                if let cur = evs.first(where: { $0.id == sel }) {
                    while ids.indices.contains(j), let n = evs.first(where: { $0.id == ids[j] }),
                          n.startHour < cur.endHour, cur.startHour < n.endHour {
                        j += dy
                    }
                }
                if ids.indices.contains(j), j != i {
                    selectedId = ids[j]; ensureSelectedEventVisible()
                }
            } else if let n = focusFind(sel, dx, 0, rects: visibleEventRects()) { // overlaps → the adjacent column
                selectedId = n; ensureSelectedEventVisible()
            }
            return
        }
        // Week view: ←/→ first hops between side-by-side overlapping events (their real time-columns). Only
        // when there's no such neighbor in that direction does it fall through to day-to-day navigation —
        // so the timeline's columns are reachable without losing cross-day movement.
        if level(z) == 2, dx != 0, let n = sideBySideNeighbor(sel, dx) {
            selectedId = n; cursor.lastEventMove = nil; scrollToSelected(); return
        }
        // Year / month / week: the 2-D focus engine over LOGICAL rects (so off-screen events are reachable).
        // Event navigation may cross quarter boundaries in year view (only the band CURSOR is quarter-bound).
        let allRects = logicalRects()
        var rects = allRects
        // Week view: PREFER the visible week — neither a vertical nor a horizontal move should teleport to an
        // off-screen event in another week's column (focusFind's beam preference would otherwise pick a far,
        // same-time event over a near, in-view one). ↑/↓ additionally drops the current event's same-time
        // colliders (those are reached with ←/→). ←/→ falls back to the full set below when the visible week
        // offers nothing in that direction (e.g. you're on the last visible day) — so you can still cross weeks.
        if level(z) == 2 {
            if let win = visibleWeekDOMRange() {
                // Keep `sel` regardless (focusFind needs its anchor); drop other-week events.
                rects
                    .removeAll {
                        $0
                            .id != sel &&
                            ($0.rect.maxX <= CGFloat(win.lowerBound) || $0.rect.minX >= CGFloat(win.upperBound + 1))
                    }
            }
            if dy != 0 {
                let colliders = timedColliderIds(of: sel)
                if !colliders.isEmpty {
                    rects.removeAll { colliders.contains($0.id) }
                }
            }
        }
        let next: String?
        if let m = cursor.lastEventMove, m.to == sel, m.dx == -dx, m.dy == -dy {
            next = m.from // exact inverse → return to origin
        } else if let n = focusFind(sel, dx, dy, rects: rects) {
            next = n; cursor.lastEventMove = (sel, dx, dy, n) // best within the (visible-week) candidate set
        } else if level(z) == 2, dx != 0, let n = focusFind(sel, dx, dy, rects: allRects) {
            next = n; cursor.lastEventMove = (sel, dx, dy, n) // nothing left/right in the visible week → cross weeks
        } else {
            next = nil
        }
        if let n = next, n != sel {
            selectedId = n; scrollToSelected()
        }
    }

    /// On-screen rects (geometry space) of every visible event box — bands + timed + deadlines.
    private func visibleEventRects() -> [(id: String, rect: CGRect)] {
        let g = snapshot()
        // Month/week/day: only the FOCUS month's events are navigable — otherwise ↑ from the top lane in
        // month view would jump to an off-screen adjacent-month band. Year view keeps all months (its
        // ↑/↓ crosses months by design).
        let sameMonthOnly = level(z) != 0
        let dayOnly = level(z) == 3 ? daily.dom : nil // day view: only the shown day's boxes are on screen
        var out: [(String, CGRect)] = []
        for b in viewBands() where !b.id.isEmpty {
            if sameMonthOnly && b.month != focus {
                continue
            }
            if let d = dayOnly, !(b.startDay <= d && b.endDay >= d) {
                continue
            }
            if let r = bandEventRect(b, g, anim: g.monthAnim) {
                out.append((b.id, CGRect(x: r.x, y: r.y, width: r.w, height: r.h)))
            }
        }
        if z >= 1.5 {
            let tl = timelineInfo(g)
            let evs = viewEvents().filter { $0.month == focus && (dayOnly == nil || $0.day == dayOnly) }
            var byDay: [Int: [TimedEvent]] = [:]
            for e in evs {
                byDay[e.day, default: []].append(e)
            }
            for e in evs {
                let layout = layoutDay(byDay[e.day] ?? [])[e.id]
                if let r = eventRect(e, year, focus, tl, g.vp, layout) {
                    out.append((
                        e.id,
                        CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                    ))
                }
            }
            for d in viewDeadlines() where d.month == focus && (dayOnly == nil || d.day == dayOnly) {
                if let pos = deadlinePos(d, g) {
                    out.append((
                        d.id,
                        CGRect(x: pos.x, y: pos.y - 9, width: pos.w, height: 18)
                    ))
                }
            }
        }
        return out
    }

    /// FocusFinder: the best event in direction (dx,dy) from `currentId`, scored over the given rect list.
    /// Edge distances, beam-preference, K≈13 major-axis weight — off-axis allowed but heavily penalized
    /// (see docs/prompts/keyboard_control.md). Callers pass LOGICAL rects (year/month/week — scroll-stable,
    /// so off-screen events are reachable) or geometric rects (day-view overlaps).
    private func focusFind(_ currentId: String, _ dx: Int, _ dy: Int, rects: [(id: String, rect: CGRect)]) -> String? {
        guard let cur = rects.first(where: { $0.id == currentId })?.rect else { return nil }
        let K: CGFloat = 13, beamPenalty: CGFloat = 1_000_000
        var best: String?; var bestScore = CGFloat.greatestFiniteMagnitude
        for (id, r) in rects where id != currentId {
            let major: CGFloat, minor: CGFloat, beam: Bool
            if dy != 0 { // vertical move
                let centerAhead = dy > 0 ? r.midY - cur.midY : cur.midY - r.midY
                guard centerAhead > 0.5 else { continue }
                major = max(0, dy > 0 ? r.minY - cur.maxY : cur.minY - r.maxY)
                minor = gap(cur.minX, cur.maxX, r.minX, r.maxX)
                beam = r.maxX > cur.minX && r.minX < cur.maxX
            } else { // horizontal move
                let centerAhead = dx > 0 ? r.midX - cur.midX : cur.midX - r.midX
                guard centerAhead > 0.5 else { continue }
                major = max(0, dx > 0 ? r.minX - cur.maxX : cur.minX - r.maxX)
                minor = gap(cur.minY, cur.maxY, r.minY, r.maxY)
                beam = r.maxY > cur.minY && r.minY < cur.maxY
            }
            let score = K * major * major + minor * minor + (beam ? 0 : beamPenalty)
            if score < bestScore {
                bestScore = score; best = id
            }
        }
        return best
    }

    /// Edge distance between two 1-D spans [a0,a1] and [b0,b1] (0 if they overlap).
    private func gap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        b1 < a0 ? a0 - b1 : (b0 > a1 ? b0 - a1 : 0)
    }

    /// The nearest TIMED event on the SAME day whose time overlaps the selection — i.e. a genuinely
    /// side-by-side box in its own layout column — in the horizontal direction `dx`. Uses the real
    /// per-column geometry (`eventRect` places overlaps at `col * subW`), so partial overlaps (10–11 vs
    /// 10–12) and 3+ columns all resolve correctly. nil when the selection isn't a timed box or has no such
    /// neighbor in that direction — the week-view caller then falls back to day-to-day navigation.
    private func sideBySideNeighbor(_ sel: String, _ dx: Int) -> String? {
        guard dx != 0, let day = selectedEventDay(sel) else { return nil }
        let g = snapshot()
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return nil }
        let dayEvents = viewEvents().filter { $0.month == focus && $0.day == day }
        let layout = layoutDay(dayEvents)
        var rects: [String: CGRect] = [:]
        for e in dayEvents {
            if let r = eventRect(e, year, focus, tl, g.vp, layout[e.id]) {
                rects[e.id] = r
            }
        }
        guard let cur = rects[sel] else { return nil } // selection must be a timed box on this day
        var best: String?; var bestAhead = CGFloat.greatestFiniteMagnitude
        for (id, r) in rects where id != sel {
            guard r.maxY > cur.minY, r.minY < cur.maxY else { continue } // must overlap in TIME (side-by-side)
            let ahead = dx > 0 ? r.midX - cur.midX : cur.midX - r.midX
            guard ahead > 0.5, ahead < bestAhead else { continue }
            bestAhead = ahead; best = id
        }
        return best
    }

    /// The day-of-month window (7 days) currently visible in WEEK view, matching `ensureDayVisibleWeek`'s
    /// geometry. `↑/↓` restricts to this window so a vertical move can't jump to an off-screen event in
    /// another week (a different day column); `←/→` still crosses weeks (it shifts the window). nil unless
    /// in week view.
    private func visibleWeekDOMRange() -> ClosedRange<Int>? {
        guard level(z) == 2 else { return nil }
        let wk = (anim.weekTween?.to ?? week).rounded()
        let startDOM = 1 - CGFloat(firstDOW(year, focus)) + wk * 7
        let lo = Int(startDOM.rounded())
        return lo ... (lo + 6)
    }

    /// The ids of the timed events that COLLIDE (overlap in time) with `sel` on the same day — the boxes
    /// laid out side-by-side with it. `↑/↓` excludes these so a vertical move steps to the next time row
    /// rather than to a same-time neighbour (which `←/→` reaches). Empty if `sel` isn't a timed box.
    private func timedColliderIds(of sel: String) -> Set<String> {
        guard let cur = viewEvents().first(where: { $0.id == sel }) else { return [] }
        var out = Set<String>()
        for e in viewEvents() where e.id != sel && e.month == cur.month && e.day == cur.day
            && e.startHour < cur.endHour && cur.startHour < e.endHour {
            out.insert(e.id)
        }
        return out
    }

    /// LOGICAL rects for the focus engine — scroll-INDEPENDENT, so off-screen events are still reachable
    /// (year: bands stacked month×lane, x = day-span; week: bands at y=lane, timeline events below at
    /// y = 4 + hour; month: bands at y=lane). x is day-of-month, y is lanes/hours.
    private func logicalRects() -> [(id: String, rect: CGRect)] {
        func bandRect(_ b: BandEvent, yBase: CGFloat) -> (String, CGRect) {
            (b.id, CGRect(x: CGFloat(b.startDay), y: yBase + CGFloat(b.track),
                          width: CGFloat(b.endDay - b.startDay + 1), height: 1))
        }
        var out: [(String, CGRect)] = []
        switch level(z) {
        case 0: // year: every month's bands, lanes stacked across months
            for b in viewBands() {
                out.append(bandRect(b, yBase: CGFloat(b.month * 4)))
            }
        case 1: // month: the focus month's bands
            for b in viewBands() where b.month == focus {
                out.append(bandRect(b, yBase: 0))
            }
        case 2: // week: focus-month bands (lanes 0–3) + timeline events below (y = 4 + hour)
            for b in viewBands() where b.month == focus {
                out.append(bandRect(b, yBase: 0))
            }
            for e in viewEvents() where e.month == focus {
                out.append((
                    e.id,
                    CGRect(x: CGFloat(e.day), y: 4 + e.startHour, width: 1, height: max(0.25, e.endHour - e.startHour))
                ))
            }
            for d in viewDeadlines() where d.month == focus {
                out.append((d.id, CGRect(x: CGFloat(d.day), y: 4 + d.hour, width: 1, height: 0.25)))
            }
        default: break
        }
        return out
    }

    /// Scroll the view so the SELECTED event stays visible: year → the band's month; week → shift the
    /// 7-day focus window to the event's day (horizontal) AND scroll the timeline to its hours; day →
    /// the timeline hours. (Month view shows the whole month — no scroll needed.)
    func scrollToSelected() { // internal: +Search's revealAndSelect uses it
        guard let sel = selectedId else { return }
        let isBand = displayBands(for: year).contains { $0.id == sel }
        switch level(z) {
        case 0:
            if let b = displayBands(for: year).first(where: { $0.id == sel }) {
                ensureMonthVisible(
                    b.month,
                    animated: true
                )
            }
        case 2:
            if let day = selectedEventDay(sel) {
                ensureDayVisibleWeek(day)
            } // week window follows horizontally
            if !isBand {
                ensureSelectedEventVisible()
            }
        default:
            if !isBand {
                ensureSelectedEventVisible()
            }
        }
    }

    private func selectedEventDay(_ id: String) -> Int? {
        if let b = displayBands(for: year).first(where: { $0.id == id }) {
            return b.startDay
        }
        if let e = displayEvents(for: year).first(where: { $0.id == id }) {
            return e.day
        }
        if let d = displayDeadlines(for: year).first(where: { $0.id == id }) {
            return d.day
        }
        return nil
    }

    /// The current day's DISPLAY boxes in top-to-bottom order: bands (by lane) — including recurrence
    /// ghosts and promoted bars — then timed + deadline boxes by time. Every box is a distinct item;
    /// duplicate ids (a promoted-recurring box that is both) are collapsed once (band wins, listed first).
    private func dayEventOrder() -> [String] {
        let d = daily.dom
        var ids = viewBands()
            .filter { $0.month == focus && $0.startDay <= d && $0.endDay >= d }
            .sorted { $0.track < $1.track }.map(\.id)
        let timed = viewEvents().filter { $0.month == focus && $0.day == d }.map { ($0.id, $0.startHour) }
        let ddls = viewDeadlines().filter { $0.month == focus && $0.day == d }.map { ($0.id, $0.hour) }
        ids += (timed + ddls).sorted { $0.1 < $1.1 }.map(\.0)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Keyboard resize — grow/shrink the SELECTED event with ⇧+arrows, keeping its START fixed.
    /// Band: ⇧←/⇧→ change the END day (`dx`), clamped to [startDay, month end]. Timed: ⇧↑/⇧↓ change the
    /// END hour (`dy`: -1 shrink, +1 extend) by 15 min, clamped to [start + 15 min, 24h]. Deadlines have
    /// no duration → no resize.
    public func resizeSelected(_ dx: Int, _ dy: Int) {
        guard let sid = selectedId else { return }
        let id = sourceId(of: sid)
        if let b = band(id), dx != 0 {
            let ne = max(b.startDay, min(daysInMonth(b.year, b.month), b.endDay + dx))
            guard ne != b.endDay else { return }
            updateBand(id) { $0.endDay = ne }
        } else if let e = event(id), dy != 0 {
            let ne = max(e.startHour + 0.25, min(24, e.endHour + CGFloat(dy) * 0.25))
            guard ne != e.endHour else { return }
            update(id) { $0.endHour = ne }
        }
    }

    /// Keyboard nudge — move the SELECTED event vertically (cmd+up / cmd+down). `dir` = -1 (up) or +1
    /// (down). Bands move across the 4 lanes; timed/deadline move by 15 minutes. Moves are clamped: a
    /// nudge that would leave the valid range (lane 0…3, or the 0…24h day) does nothing.
    public func nudgeVertical(_ dir: Int) {
        guard let sid = selectedId else { return }
        let id = sourceId(of: sid)
        // A selected PROMOTED ghost band: ⌘↑/↓ re-homes the promotion lane on the SOURCE event —
        // NOT the source's time (the ghost is a lane mirror; its vertical axis IS the lane).
        if sid.hasSuffix(PROMOTED_SUFFIX) {
            guard let cur = items.richById[overlayKey(id)]?.promoteTrack else { return }
            let t = cur + dir
            guard (0 ... 3).contains(t) else { return }
            setPromoteTrack(id, t)
            return
        }
        if let b = band(id) {
            let t = b.track + dir // -1 = up a lane, +1 = down a lane
            guard t >= 0, t <= 3 else { return }
            updateBand(id) { $0.track = t }
        } else if let e = event(id) {
            let step = CGFloat(dir) * 0.25 // 15 min; -1 = earlier (up), +1 = later (down)
            let ns = e.startHour + step, ne = e.endHour + step
            guard ns >= 0, ne <= 24 else { return } // keep the whole event inside the day
            update(id) { $0.startHour = ns; $0.endHour = ne }
        } else if let d = deadline(id) {
            let nh = d.hour + CGFloat(dir) * 0.25
            guard nh >= 0, nh <= 24 else { return }
            updateDeadline(id) { $0.hour = nh }
        }
    }

    /// Keyboard nudge — move the SELECTED event horizontally by a day (cmd+left / cmd+right). Bands shift
    /// the whole span (start fixed relative to end); they CANNOT cross the month boundary. Timed/deadlines
    /// move their date by a day (across month/year). Follows with a scroll so it stays visible.
    public func nudgeHorizontal(_ dir: Int) {
        enterKeyboardMode()
        guard let sid = selectedId else { return }
        let id = sourceId(of: sid)
        if let b = band(id) {
            let ns = b.startDay + dir, ne = b.endDay + dir
            guard ns >= 1, ne <= daysInMonth(b.year, b.month) else { return } // stay within the month
            updateBand(id) { $0.startDay = ns; $0.endDay = ne }
        } else if let e = event(id) {
            let (y, m, dd) = addDays(e.year, e.month, e.day, dir)
            update(id) { $0.year = y; $0.month = m; $0.day = dd }
        } else if let d = deadline(id) {
            let (y, m, dd) = addDays(d.year, d.month, d.day, dir)
            updateDeadline(id) { $0.year = y; $0.month = m; $0.day = dd }
        }
        scrollToSelected()
    }

    /// Add `delta` days to a (year, 0-based month, day), rolling months/years correctly.
    func addDays(_ y: Int, _ m0: Int, _ d: Int,
                 _ delta: Int) -> (Int, Int, Int) { // internal: used across the engine's extension files
        var c = DateComponents(); c.year = y; c.month = m0 + 1; c.day = d
        let cal = Calendar(identifier: .gregorian)
        guard let base = cal.date(from: c), let nd = cal.date(byAdding: .day, value: delta, to: base) else { return (
            y,
            m0,
            d
        ) }
        let x = cal.dateComponents([.year, .month, .day], from: nd)
        return (x.year ?? y, (x.month ?? 1) - 1, x.day ?? d)
    }

    /// Whole-day difference (b − a) between two calendar dates (0-based months), DST-agnostic. Used to make
    /// mouse resize/create day-column aware so a drag into an adjacent day spans midnight rather than
    /// collapsing (the pointer's hour is relative to whichever day column it's over).
    func dayDiff(_ ay: Int, _ am: Int, _ ad: Int, _ by: Int, _ bm: Int,
                 _ bd: Int) -> Int { // internal: used across extension files
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let a = cal.date(from: DateComponents(year: ay, month: am + 1, day: ad)),
              let b = cal.date(from: DateComponents(year: by, month: bm + 1, day: bd)) else { return 0 }
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// Open the inline title editor for a band, positioned over its rect (geometry space). The click-a-
    /// selected-band gesture and the keyboard "Enter → edit title" (via `editSelectedBand`) both route here.
    public func editBand(_ id: String) {
        let g = snapshot()
        guard let b = items.bands.first(where: { $0.id == id }),
              let r = bandEventRect(b, g, anim: g.monthAnim) else { return }
        // Let the field extend right to the content edge (like the title's overflow), not
        // just the box width.
        onEditBand?(id, CGRect(x: r.x, y: r.y, width: max(r.w, g.vp.w - r.x), height: r.h))
    }

    /// Tooltip when the cursor is over a fully-overlapping-events warning sign (top-left of
    /// the kept band). Fully overlapping = same month/track/startDay/endDay.
    public func bandWarningTooltip(at p: CGPoint) -> String? {
        var groups: [String: [BandEvent]] = [:]
        for b in items.bands {
            groups["\(b.month)-\(b.track)-\(b.startDay)-\(b.endDay)", default: []].append(b)
        }
        let g = snapshot()
        for (_, arr) in groups where arr.count > 1 {
            guard let keep = arr.max(by: { $0.id < $1.id }),
                  let r = bandEventRect(keep, g, anim: g.monthAnim) else { continue }
            if CGRect(x: r.x, y: r.y, width: 18, height: 18).contains(p) {
                return "Fully overlapping events"
            }
        }
        return nil
    }

    public func setBandTitle(_ id: String, _ title: String) {
        guard let i = items.bands.firstIndex(where: { $0.id == id }), items.bands[i].title != title else { return }
        beginTxn(); items.bands[i].title = title; scheduleCommit()
    }

    public func event(_ id: String) -> TimedEvent? {
        items.events.first { $0.id == id } ?? imported.events
            .first { $0.id == id }
    }

    public func band(_ id: String) -> BandEvent? {
        items.bands.first { $0.id == id } ?? imported.bands
            .first { $0.id == id }
    }

    public func deadline(_ id: String) -> Deadline? {
        items.deadlines.first { $0.id == id }
    }

    /// Whether a source id still backs a real item — used by the UI to close a drawer whose event just
    /// vanished (e.g. deleted in Apple Calendar, then re-imported; or removed by an iCloud remote change).
    public func itemExists(_ id: String) -> Bool {
        event(id) != nil || band(id) != nil || deadline(id) != nil
    }
}

/// Cursor-domain cycling + block/band cursors + keyboard zoom (moved from CalendarEngine.swift).
extension CalendarEngine {
    // ── Tab cycling between cursors (block ⇄ event; band cursor is a later increment) ──────────────
    // One-step inverse memory: the last block⇄event pairing. If a Tab is the exact inverse of the last,
    // we restore the remembered side instead of re-deriving via carry-over — so Tab then ⇧Tab round-trips
    // exactly even where carry-over is lossy (see docs/prompts/keyboard_control.md).
    private enum NavDomain { case block, band, event }
    private var currentDomain: NavDomain {
        selectedId != nil ? .event : (cursor.bandCursorActive ? .band : .block)
    }

    /// Tab / ⇧Tab cycle the cursor DOMAIN: block ⇄ event (⇧Tab reverses). The band lanes are a
    /// SUB-STATE of the block cursor (entered/left by arrows — see blockArrow/bandArrow), not a
    /// Tab stop of their own. Each step carries the position over so the cycle round-trips.
    public func tabCursor(_ forward: Bool) {
        enterKeyboardMode()
        // Month view inserts 4 track-name stops between Event and Block (after Event, before wrapping).
        let inMonth = level(z) == 1
        if let t = cursor.trackNameCursor {
            if forward {
                if t < 3 {
                    cursor.trackNameCursor = t + 1
                } else {
                    cursor.trackNameCursor = nil
                }
            } // track 3 → block
            else if t > 0 {
                cursor.trackNameCursor = t - 1
            } else { // track 0 → event (⇧Tab); no event in view → skip the empty stop to block
                cursor.trackNameCursor = nil
                if let eid = nearestEventToBlock() {
                    selectedId = eid; scrollToSelected()
                }
            }
            return
        }
        if inMonth {
            if selectedId != nil && forward {
                deselect(); cursor.trackNameCursor = 0; return
            } // event → track 0
            if currentDomain != .event && !forward {
                cursor.trackNameCursor = 3; return
            } // block ← track 3
        }
        // The dashboard stops (TODO / NOTE) are OUT of the Tab cycle — ⌘B/⌘E own them
        // (dashFocusEntry) and their interactions are self-contained. Any Tab while one holds
        // focus recenters onto the timeline's block cursor.
        if cursor.dashStop != nil {
            clearDashStop()
            cursor.blockDay = daily.dom
            return
        }
        if currentDomain == .event { // event → its earliest anchor (with inverse memory)
            if let sel = selectedId {
                if let link = tabLink,
                   link
                   .eventId ==
                   sel {
                    cursor.blockMonth = link.month; cursor.blockDay = link.day; cursor.blockHour = link.hour
                } else {
                    setBlockToEventAnchor(sel)
                }
                tabLink = (cursor.blockMonth, cursor.blockDay, cursor.blockHour, sel)
            }
            selectedId = nil; cursor.bandCursorActive = false
            syncBlockVisible()
        } else { // block (or its lane sub-state) → the band under the cell, else the nearest
            // event (with inverse memory); truly nothing in view → skip the empty event stop.
            let fromLane = cursor.bandCursorActive
            cursor.bandCursorActive = false
            if fromLane, let b = bandForCursor() {
                selectedId = b.id
            } else if let link = tabLink, link.month == cursor.blockMonth, link.day == cursor.blockDay,
                      abs(link.hour - cursor.blockHour) < 0.01, isVisibleEvent(link.eventId) {
                selectedId = link.eventId
            } else if let eid = nearestEventToBlock() {
                selectedId = eid; tabLink = (cursor.blockMonth, cursor.blockDay, cursor.blockHour, eid)
            } else {
                cursor.bandCursorActive = fromLane // stay put — there is no event stop to land on
                skipEventForward()
            }
        }
        // Scroll whatever event we landed on into view: a timed/deadline event above or below the
        // timeline viewport (week/day) glides into sight; a band scrolls to its month/day. (req 2)
        if selectedId != nil {
            scrollToSelected()
        }
    }

    /// Forward Tab reached the event stop but found nothing to select → advance to the stop that follows
    /// the (empty) event stop in this view, so Tab never lands on a dead event cursor: month → the first
    /// track-name stop; week/day/year → the block cursor (already the state here — the dashboard
    /// stops left the cycle; ⌘B/⌘E reach them directly).
    private func skipEventForward() {
        switch level(z) {
        case 1: cursor.trackNameCursor = 0
        default: break
        }
    }

    private func isVisibleEvent(_ id: String) -> Bool {
        viewBands().contains { $0.id == id } || viewEvents().contains { $0.id == id } || viewDeadlines()
            .contains { $0.id == id }
    }

    /// The band the band-cursor cell sits on: the band covering `(month, track, day)`, else the nearest
    /// band in that month. Shared by Tab (band→event) and Enter-to-select.
    private func bandForCursor() -> BandEvent? {
        let m = level(z) == 0 ? cursor.blockMonth : focus
        let hit = viewBands()
            .first {
                $0.month == m && $0.track == cursor.bandCurTrack && $0.startDay <= cursor.blockDay && $0
                    .endDay >= cursor
                    .blockDay
            }
        return hit ?? viewBands().filter { $0.month == m }
            .min(by: { (bandDayDist($0, cursor.blockDay), abs($0.track - cursor.bandCurTrack)) < (
                bandDayDist($1, cursor.blockDay),
                abs($1.track - cursor.bandCurTrack)
            ) })
    }

    /// Enter from the band cursor (any view) or the block cursor (week/day) → enter event-cursor mode on
    /// the relevant event: the band under the band cell, else the nearest event to the block cell. Keeps
    /// the one-step Tab memory in sync so a following ⇧Tab round-trips back to the originating cell.
    public func selectFromCursor() {
        enterKeyboardMode()
        if cursor.bandCursorActive {
            if let b = bandForCursor() {
                cursor.bandCursorActive = false; selectedId = b.id; scrollToSelected()
            }
        } else if cursor.trackNameCursor == nil, level(z) >= 2 { // block cursor — week/day only (per spec)
            if let eid = nearestEventToBlock() {
                selectedId = eid; tabLink = (
                    cursor.blockMonth,
                    cursor.blockDay,
                    cursor.blockHour,
                    eid
                ); ensureSelectedEventVisible()
            }
        }
    }

    /// A mouse move/click hides the keyboard cursor visual (state persists).
    public func enterMouseMode() {
        if cursor.keyboardActive {
            cursor.keyboardActive = false; wake()
        }
    }

    /// A dispatched nav/action key shows the keyboard cursor.
    public func enterKeyboardMode() {
        if !cursor.keyboardActive {
            cursor.keyboardActive = true; wake()
        }
    }

    /// Move the block cursor by an arrow. `dy`: up = -1, down = +1; `dx`: left = -1, right = +1.
    ///
    /// The band lanes are a SUB-STATE of the block cursor (one merged Tab stop), entered and left
    /// by arrows at each level's natural edge — see bandArrow for the exits:
    ///   · year  — → enters the month's lanes at the top-LEFT cell, ← at the top-RIGHT.
    ///   · month — ↓ from a day enters its TOP lane, ↑ enters its BOTTOM lane (a vertical ring).
    ///   · week/day — the day's vertical ring: ↑ from 12am enters the BOTTOM lane, ↓ from 11pm
    ///     enters the TOP lane.
    public func blockArrow(dx: Int, dy: Int) {
        enterKeyboardMode()
        switch level(z) {
        case 0: // year: up/down = month; left/right = into the month's band lanes
            if dy != 0 {
                let m = max(0, min(11, cursor.blockMonth + dy))
                if m != cursor.blockMonth {
                    cursor.blockMonth = m; ensureMonthVisible(m, animated: true)
                }
            }
            if dx != 0 {
                cursor.bandCursorActive = true; cursor.bandCurTrack = 0
                cursor.blockDay = dx > 0 ? 1 : daysInMonth(year, cursor.blockMonth)
            }
        case 1: // month: left/right = day; up/down = into the day's band lanes (vertical ring)
            if dx != 0 {
                let d = max(1, min(daysInMonth(year, focus), cursor.blockDay + dx))
                if d != cursor.blockDay {
                    cursor.blockDay = d
                }
            }
            if dy != 0 {
                cursor.bandCursorActive = true
                cursor.bandCurTrack = dy > 0 ? 0 : 3 // ↓ → top lane; ↑ → bottom lane (ring)
            }
        case 2: // week: up/down = hour (wrapping into the band lanes); left/right = day (+ glide)
            if dy != 0 {
                hourArrowOrBand(dy)
            }
            if dx != 0 {
                let d = max(1, min(daysInMonth(year, focus), cursor.blockDay + dx))
                if d != cursor.blockDay {
                    cursor.blockDay = d; ensureDayVisibleWeek(d)
                }
            }
        case 3: // day: up/down = hour (wrapping into the band lanes); left/right = prev/next day
            if dy != 0 {
                hourArrowOrBand(dy)
            }
            if dx != 0 {
                swipeDay(dx)
            }
        default:
            break
        }
    }

    /// Week/day vertical ring: hours step normally, but ↑ from 12am wraps into the BOTTOM band
    /// lane and ↓ from 11pm wraps into the TOP lane (bandArrow closes the ring on the other side).
    private func hourArrowOrBand(_ dy: Int) {
        let h = Int(cursor.blockHour.rounded())
        if dy < 0, h <= 0 {
            cursor.bandCursorActive = true; cursor.bandCurTrack = 3
        } else if dy > 0, h >= 23 {
            cursor.bandCursorActive = true; cursor.bandCurTrack = 0
        } else {
            stepHour(dy)
            return
        }
        if level(z) == 3 { // day view: the lane cell sits on the VIEWED day
            cursor.blockDay = daily.dom
        }
    }

    /// ⌘N — create a new event at the block cursor. Week/day (an hour cell) → a 1-hour timed event on
    /// that day/hour, selected + its inline title editor opened for immediate naming. Month/year → no-op.
    public func createEventAtBlock() {
        enterKeyboardMode()
        guard selectedId == nil, !drawerOpen else { return }
        guard level(z) >= 2 else { return } // month/year → no-op
        let d = level(z) == 2 ? cursor.blockDay : daily.dom
        let h = cursor.blockHour
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        items.events.append(TimedEvent(id: id, year: year, month: focus, day: d,
                                       startHour: h, endHour: min(24, h + 1), title: "New event", color: "blue",
                                       anchorTz: anchorNow))
        selectedId = id
        commitTxn()
        editTimed(id) // open the inline title editor so the name is focused right away
    }

    /// ── Band cursor (the block cursor's LANE sub-state — one merged Tab stop) ──────
    /// Move the band cursor; the edges hand back to the plain block cursor (blockArrow enters):
    ///   · year  — ← past day 1 / → past the last day → back to the month cursor.
    ///   · month — ↑ past the top lane / ↓ past the bottom lane → back to the day cursor (ring).
    ///   · week/day — ↓ past the bottom lane → 12am; ↑ past the top lane → 11pm (ring).
    /// Otherwise ↑/↓ walk the 4 lanes and ←/→ walk days (week may shift the focus window).
    public func bandArrow(dx: Int, dy: Int) {
        enterKeyboardMode()
        if dy != 0 {
            switch level(z) {
            case 0: // year: lanes stack across all 12 months (0…47), crossing quarters
                let flat = max(0, min(11 * 4 + 3, cursor.blockMonth * 4 + cursor.bandCurTrack + dy))
                cursor.blockMonth = flat / 4; cursor.bandCurTrack = flat % 4
                cursor.blockDay = min(daysInMonth(year, cursor.blockMonth), max(1, cursor.blockDay))
                ensureMonthVisible(cursor.blockMonth, animated: true)
            case 1: // month: past either lane edge → back to the day cursor (vertical ring)
                let t = cursor.bandCurTrack + dy
                if t < 0 || t > 3 {
                    cursor.bandCursorActive = false
                } else {
                    cursor.bandCurTrack = t
                }
            default: // week/day: past the bottom lane → 12am; past the top lane → 11pm (ring)
                let t = cursor.bandCurTrack + dy
                if t > 3 {
                    cursor.bandCursorActive = false; cursor.blockHour = 0; ensureHourVisible()
                } else if t < 0 {
                    cursor.bandCursorActive = false; cursor.blockHour = 23; ensureHourVisible()
                } else {
                    cursor.bandCurTrack = t
                }
            }
        }
        if dx != 0 {
            let m = level(z) == 0 ? cursor.blockMonth : focus
            switch level(z) {
            case 0: // year: past either day edge → back to the month cursor
                let d = cursor.blockDay + dx
                if d < 1 || d > daysInMonth(year, m) {
                    cursor.bandCursorActive = false
                } else {
                    cursor.blockDay = d
                }
            case 1: cursor.blockDay = max(1, min(daysInMonth(year, m), cursor.blockDay + dx))
            case 2: let d = max(1, min(daysInMonth(year, focus), cursor.blockDay + dx)); if d != cursor
                .blockDay {
                    cursor.blockDay = d; ensureDayVisibleWeek(d)
                }
            default: swipeDay(dx) // day view
            }
        }
    }

    /// The band cursor's cell rect (geometry space): one day column × one lane.
    public func bandCursorRect() -> CGRect? {
        guard cursor.keyboardActive, !Self.isDemoMode, cursor.bandCursorActive, selectedId == nil,
              !drawerOpen else { return nil }
        let g = snapshot()
        let m = level(z) == 0 ? cursor.blockMonth : focus
        let f = frameFor(m, g)
        let day = min(daysInMonth(year, m), max(1, cursor.blockDay))
        return CGRect(x: f.x0 + CGFloat(day - 1) * f.dayW, y: f.bandY + CGFloat(cursor.bandCurTrack) * f.trackH,
                      width: f.dayW, height: f.trackH)
    }

    /// ⌘N in band-cursor mode — create a 1-day band at the cursor cell, select it, open its title editor.
    public func createBandAtCursor() {
        enterKeyboardMode()
        guard cursor.bandCursorActive, selectedId == nil, !drawerOpen else { return }
        let m = level(z) == 0 ? cursor.blockMonth : focus
        let day = min(daysInMonth(year, m), max(1, cursor.blockDay))
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        items.bands.append(BandEvent(
            id: id,
            year: year,
            month: m,
            track: cursor.bandCurTrack,
            startDay: day,
            endDay: day,
            title: "New event",
            color: "blue"
        ))
        selectedId = id
        cursor.bandCursorActive = false
        commitTxn()
        editBand(id)
    }

    /// ── Track-name cursor (month view's extra Tab stops) ───────────────────────────
    /// The focused track-name gutter cell (geometry space), or nil when not on a track name.
    public func trackNameCursorRect() -> CGRect? {
        guard cursor.keyboardActive, !Self.isDemoMode, let t = cursor.trackNameCursor, selectedId == nil, !drawerOpen,
              level(z) == 1 else { return nil }
        let g = snapshot()
        let f = frameFor(focus, g)
        let y = f.bandY + CGFloat(t) * f.trackH
        return CGRect(x: Layout.mnameW, y: y, width: Layout.labelW - Layout.mnameW - Layout.rightPad, height: f.trackH)
    }

    /// Enter on a focused track name → open its inline editor (Enter again commits — see TrackNameEditor).
    public func editFocusedTrackName() {
        guard let t = cursor.trackNameCursor, let rect = trackNameCursorRect() else { return }
        onEditTrackName?(focus, t, rect)
    }

    /// The selected event's anchor (month, day, hour) — nil if nothing selected. Bands anchor at their
    /// start day + noon; timed/deadlines at their day + start hour.
    private func selectedAnchor() -> (month: Int, day: Int, hour: CGFloat)? {
        guard let sel = selectedId else { return nil }
        if let b = displayBands(for: year).first(where: { $0.id == sel }) {
            return (b.month, b.startDay, 12)
        }
        if let e = displayEvents(for: year).first(where: { $0.id == sel }) {
            return (e.month, e.day, e.startHour)
        }
        if let d = displayDeadlines(for: year).first(where: { $0.id == sel }) {
            return (d.month, d.day, d.hour)
        }
        return nil
    }

    /// ⌘= — zoom IN one level, keeping the current focus. With an event selected, the view lands on that
    /// event's month/week/day (it stays selected). With a cursor, this is blockZoomIn's placement.
    public func cmdZoomIn() {
        enterKeyboardMode()
        guard let a = selectedAnchor() else { blockZoomIn(); return }
        cursor.trackNameCursor = nil
        switch level(z) {
        case 0: focus = a.month; cursor.blockMonth = a.month; cursor.blockDay = a.day; ensureMonthVisible(
                a.month,
                animated: false
            ); tweenZ(to: 1)
        case 1: week = CGFloat(weekOfDate(year, focus, a.day)); daily.dom = a.day; cursor.blockDay = a.day; cursor
            .blockHour = a.hour; tweenZ(to: 2)
        case 2: daily.dom = a.day; cursor.blockHour = a.hour; tweenZ(to: 3)
        default: break // day is the deepest
        }
    }

    /// ⌘− — zoom OUT one level, keeping the current focus. With an event selected, the higher-level view
    /// lands on the event so it stays visible; otherwise the block cursor carries over (syncBlockToView).
    public func cmdZoomOut() {
        enterKeyboardMode()
        cursor.trackNameCursor = nil
        clearDashStop()
        let dest = max(0, level(z) - 1)
        if let a = selectedAnchor() {
            focus = a.month
            week = CGFloat(weekOfDate(year, a.month, a.day)); daily.dom = a.day
            cursor.blockMonth = a.month; cursor.blockDay = a.day; cursor.blockHour = a.hour
        }
        tweenZ(to: CGFloat(dest))
        if selectedId == nil {
            syncBlockToView(dest)
        }
    }

    /// Space / ⌘= — zoom IN one level, carrying the block cursor with the placement rules.
    public func blockZoomIn() {
        enterKeyboardMode()
        cursor.trackNameCursor = nil // track names are month-only; zooming leaves them → block cursor
        switch level(z) {
        case 0: // year → month: focus the cursor's month; land the day on today (if that month) else the 1st.
            focus = cursor.blockMonth
            let t = Calendar.current.dateComponents([.year, .month, .day], from: now)
            let isCurMonth = (t.year == year) && ((t.month ?? 0) - 1 == cursor.blockMonth)
            cursor.blockDay = isCurMonth ? (t.day ?? 1) : 1
            ensureMonthVisible(cursor.blockMonth, animated: false) // instant; the zoom repositions immediately after
            tweenZ(to: 1)
        case 1: // month → week: focus the cursor's week; land the hour on now (if the week has today) else noon.
            week = CGFloat(weekOfDate(year, focus, cursor.blockDay))
            daily.dom = cursor.blockDay
            let t = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            let weekHasToday = (t.year == year) && ((t.month ?? 0) - 1 == focus)
                && weekOfDate(year, focus, t.day ?? 1) == weekOfDate(year, focus, cursor.blockDay)
            cursor.blockHour = weekHasToday ? CGFloat(t.hour ?? 12) : 12 // land on the hour cell containing now
            tweenZ(to: 2)
        case 2: // week → day: same hour, on the cursor's day
            daily.dom = min(daysInMonth(year, focus), max(1, cursor.blockDay))
            tweenZ(to: 3)
        default:
            break // day view is the deepest — Space is a no-op
        }
    }

    /// The block cursor's cell rect in geometry space (pre-padLeft), or nil when it shouldn't show
    /// (mouse mode, an event/drawer is active, or a view without a cursor yet).
    public func blockCursorRect() -> CGRect? {
        guard cursor.keyboardActive, !Self.isDemoMode, !cursor.bandCursorActive, cursor.trackNameCursor == nil,
              selectedId == nil, cursor.dashStop == nil, !drawerOpen else { return nil }
        let g = snapshot()
        switch level(z) {
        case 0:
            // Cover the ENTIRE month row — from the left edge (the month-name gutter) to the right.
            let f = yearFrame(cursor.blockMonth, g.vp, scrollY)
            return CGRect(x: 0, y: f.bandY, width: g.vp.w, height: 4 * f.trackH)
        case 1:
            // A day COLUMN: the band cell on top + the day's timeline below it.
            let f = frameFor(focus, g)
            let tl = timelineInfo(g)
            let d = max(1, min(daysInMonth(year, focus), cursor.blockDay))
            let x = f.x0 + CGFloat(d - 1) * f.dayW
            return CGRect(x: x, y: f.bandY, width: f.dayW, height: max(4 * f.trackH, tl.tlBottom - f.bandY))
        case 2, 3:
            // An HOUR cell: the day column × one hour row. (Day view: the shown day is daily.dom.)
            let tl = timelineInfo(g)
            guard tl.hourH > 0 else { return nil }
            let d = level(z) == 2 ? cursor.blockDay : daily.dom
            let x = tl.x0 + CGFloat(d - 1) * tl.colW
            let y = tl.tlTop + cursor.blockHour * tl.hourH - tl.scroll
            return CGRect(x: x, y: y, width: tl.colW, height: tl.hourH)
        default:
            return nil
        }
    }

    /// The dashed-ring rect for the SELECTED event box (geometry space, pre-padLeft) — the event-cursor
    /// visual, shown in keyboard mode. Looks up the exact box in the DISPLAY arrays (so a promoted band /
    /// occurrence ghost rings its own box, not the whole series).
    public func selectionRingRect() -> CGRect? {
        guard cursor.keyboardActive, !drawerOpen else { return nil }
        return selectedBoxRect()
    }

    /// The selected box's rect (scene coords), independent of input mode — the keyboard ring
    /// above and the right-click callout anchor both derive from this.
    public func selectedBoxRect() -> CGRect? {
        guard let sel = selectedId else { return nil }
        let g = snapshot()
        if let b = displayBands(for: year).first(where: { $0.id == sel }), let r = bandEventRect(
            b,
            g,
            anim: g.monthAnim
        ) {
            return CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
        }
        if z >= 1.5, let e = displayEvents(for: year).first(where: { $0.id == sel }) {
            let tl = timelineInfo(g)
            let sameDay = eventsOn(year, e.month, e.day)
            if let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) {
                return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
            }
        }
        if z >= 1.5, let d = displayDeadlines(for: year).first(where: { $0.id == sel }), let pos = deadlinePos(d, g) {
            return CGRect(x: pos.x, y: pos.y - 9, width: pos.w, height: 18) // the moment-line band
        }
        return nil
    }
}
