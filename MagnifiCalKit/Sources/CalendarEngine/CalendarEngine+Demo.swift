// CalendarEngine+Demo — GIF-recording mode (env CC_DEMO): deterministic scene seeding and
// scripted input that drives the REAL pointer/pinch paths. Never touches personal data.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// ── Demo / GIF-recording mode ──────────────────────────────────────────────────────────────
    /// True when launched for automated tutorial-GIF recording (env CC_DEMO=<scene>). In this mode the
    /// store is redirected to a throwaway dir (see ItemStore) and Apple Calendar import is skipped, so a
    /// recording never touches personal data. The DemoController scripts the on-screen scene.
    public static var isDemoMode: Bool {
        !(ProcessInfo.processInfo.environment["CC_DEMO"] ?? "").isEmpty
    }

    public static var demoScene: String {
        ProcessInfo.processInfo.environment["CC_DEMO"] ?? ""
    }

    /// Wipe the calendar to an empty state (recording scenes build their own deterministic content).
    public func demoClearEvents() {
        items.events = []; items.bands = []; items.deadlines = []; items.richById = [:]
        selectedId = nil; caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
    }

    /// Insert one ambient timed event (recording scenes; not on the undo stack, not selected).
    @discardableResult
    public func demoAddTimed(month: Int, day: Int, startHour: CGFloat, endHour: CGFloat, title: String,
                             color: String) -> String {
        let id = "demo-\(items.events.count)"
        items.events.append(TimedEvent(
            id: id,
            year: year,
            month: month,
            day: day,
            startHour: startHour,
            endHour: endHour,
            title: title,
            color: color
        ))
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
        return id
    }

    /// Insert one ambient all-day band (recording scenes; not selected).
    @discardableResult
    public func demoAddBand(month: Int, track: Int, startDay: Int, endDay: Int, title: String,
                            color: String) -> String {
        let id = "demob-\(items.bands.count)"
        items.bands.append(BandEvent(
            id: id,
            year: year,
            month: month,
            track: track,
            startDay: startDay,
            endDay: endDay,
            title: title,
            color: color
        ))
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
        return id
    }

    /// Widen the pinned MONTH dashboard for the still help shots — the divider drag's exact
    /// clamp (dashMonthMinW floor, 0.55 cap), so the staged width is a state a user can reach.
    /// Demo-only: deliberately NOT persisted to UserDefaults (no pref leak out of a recording).
    public func demoSetDashMonthFrac(_ v: CGFloat) {
        let minFrac = Layout.dashMonthMinW / max(1, viewport.w - Layout.labelW)
        let mv = max(min(v, 0.55), minFrac)
        dashMonthFrac = mv
        chrome.dashMonthFrac = mv
        wake()
    }

    /// Drive the REAL pointer/create path from VIEW-local points (GeometryReader space, 0,0 = top-left), so a
    /// scripted drag creates an event exactly under the synthetic cursor — with the live create-preview. This
    /// mirrors CatcherView.point(): geometry space = view − padLeft (+ the live drawer shift).
    private func demoViewToGeometry(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - Layout.padLeft + drawerShift + gutterShift, y: p.y)
    }

    public func demoPointerDown(atView p: CGPoint) {
        onPointerDown(at: demoViewToGeometry(p))
    }

    public func demoPointerDrag(atView p: CGPoint) {
        onPointerDrag(at: demoViewToGeometry(p))
    }

    public func demoPointerUp(atView p: CGPoint) {
        onPointerUp(at: demoViewToGeometry(p))
    }

    /// Rename the currently-selected event (recording scenes give a freshly drag-created event a real title).
    public func demoRenameSelected(_ title: String) {
        guard let id = selectedId, let i = items.events.firstIndex(where: { $0.id == id }) else { return }
        items.events[i].title = title; caches.editGen &+= 1; wake()
    }

    /// Rename the currently-selected BAND (band scenes name their freshly drag-created band).
    public func demoRenameSelectedBand(_ title: String) {
        guard let id = selectedId, let i = items.bands.firstIndex(where: { $0.id == id }) else { return }
        items.bands[i].title = title; caches.editGen &+= 1; wake()
    }

    /// Bench: glide the YEAR scroll until month `m` is visible — the same pace-locked tween a keyboard
    /// scroll uses (constant speed per month band), so a scroll benchmark is deterministic.
    public func demoScrollYearToMonth(_ m: Int) {
        wake(); ensureMonthVisible(m, animated: true)
    }

    /// Bench: feed the REAL hover path from a view-local point (what a trackpad scroll does every frame —
    /// hit-testing bands/events under the pointer), so a scroll benchmark can include that per-move cost.
    public func demoHover(atView p: CGPoint) {
        onHover(at: demoViewToGeometry(p))
    }

    /// The deadline quick-add "+" spot (appears while hovering a day column), in VIEW coordinates — the
    /// deadline-add recording scene hovers, reads this, and clicks it through the real pointer path.
    public func demoDeadlineSpotView() -> CGPoint? {
        deadlineAddSpot(snapshotInput()).map { CGPoint(x: $0.x + Layout.padLeft - drawerShift - gutterShift, y: $0.y) }
    }

    /// A DEADLINE's on-screen anchor (mid moment-line), VIEW coords — the promote scene right-clicks it.
    public func demoDeadlinePointView(_ id: String) -> CGPoint? {
        guard let d = displayDeadlines(for: year).first(where: { $0.id == id }),
              let pos = deadlinePos(d, snapshotInput()) else { return nil }
        return CGPoint(x: pos.x + pos.w * 0.2 + Layout.padLeft - drawerShift - gutterShift, y: pos.y)
    }

    /// A BAND box's rect (incl. promoted ghosts), VIEW coords — the promote scene drags the ghost by it.
    public func demoBandRectView(_ boxId: String) -> CGRect? {
        guard let b = viewBands().first(where: { $0.id == boxId }),
              let r = bandEventRect(b, snapshotInput()) else { return nil }
        return CGRect(x: r.x + Layout.padLeft - drawerShift - gutterShift, y: r.y, width: r.w, height: r.h)
    }

    /// Center the week/day timeline on `hour` (scenes must not assume where the pinned-16:00 scroll sits).
    public func demoScrollTimelineToHour(_ hour: CGFloat) {
        let tl = timelineInfo(snapshotInput())
        guard tl.hourH > 0 else { return }
        tlScroll = max(0, min(tl.maxScroll, hour * tl.hourH - (tl.tlBottom - tl.tlTop) / 2))
        wake()
    }

    /// Scroll the timeline so the SELECTED event is on screen (the week view's scroll follows the clock,
    /// so a scene can't assume where any hour sits — reveal first, then read the rect).
    public func demoRevealSelected() {
        scrollToSelected()
    }

    /// A timed event's box rect in VIEW coordinates, straight from the display geometry — scenes aim the
    /// synthetic cursor with this instead of hardcoded fractions (which break as the time-of-day scroll
    /// shifts the grid). Independent of selection/keyboard state.
    public func demoEventRectView(_ id: String) -> CGRect? {
        let g = snapshot()
        let tl = timelineInfo(g)
        guard tl.hourH > 0, let disp = viewEvents().first(where: { $0.id == id }),
              let seg = timedSegments(disp).first else { return nil }
        let sameDay = eventsOn(seg.event.year, seg.event.month, seg.event.day)
        guard let r = eventRect(seg.event, year, focus, tl, g.vp, layoutDay(sameDay)[seg.event.id]) else { return nil }
        return CGRect(x: r.minX + Layout.padLeft - drawerShift - gutterShift, y: tl.tlTop - tl.scroll + r.minY,
                      width: r.width, height: r.height)
    }

    /// Dev (env CC_DUMP_DISPLAY=<path>, real mode): once imports settle, write this year's fully-EXPANDED
    /// display set — recurrence occurrences, promoted ghost bands, Apple-Calendar imports, exactly what
    /// renders — as a plain store payload. Benchmarks load it as data.json so a demo-mode (no-EventKit,
    /// no-personal-store) run renders the true production load.
    func scheduleDisplayDumpIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CC_DUMP_DISPLAY"], !path.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6)) // give the EventKit import time to land
            guard let self else { return }
            let y = self.year
            let st = PersistedState(events: self.displayEvents(for: y), bands: self.displayBands(for: y),
                                    deadlines: self.displayDeadlines(for: y),
                                    monthTrackNames: self.items.trackNames, rich: [:])
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(st) {
                try? d.write(to: URL(fileURLWithPath: path))
            }
            NSLog("CC_DUMP_DISPLAY: wrote %d events / %d bands / %d deadlines for %d to %@",
                  self.displayEvents(for: y).count, self.displayBands(for: y).count,
                  self.displayDeadlines(for: y).count, y, path)
        }
    }

    /// Bench: time the pure notification-planning pass over the CURRENT store (prefs forced
    /// enabled, all kinds on) — per-rep milliseconds. This is the exact main-thread stall a
    /// post-edit resync costs at this data size when the plan runs synchronously on main.
    public func benchNotifyPlan(reps: Int) -> [Double] {
        var prefs = NotifyPrefs.load()
        prefs.enabled = true
        for k in NotifyKind.allCases {
            prefs.kindEnabled[k] = true
        }
        var out: [Double] = []
        for _ in 0 ..< reps {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = NotifyPlanner.plan(items: items, mainTz: mainTz, prefs: prefs, now: Date())
            out.append(Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6)
        }
        return out
    }

    /// Bench: has the year-scroll glide finished? (Poll + `wake()` while false to keep the frames coming.)
    public var demoYearScrollSettled: Bool {
        anim.scrollTween == nil
    }

    /// Snap the view to year level, scrolled so `centerMonth` is visible (deterministic scene setup).
    public func demoGoToYear(centerMonth: Int) {
        cancelTween()
        z = 0; focus = centerMonth
        ensureMonthVisible(centerMonth, animated: false)
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
    }

    /// Snap the view to WEEK level on this year's `month`, week index `w` (0-based; deterministic
    /// scene setup — no zoom tween). `weekResync` re-syncs the WeekPager strip to the new week.
    public func demoGoToWeek(month: Int, week w: CGFloat) {
        cancelTween()
        focus = month
        week = clamp(w, 0, CGFloat(max(0, weeksInMonth(year, month) - 1)))
        z = 2
        pushChrome()
        chrome.weekResync &+= 1
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
    }

    /// Drive the REAL pinch path (`onMagnify`) from a view point, so the month/week/day under `v` is exactly
    /// what fills the screen (`captureFocus` anchors on the pinch point — unlike the keyboard/block zoom,
    /// which snaps to the block cursor / today). The recording's pinch visual is drawn at this same point, so
    /// the gesture and the zoom target always line up. `delta` is trackpad-style magnification (Motion.pinchSens
    /// scales it into z); a full single-level pinch accumulates ≈0.7 (see DemoController.pinch).
    public func demoMagnify(delta: CGFloat, atView v: CGPoint, began: Bool, ended: Bool) {
        onMagnify(delta: delta, at: demoViewToGeometry(v), began: began, ended: ended)
    }

    /// Double-click an item at a view point: select it (so it highlights) and open its drawer — the same
    /// outcome as a real double-click. Returns the item id, or nil if nothing was under the point.
    @discardableResult
    public func demoDoubleClick(atView v: CGPoint) -> String? {
        guard let id = itemId(at: demoViewToGeometry(v)) else { return nil }
        selectedId = id
        onRequestOpenDrawer?(id, false)
        caches.editGen &+= 1; wake()
        return id
    }

    /// Select an item by id (highlight it), e.g. a just-created event in the AI scene.
    public func demoSelect(_ id: String?) {
        selectedId = id; caches.editGen &+= 1; wake()
    }
}
