// CalendarEngine+PagerGestures — the month/week/day pager projections (invisible SwiftUI
// pagers own the physics; we project their offsets onto engine state), their boundary
// flips, pinch zoom anchoring, and pointer-focus capture.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// ── Month view: vertical month↕month paging, driven by an invisible SwiftUI ScrollView ──
    /// A hidden SwiftUI `ScrollView` with 12 page cells and `.scrollTargetBehavior(.paging)` does
    /// the real work: native velocity-aware paging + the settle animation. We just observe its
    /// absolute content offset (via `.onScrollGeometryChange`) and convert it to (focus, anim.monthAnim).
    /// No snap anim.tween / recentre here — SwiftUI owns the physics; this is a pure projection.
    /// A month-view scroll gesture or page-turn is in progress (fingers down OR the turn/settle
    /// animating). The events overlay pre-mounts the neighbor months' stickers while this is true.
    public var monthGestureActive: Bool {
        isMonthLevel && (scroll.liveMonthScrolling || anim.monthAnim != nil)
    }

    public var isMonthLevel: Bool {
        level(z) == 1
    }

    /// A scroll gesture starts — kill any zoom anim.tween so they don't fight.
    public func beginMonthGesture() {
        wake(); cancelTween(); scroll.liveMonthScrolling = true
    }

    /// ── Week view: horizontal day/week paging, driven by an invisible SwiftUI ScrollView ──
    /// Same construct as the month pager, rotated horizontal: a strip of day cells + a custom
    /// ScrollTargetBehavior that snaps to a day (small scroll) or a week boundary (large scroll).
    /// Month-scoped for now — `week` is clamped to the month; crossing the edge (a flip) is TODO.
    public var isWeekLevel: Bool {
        level(z) == 2
    }

    public var isDayLevel: Bool {
        level(z) == 3
    }

    /// Day-view split: the timeline's width as a fraction of the content area (the rest is the daily
    /// dashboard). Driven by the drag handle on the timeline↔dashboard boundary; clamped so neither
    /// side collapses.
    public func setDailyFrac(_ f: CGFloat) {
        wake(); daily.frac = clamp(f, Layout.dayFracMin, Layout.dayFracMax); chrome.dailyResync &+= 1
    }

    /// Split-handle drag at a PINNED month/week: adjusts (and persists) that scope's panel width.
    /// The clamp keeps the panel usable without letting it eat the squeezed grid.
    public func setDashPinFrac(_ f: CGFloat) {
        wake()
        let v = clamp(f, 0.15, 0.55)
        if level(z) <= 1 {
            // The month panel is FLOORED at dashMonthMinW px (geometry-side); clamp the stored
            // fraction to the same floor so the handle can't drag below it and detach from the
            // (floored) panel edge.
            let minFrac = Layout.dashMonthMinW / max(1, viewport.w - Layout.labelW)
            let mv = max(v, min(0.55, minFrac))
            dashMonthFrac = mv; chrome.dashMonthFrac = mv
            UserDefaults.standard.set(Double(mv), forKey: PrefKeys.dashMonthFrac)
        } else {
            dashWeekFrac = v; chrome.dashWeekFrac = v
            UserDefaults.standard.set(Double(v), forKey: PrefKeys.dashWeekFrac)
        }
    }

    /// True when the current overscroll pull has passed the flip threshold — peeked on fingers-up so
    /// the catcher can withhold `.ended` from the pager (preventing a stale snap animation).
    public var weekFlipArmed: Bool {
        isWeekLevel && (scroll.weekPull?.armed ?? false)
    }

    /// The week window's travel bounds for the focus month, in week units. A FULL-week window
    /// (desktop) pages week-aligned across weeksInMonth — its boundary weeks include neighbor
    /// spillover by design. A PARTIAL window (phone, weekDaysVisible < 7) is day-aligned and
    /// MONTH-BOUNDED: it parks at the month's own day 1 / last day, so a neighbor-month
    /// spillover day can never fill the view.
    var weekBounds: (min: CGFloat, max: CGFloat) {
        if Layout.weekDaysVisible < 7 {
            let fdow = CGFloat(firstDOW(year, focus))
            let hi = (fdow + CGFloat(daysInMonth(year, focus)) - Layout.weekDaysVisible) / 7
            return (fdow / 7, max(fdow / 7, hi))
        }
        return (0, max(0, CGFloat(weeksInMonth(year, focus)) - 1))
    }

    public func beginWeekGesture() {
        wake(); cancelTween(); anim.weekTween = nil; scroll.liveWeekScrolling = true
        // Fingers down INTERCEPT any dashboard cruise/settle: freeze the carousel exactly where
        // it is (fingers may keep scrubbing the canvas; the frozen hold ignores the band). The
        // release settles it — weekGlideWillLand on the next snap, or the idle fallback.
        if let st = weekDashSettle {
            weekDashHold?.q = st.value(at: Date()); weekDashSettle = nil
        }
        weekDashCruise = nil
    }

    public func beginDayGesture() {
        wake(); cancelTween(); scroll.liveDayScrolling = true
    }

    /// The `week` value that keeps the week window aligned with day `dom` while DAY-level
    /// navigation moves it (paging, glides, drills): a full-week window (desktop) snaps to the
    /// day's whole week; a partial window (phone) centers on the day, clamped to the month-
    /// bounded travel range — so zooming back out always lands on a legal window showing `dom`.
    func weekFor(dom: Int) -> CGFloat {
        if Layout.weekDaysVisible < 7 {
            let slot = CGFloat(dom - 1 + firstDOW(year, focus))
            let b = weekBounds
            return clamp((slot + 0.5 - Layout.weekDaysVisible / 2).rounded() / 7, b.min, b.max)
        }
        return CGFloat(weekOfDate(year, focus, dom))
    }

    /// Project the day pager's horizontal offset onto (daily.dom, daily.anim). Each day cell is `dayW`
    /// wide (the day column's own width), so `offsetX / dayW` is a continuous day index: `daily.dom` is
    /// the anchored day and the fractional remainder becomes the slide progress. Past a month edge the
    /// (AppKit-rubber-banded) offset runs negative / beyond max; there we PREVIEW the neighbor month's
    /// first/last day sliding in (via the spillover day-page: day 0 / day dim+1) and arm a flip.
    public func setDayProgress(_ offsetX: CGFloat) {
        guard isDayLevel, !isDayFlipping else { return }
        wake()
        let dayW = daily.frac * (viewport.w - Layout.labelW)
        guard dayW > 0 else { return }
        let dim = daysInMonth(year, focus)
        let maxOff = CGFloat(dim - 1) * dayW
        var norm = offsetX / dayW - CGFloat(daily.dom - 1) // progress relative to the current anchor
        while norm >= 1, daily.dom < dim {
            daily.dom += 1; norm -= 1
        }
        while norm <= -1, daily.dom > 1 {
            daily.dom -= 1; norm += 1
        }
        let overLeft = offsetX < 0 ? -offsetX : 0
        let overRight = offsetX > maxOff ? offsetX - maxOff : 0
        // At the edges, map the rubber-band to a day-page PREVIEW: the neighbor month's day (day dim+1
        // resolves to next month's 1st; day 0 to prev month's last) slides in via the spillover day-page.
        // (Flip disabled — phone: no preview either; the strip just rubber-bands at the month's days.)
        if dayMonthFlipEnabled, daily.dom >= dim, overRight > 0 {
            norm = min(0.999, overRight / dayW * Motion.dayOverMul)
        } else if dayMonthFlipEnabled, daily.dom <= 1, overLeft > 0 {
            norm = -min(0.999, overLeft / dayW * Motion.dayOverMul)
        } else {
            if daily.dom >= dim {
                norm = min(0, norm)
            }
            if daily.dom <= 1 {
                norm = max(0, norm)
            }
        }
        daily.anim = abs(norm) < 0.001 ? nil : PageAnim(dir: norm > 0 ? 1 : -1, p: min(1, abs(norm)))
        // Arm a boundary flip while the overscroll is live.
        if scroll.liveDayScrolling, dayMonthFlipEnabled, overLeft > 2 || overRight > 2 {
            let dir = overRight > 0 ? 1 : -1
            let over = dir > 0 ? overRight : overLeft
            let tm = dir > 0 ? (focus + 1) % 12 : (focus + 11) % 12
            let ty = dir > 0 ? (focus == 11 ? year + 1 : year) : (focus == 0 ? year - 1 : year)
            scroll.dayPull = DayPull(
                dir: dir,
                over: over,
                armed: over >= Motion.dayFlipOver,
                targetMonth: tm,
                targetYear: ty
            )
        } else {
            scroll.dayPull = nil
        }
        // Keep `week` on the week that contains the day we scrolled to, so zooming back out lands on
        // THAT week (not the one we entered day view from).
        week = weekFor(dom: daily.dom)
        pushChrome()
        scheduleDaySettle()
    }

    /// Safety-net for the day pager: forwarded webview scrolls can leave the SwiftUI ScrollView settled
    /// a hair off a day boundary (its snap behaviour didn't fully fire), so `daily.anim` keeps a leftover
    /// `p` and everything downstream (panel interactivity, the note toggle, the landing position) stays
    /// stuck mid-swipe. If scrolling goes idle with a residual, snap to the nearest day and re-sync the
    /// pager. Rescheduled on every offset change, so it only fires once the scroll has actually stopped.
    private func scheduleDaySettle() {
        scroll.daySettleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.settleDay() }
        scroll.daySettleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
    }

    private func settleDay() {
        // Only rescue a residual once the gesture is genuinely OVER — never snap while fingers are still
        // on the trackpad (a mid-scroll pause). The catcher now marks `scroll.liveDayScrolling` for the whole
        // finger-down phase — direct AND webview-forwarded — and clears it on `.ended` (which also
        // schedules this settle), so this gate cleanly separates "paused mid-scroll" from "done".
        guard isDayLevel, !isDayFlipping, anim.dayTween == nil, !scroll.liveDayScrolling
        else { return }
        guard let a = daily.anim else { return } // already settled → nothing to do
        let dim = daysInMonth(year, focus)
        if a.p > 0.5 { // past halfway → adopt the neighbour day
            let nd = daily.dom + a.dir
            if nd >= 1, nd <= dim {
                daily.dom = nd
            }
        }
        daily.anim = nil // clear the residual → back to "at rest"
        week = weekFor(dom: daily.dom)
        pushChrome(); chrome.dailyResync &+= 1 // re-sync the pager strip to the snapped day
    }

    /// Fingers lifted in day view. If a boundary pull passed the threshold, complete the day-page
    /// across the month edge (p→1), then re-anchor focus/year/day to the neighbor day. Returns true if
    /// a flip started (so the catcher can withhold `.ended` / swallow momentum, like the week flip).
    @discardableResult
    public func endDayGesture() -> Bool {
        scroll.liveDayScrolling = false
        let pull = scroll.dayPull
        scroll.dayPull = nil
        if let pull, pull.armed, dayMonthFlipEnabled, !isDayFlipping, isDayLevel {
            let toDom = pull.dir > 0 ? 1 : daysInMonth(pull.targetYear, pull.targetMonth)
            anim.dayFlip = DayFlip(dir: pull.dir, toYear: pull.targetYear, toFocus: pull.targetMonth,
                                   toDom: toDom, startP: daily.anim?.p ?? 0, start: Date())
            return true
        }
        scheduleDaySettle() // fingers up, no flip → settle any residual once the pager's momentum stops
        return false
    }

    /// Per-frame day-flip. `focus` is HELD at the from-month while the day-page eases to completion —
    /// the incoming neighbor day is drawn as the spillover day (day 0 / dim+1), so it's already the
    /// real neighbor date. At p=1 we commit: swap focus/year/day to the neighbor and re-sync the pager
    /// (and the year-view scroll, so zooming out lands on the new month).
    func advanceDayFlip(_ df: DayFlip, at date: Date) {
        let t = clamp(CGFloat(date.timeIntervalSince(df.start) / Motion.dayFlipDur), 0, 1)
        if t >= 1 {
            year = df.toYear; focus = df.toFocus; daily.dom = df.toDom
            daily.anim = nil; daily.over = 0; anim.dayFlip = nil // END the flip (else it re-commits every frame)
            week = weekFor(dom: daily.dom)
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY)
            pushChrome()
            chrome.dailyResync += 1
            return
        }
        daily.anim = PageAnim(dir: df.dir, p: lerp(df.startP, 1, easeOut(t)))
        pushChrome()
    }

    /// Project the week pager's horizontal offset onto `week`. Day cells are `dayW` wide and a
    /// week is 7 of them, so `offsetX / (7·dayW)` is the fractional week index within the month.
    /// Past either edge the (AppKit-rubber-banded) offset runs negative / beyond max; we let `week`
    /// follow it (bounded) so the window elastically slides past the boundary, and detect the
    /// overscroll to arm a month flip.
    public func setWeekProgress(_ offsetX: CGFloat, dayW: CGFloat) {
        guard isWeekLevel, !isWeekFlipping, dayW > 0 else { return }
        wake()
        let span = 7 * dayW
        // Window travel bounds, week units: week-aligned across weeksInMonth on desktop;
        // day-aligned and MONTH-BOUNDED on the phone's partial window (see weekBounds).
        let (minWeek, maxWeek) = weekBounds
        let minOff = minWeek * span
        let maxOff = maxWeek * span
        // Elastic: follow the rubber-banded offset past each edge, AMPLIFYING the overscroll so the
        // window travels further than AppKit's (heavily damped) rubber-band alone would allow — a
        // more generous, tactile pull. Arming/indicator use the raw px `over`, so the flip threshold
        // feel is unchanged; only the on-screen travel grows.
        // The overscroll AMPLIFICATION (weekOverMul) exists to make the flip-arming pull feel
        // generous; with the month-edge flip disabled (phone) the window just tracks the native
        // rubber-band unamplified and bounces back.
        let raw = offsetX / span
        if raw < minWeek {
            week = weekMonthFlipEnabled
                ? clamp(minWeek + (raw - minWeek) * Motion.weekOverMul, minWeek - 1.6, minWeek)
                : clamp(raw, minWeek - 1.6, minWeek)
        } else if raw > maxWeek {
            week = weekMonthFlipEnabled
                ? clamp(maxWeek + (raw - maxWeek) * Motion.weekOverMul, maxWeek, maxWeek + 1.6)
                : clamp(raw, maxWeek, maxWeek + 1.6)
        } else {
            week = raw
        }
        // Weekly-dashboard cruise: while a hard-fling glide is in flight, the carousel progress
        // rides the glide's travel proportionally — the WHOLE remaining scroll maps onto the
        // remaining carousel travel, hitting the rest state exactly as the glide lands.
        weekDashIdleAt = Date()
        if var hold = weekDashHold, let c = weekDashCruise {
            let span = c.wTarget - c.wStart
            let lo = min(c.qStart, c.qTarget), hi = max(c.qStart, c.qTarget)
            hold.q = abs(span) < 0.0001 ? c.qTarget
                : clamp(c.qStart + (week - c.wStart) / span * (c.qTarget - c.qStart), lo, hi)
            weekDashHold = hold
            if abs(week - c.wTarget) < 0.003 { // landed → the band's rest matches; follow it
                weekDashHold = nil; weekDashCruise = nil
            }
        }
        let overLeft = offsetX < minOff ? minOff - offsetX : 0
        let overRight = offsetX > maxOff ? offsetX - maxOff : 0
        if scroll.liveWeekScrolling, weekMonthFlipEnabled, overLeft > 2 || overRight > 2 {
            let dir = overRight > 0 ? 1 : -1
            let over = dir > 0 ? overRight : overLeft
            let fdow = firstDOW(year, focus)
            let dim = daysInMonth(year, focus)
            // A boundary week is "shared" (dim-swap) when it holds spillover from the neighbor:
            // the right edge shares unless the month ends on Saturday; the left unless it starts Sunday.
            let shared = dir > 0 ? ((fdow + dim - 1) % 7 != 6) : (fdow != 0)
            let tm = dir > 0 ? (focus + 1) % 12 : (focus + 11) % 12
            let ty = dir > 0 ? (focus == 11 ? year + 1 : year) : (focus == 0 ? year - 1 : year)
            scroll.weekPull = WeekPull(dir: dir, over: over, armed: over >= Motion.weekFlipOver,
                                       shared: shared, targetMonth: tm, targetYear: ty)
        } else {
            scroll.weekPull = nil
        }
        pushChrome()
    }

    /// Project the pager's absolute content offset onto (focus, anim.monthAnim). The page cells are
    /// `pageH` tall, so `offsetY / pageH` is a continuous month index; `focus` is the anchored
    /// month and the fractional remainder becomes the page-turn progress. `focus` advances as the
    /// offset crosses each page boundary, so a multi-page fling walks through the months in order.
    public func setMonthProgress(_ offsetY: CGFloat, pageH: CGFloat) {
        // monthGlide gate: during a jumpToMonth glide the engine owns the month position and the
        // pager scroll view is parked at the OLD offset — its callbacks must not fight the glide.
        guard isMonthLevel, !isMonthFlipping, anim.monthGlide == nil, pageH > 0 else { return }
        wake()
        let startFocus = focus
        var norm = offsetY / pageH - CGFloat(focus)
        while norm >= 1, focus < 11 {
            focus += 1; norm -= 1
        } // crossed into the next month
        while norm <= -1, focus > 0 {
            focus -= 1; norm += 1
        } // crossed into the previous month
        if focus >= 11 {
            norm = min(0, norm)
        } // Dec: clamp elastic overscroll
        if focus <= 0 {
            norm = max(0, norm)
        } // Jan
        anim.monthAnim = abs(norm) < 0.001 ? nil
            : PageAnim(dir: norm > 0 ? 1 : -1, p: min(1, abs(norm)))
        // Elastic overscroll past Jan (top) / Dec (bottom) arms a cross-year flip. The pager
        // document is [0, 11·pageH]; a live drag can push the offset outside that, and paging
        // caps one page per gesture so this only fires when already resting at the boundary.
        let maxOff = CGFloat(11) * pageH
        let overTop = offsetY < 0 ? -offsetY : 0
        let overBot = offsetY > maxOff ? offsetY - maxOff : 0
        // Elastic: the month follows the (AppKit-rubber-banded) overscroll and snaps back with it.
        anim.monthFlipShift = overTop > 0 ? overTop : (overBot > 0 ? -overBot : 0)
        if scroll.liveMonthScrolling, monthYearFlipEnabled, overTop > 2 || overBot > 2 {
            let atTop = overTop > 0
            scroll.monthPull = YearPull(targetYear: atTop ? year - 1 : year + 1, atTop: atTop,
                                        over: atTop ? overTop : overBot,
                                        armed: (atTop ? overTop : overBot) >= Layout.yearFlipOver)
        } else {
            scroll.monthPull = nil
        }
        // Keep the year-view scroll in step with the month we paged to, so zooming back out
        // lands on this month (centred, clamped so Jan/Dec sit at the top/bottom).
        if focus != startFocus {
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY)
        }
        pushChrome()
    }

    /// Fingers lifted in month view. If a boundary pull passed the threshold, launch the
    /// cross-year flip (Jan → previous Dec, Dec → next Jan); otherwise the pager bounces back.
    public func endMonthGesture() {
        scroll.liveMonthScrolling = false
        let pull = scroll.monthPull
        scroll.monthPull = nil
        guard let pull, pull.armed, monthYearFlipEnabled, !isMonthFlipping, isMonthLevel else { return }
        let dir = pull.atTop ? -1 : 1
        anim.monthFlip = MonthFlip(dir: dir, fromYear: year, fromFocus: focus,
                                   toYear: year + dir, toFocus: dir < 0 ? 11 : 0,
                                   startShift: anim.monthFlipShift, start: Date()) // continue from the elastic pull
    }

    /// Two-phase month boundary flip, per frame. Phase 1: the current month slides off (down for
    /// a prev-flip, up for next) and fades out. Phase 2: the cross-year month enters from the
    /// opposite edge and fades in. Year/focus swap at the midpoint; the pager re-syncs then too.
    func advanceMonthFlip(_ mf: MonthFlip, at date: Date) {
        let dir = CGFloat(mf.dir)
        let OFF = viewport.h + Layout.monthH
        let t = clamp(CGFloat(date.timeIntervalSince(mf.start) / Motion.monthFlipDur), 0, 1)
        if t >= 1 {
            year = mf.toYear; focus = mf.toFocus
            anim.monthFlipShift = 0; anim.flipFade = 1; anim.monthFlip = nil
            onSetMonthPage?(focus) // final pin: the pager is at rest ON the new focus page, so the
            // first unguarded mirror callback is a no-op (norm 0)
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY) // new year → keep the year-view scroll in step
            pushChrome()
            return
        }
        if t < 0.5 { // outgoing month exits + fades
            let p = t / 0.5
            if year != mf.fromYear || focus != mf.fromFocus {
                year = mf.fromYear; focus = mf.fromFocus
            }
            anim.monthFlipShift = lerp(mf.startShift, dir < 0 ? OFF : -OFF, easeInOut(p)) // continue from the pull
            anim.flipFade = 1 - p
        } else { // incoming (cross-year) month enters + fades
            let p = (t - 0.5) / 0.5
            if year != mf.toYear || focus != mf.toFocus {
                year = mf.toYear; focus = mf.toFocus
                pushChrome()
            }
            let enter = dir < 0 ? -OFF : OFF // prev → Dec from top; next → Jan from bottom
            anim.monthFlipShift = enter * (1 - easeOut(p))
            anim.flipFade = p
        }
        // Pin the (invisible) pager to the current phase's page EVERY FRAME, like the week flip
        // does. A one-shot midpoint teleport LOSES to a live paging settle: the paging behavior
        // re-targets the 11-page jump to originalPage ± 1 — the "heavy fling at Dec lands on
        // Nov / at Jan lands on Feb" bug. Overwritten 60×/s, its settle can't diverge, and the
        // final pin (above) lands after the gesture closed, so it sticks.
        onSetMonthPage?(focus)
    }

    /// Fingers lifted in week view. If a boundary pull passed the threshold, launch the month-edge
    /// flip: the focus/week re-anchor to the neighbor month and the dim/bright split cross-fades.
    /// Returns true if a flip started (so the catcher can swallow the fling's trailing momentum).
    @discardableResult
    public func endWeekGesture() -> Bool {
        scroll.liveWeekScrolling = false
        let pull = scroll.weekPull
        scroll.weekPull = nil
        guard let pull, pull.armed, weekMonthFlipEnabled, !isWeekFlipping, isWeekLevel else { return false }
        // A month-edge flip re-anchors week coordinates — drop any dashboard override; the
        // band mapping (in the destination month's coordinates) takes over.
        weekDashHold = nil; weekDashCruise = nil; weekDashSettle = nil
        let toFocus = pull.targetMonth, toYear = pull.targetYear
        let maxWeekFrom = CGFloat(max(0, weeksInMonth(year, focus) - 1))
        // Rest week in FROM-month coordinates that shows the boundary week:
        //  · shared boundary → the SAME 7 days stay put (last/first week of the from-month);
        //  · aligned boundary → advance one week PAST the edge (into the neighbor's fresh week).
        let targetWeek: CGFloat = pull.dir > 0 ? (pull.shared ? maxWeekFrom : maxWeekFrom + 1)
            : (pull.shared ? 0 : -1)
        // Final anchor in DESTINATION coordinates: dir>0 → its first week; dir<0 → its last week.
        let toWeek: CGFloat = pull.dir > 0 ? 0 : CGFloat(max(0, weeksInMonth(toYear, toFocus) - 1))
        // `targetWeek` (from-coords) and `toWeek` (to-coords) are the SAME on-screen position; the
        // constant offset between the two coordinate systems is `delta = targetWeek - toWeek`. So the
        // overscrolled `week` (from-coords) maps to `week - delta` in destination coords.
        let delta = targetWeek - toWeek
        let startWeek = week - delta
        // Swap the anchor NOW, on release: month name, track names, day labels ("3"→"Jun 3") and the
        // breadcrumb all update immediately — the on-screen window doesn't move (startWeek matches the
        // current screen position) and `spillFactor` at fade=0 matches the pre-release dim, so the only
        // thing left to animate is the event cross-fade that follows.
        year = toYear; focus = toFocus; week = startWeek
        anim.weekFlipFade = 0
        anim.weekFlip = WeekFlip(dir: pull.dir, startWeek: startWeek, toWeek: toWeek, start: Date())
        // Keep the year-view scroll in step with the month we flipped into (exactly as month paging
        // does), so zooming out lands on this month — and one more zoom-out centers it in the year.
        scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
        onSetYearScroll?(scrollY)
        pushChrome()
        return true
    }

    /// ── Weekly-dashboard carousel (OBSERVES the scroll; never drives it) ─────────────────────
    /// WeekScrollBehavior's existing snap policy already classifies every release: a hard fling
    /// glides to a WEEK boundary, a gentle scroll steps days. This is its read-only report of
    /// that decision. On a week jump → arm a CRUISE: the dashboard carousel's progress rides the
    /// glide's remaining travel proportionally (the "entire week's scroll" mapping), landing at
    /// its rest exactly as the window does. On a small landing → if a caught (frozen) carousel
    /// is off the band, SETTLE it to the band's resting side for the landing week.
    public func weekGlideWillLand(atDay day: CGFloat, weekJump: Bool) {
        guard isWeekLevel else { return }
        let wTarget = day / 7
        guard weekJump, abs(wTarget - week) > 0.02 else {
            if weekDashHold != nil, weekDashCruise == nil {
                settleWeekDash(restWeek: wTarget)
            }
            return
        }
        let base = Int(floor(week))
        let pB = clamp((week - floor(week)) * 7 - 3, 0, 1) // the band's value right now
        var from = base, to = base + 1
        var qStart = pB, qTarget: CGFloat = 1
        if wTarget < week { // backward glide
            if Int(wTarget.rounded()) <= base - 1, pB < 0.5 { // into the previous week
                from = base - 1; to = base; qStart = 1; qTarget = 0
            } else {
                qTarget = 0 // back to the base week's own rest
            }
        }
        // Chained flings / catch-then-refling: keep the live progress when the pair is
        // unchanged, so the carousel continues from where it visually is (no pop).
        if let h = weekDashHold, h.from == from, h.to == to {
            qStart = h.q
        }
        weekDashHold = WeekDashHold(from: from, to: to, q: qStart)
        weekDashCruise = (wStart: week, wTarget: wTarget, qStart: qStart, qTarget: qTarget)
        weekDashSettle = nil
    }

    /// Tween a frozen/off-band carousel hold to the band's resting side for `restWeek`, then
    /// hand back to the pure band mapping (the hold clears when the tween completes — see
    /// sceneInput). Landing rests are day-aligned, so the band there is always 0 or 1.
    func settleWeekDash(restWeek: CGFloat) {
        guard var hold = weekDashHold else { return }
        let baseF = floor(restWeek + 0.0001)
        let pB = clamp((restWeek - baseF) * 7 - 3, 0, 1)
        let rest = pB < 0.5 ? Int(baseF) : Int(baseF) + 1 // the week the band rests on
        let target: CGFloat
        if rest == hold.to {
            target = 1
        } else if rest == hold.from {
            target = 0
        } else { // scrubbed to a third week — re-base from the visually dominant panel
            hold = WeekDashHold(from: hold.q < 0.5 ? hold.from : hold.to, to: rest, q: 0)
            target = 1
        }
        weekDashHold = hold
        weekDashCruise = nil
        weekDashSettle = Tween(
            from: hold.q,
            to: target,
            start: Date(),
            duration: Motion.weekDashSettleDur,
            ease: easeInOut
        )
    }

    /// Per-frame week-flip. The anchor already swapped to the destination month on release; here the
    /// window just eases from the overscrolled `startWeek` back to `toWeek` while `anim.weekFlipFade` 0→1
    /// drives `spillFactor`'s dim/bright cross-fade. At t=1 we settle and re-sync the pager.
    func advanceWeekFlip(_ wf: WeekFlip, at date: Date) {
        let t = clamp(CGFloat(date.timeIntervalSince(wf.start) / Motion.weekFlipDur), 0, 1)
        if t >= 1 {
            week = wf.toWeek
            anim.weekFlipFade = 0; anim.weekFlip = nil
            onSetWeekScroll?(weekOffset(week)) // pin the pager to rest BEFORE the guard lifts (no stray callback)
            pushChrome()
            chrome.weekResync += 1
            return
        }
        week = lerp(wf.startWeek, wf.toWeek, easeOut(t)) // settle the window (bounce-back)
        anim.weekFlipFade = easeInOut(t) // cross-fade the events (after the text swap)
        onSetWeekScroll?(weekOffset(week)) // pin the (invisible) pager each frame so its
        // own snap/decelerate animation can't diverge → twitch
    }

    /// Convert one step of a TOUCH pinch (SwiftUI MagnifyGesture's cumulative magnification
    /// RATIO) into an `onMagnify` delta: the LOG of the ratio, scaled so a finger-spread of
    /// `spreadPerLevel`× crosses exactly one zoom level. The log keeps pinch-in and pinch-out
    /// symmetric — linear ratio differences are not (doubling the spread adds +1.0 while
    /// halving adds only −0.5, which made touch zoom-in twitchy and zoom-out unreachable).
    public func pinchDelta(ratio: CGFloat, spreadPerLevel: CGFloat) -> CGFloat {
        guard ratio > 0, spreadPerLevel > 1 else { return 0 }
        return CGFloat(log(Double(ratio))) / (CGFloat(log(Double(spreadPerLevel))) * Motion.pinchSens)
    }

    /// `fromPanel`: the pinch started over the pinned DASHBOARD PANEL (CalendarView's overlay
    /// gesture), so the pointer's x/y map to a virtual day OUTSIDE the visible window — the
    /// day/week focus capture uses a deliberate target instead (today / block cursor / window
    /// start; see panelPinchRelDom).
    public func onMagnify(delta: CGFloat, at p: CGPoint, began: Bool, ended: Bool,
                          fromPanel: Bool = false) {
        wake()
        if began {
            cancelTween() // clears any held anchor; recapture fresh for this gesture
            anim.monthAnim = nil // a pinch overrides an in-flight month page
            // …and an in-flight DAY page: settle onto the nearest day and clear the anim, so a leftover
            // `daily.anim` can't blank out the other days as we zoom out (dailyFade also guards this).
            if let a = daily.anim {
                let to = daily.dom + a.dir
                if a.p >= 0.5, to >= 1, to <= daysInMonth(year, focus) {
                    daily.dom = to; week = weekFor(dom: daily.dom)
                }
                daily.anim = nil
            }
            magStartZ = z
            magAccum = 0
            captureFocus(at: p, fromPanel: fromPanel)
            captureZoomAnchor(pointerY: fromPanel ? nil : p.y)
        } else if ended {
            tweenZ(to: z.rounded()) // keeps the pinch's anchor through the settle
        } else {
            magAccum += delta
            z = clamp(magStartZ + magAccum * Motion.pinchSens, 0, maxZ)
            applyZoomAnchor(at: z) // hold the centre/now hour across the pinch (no jump)
            pushChrome()
        }
    }

    /// Capture the hour to hold at the viewport centre for the whole of a zoom gesture. It must be held
    /// (not recomputed per frame): near month view `maxScroll → 0` clamps the scroll, so a per-frame
    /// re-derivation would collapse the anchor back to the geometric centre (noon). A view with scroll
    /// freedom (week) has a real focal hour → preserve it. A whole-day-fit view (month) has none → anchor
    /// to the current time, so zooming IN leans toward now (e.g. 11pm → bottom of the timeline).
    func captureZoomAnchor(pointerY: CGFloat? = nil) {
        let tl = timelineInfo(snapshot())
        guard tl.hourH > 0 else { anim.zoomAnchorHour = nil; anim.zoomAnchorY = nil; return }
        if tl.maxScroll >= 1 {
            // Week (has scroll freedom) → a real focal hour: hold the current centre hour.
            anim.zoomAnchorHour = (tlScroll + tl.viewH / 2) / tl.hourH; anim.zoomAnchorY = nil
        } else if weekContainsToday() {
            // Whole-day fit AND we're going into today's week → lean toward the current time (centred).
            anim.zoomAnchorHour = nowFrac(); anim.zoomAnchorY = nil
        } else if let py = pointerY, py > tl.tlTop, py < tl.tlBottom {
            // Whole-day fit, another week → anchor the hour under the cursor and keep it under the cursor.
            anim.zoomAnchorHour = (py - tl.tlTop + tl.scroll) / tl.hourH; anim.zoomAnchorY = py
        } else {
            anim.zoomAnchorHour = 12; anim.zoomAnchorY = nil // no pointer over the timeline → neutral midday centre
        }
    }

    /// Rescale `tlScroll` so the held anchor hour stays at `anim.zoomAnchorY` (centre if nil) at zoom `newZ`,
    /// clamped in range. The focus-month timeline viewport is stable across the month↔week zoom, so only
    /// `hourH` changes: y = tlTop + hour·hourH − scroll ⇒ scroll = hour·hourH − (anchorY − tlTop).
    func applyZoomAnchor(at newZ: CGFloat) {
        guard let anchor = anim.zoomAnchorHour else { return }
        var g = snapshot(); g.z = newZ
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return }
        let anchorY = anim.zoomAnchorY ?? (tl.tlTop + tl.viewH / 2)
        let clamped = min(max(0, anchor * tl.hourH - (anchorY - tl.tlTop)), tl.maxScroll)
        if clamped != tlScroll {
            tlScroll = clamped; onSetTlScroll?(clamped)
        }
    }

    /// Whether the currently-targeted week window (focus + week) contains today.
    func weekContainsToday() -> Bool {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        guard c.year == year, let cm = c.month, let cd = c.day else { return false }
        return weekContains(cm - 1, cd)
    }

    /// Does the current week window (year/focus/week) show the given day (target month `tm` 0-based,
    /// `td` 1-based)? Assumes the target is in the shown `year`.
    func weekContains(_ tm: Int, _ td: Int) -> Bool {
        let relDom: Int
        if tm == focus {
            relDom = td
        } else if tm == focus - 1 {
            relDom = td - daysInMonth(year, focus - 1)
        } else if tm == focus + 1 {
            relDom = daysInMonth(year, focus) + td
        } else {
            return false
        }
        let d = CGFloat(relDom) - (1 - CGFloat(firstDOW(year, focus)) + week * 7) // vs window start
        return d > -1 && d < 7
    }

    /// Current wall-clock time as a fractional hour (0–24), for anchoring the timeline scroll.
    private func nowFrac() -> CGFloat {
        // The now-line sits at the current instant expressed in the VIEW (main) timezone, so it lines up
        // with events once they're converted into that zone (not the device zone, which may differ).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: DeadlineTZ.iana(mainTz)) ?? .current
        let c = cal.dateComponents([.hour, .minute], from: now)
        return CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60
    }

    /// The relative day-of-month a dashboard-panel pinch zooms toward, replacing the pointer's
    /// virtual (out-of-window) column. Preference: today when the visible week window shows
    /// it; else the keyboard block cursor's day when IT is visible; else the window's first
    /// day. (The caller clamps: leading spillover days can't be zoomed into.)
    private func panelPinchRelDom() -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        if let cm = c.month, let cd = c.day, c.year == year, weekContains(cm - 1, cd),
           let rd = relDomOf(year, focus, year, cm - 1, cd) {
            return rd
        }
        if cursor.keyboardActive, weekContains(cursor.blockMonth, cursor.blockDay),
           let rd = relDomOf(year, focus, year, cursor.blockMonth, cursor.blockDay) {
            return rd
        }
        return Int((1 - CGFloat(firstDOW(year, focus)) + week * 7).rounded()) // window start
    }

    /// Same preference at MONTH level, as a week index: today's week when the shown month
    /// contains today; else the block cursor's week; else the month's first week window.
    private func panelPinchWeekInMonth() -> CGFloat {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        if let cm = c.month, let cd = c.day, c.year == year, cm - 1 == focus {
            return weekFor(dom: cd)
        }
        if cursor.keyboardActive, cursor.blockMonth == focus {
            return weekFor(dom: cursor.blockDay)
        }
        return 0
    }

    func captureFocus(at p: CGPoint, fromPanel: Bool = false) {
        let g = snapshot()
        switch level(z) {
        case 0:
            // Whole band row (incl. the gutter: track names + month name), so a pinch
            // starting over the labels still focuses that month.
            if let m = monthRowAtPoint(p.x, p.y, g) {
                focus = m
                // Carry the quarter's horizontal scroll into the month view (phone overflow;
                // both stay 0 on desktop) so the visible columns don't jump as the pinch
                // crosses into month level — the same seeding `navigate(at:)` does for a tap.
                monthQX = clamp(yearQX.indices.contains(m / 3) ? yearQX[m / 3] : 0,
                                0, yearQuarterMaxX(viewport))
            }
        case 1:
            // Zoom-IN capture: an overflowing month grid (phone) centers the week window on the
            // viewport's visible center day; a fitted grid (desktop) zooms into the week under
            // the pinch point — unless the pinch started over the dashboard PANEL, whose x maps
            // to a virtual column (today's week / cursor's week / first week instead).
            if fromPanel {
                if !carryMonthCenterIntoWeek() {
                    week = panelPinchWeekInMonth()
                }
            } else if !carryMonthCenterIntoWeek(), let w = weekAtPointInMonth(p.x, g) {
                week = CGFloat(w)
            }
            // Zoom-OUT carry (invisible unless the pinch actually leaves month level): land the
            // year with the focus month centered and its quarter showing the same day columns
            // the month shows now — the reverse of case 0's drill-in seeding.
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY)
            carryMonthIntoQuarter()
        case 2:
            // Record the day under the pinch (for a zoom-IN to day view), but DON'T snap `week` to
            // its integer — that would jump a non-aligned 7-day window to the nearest week the moment
            // you start zooming OUT. The fractional window position is preserved through the zoom.
            // A spillover day can't be zoomed into: clamp to the nearest focus-month day, keep focus.
            // Over the dashboard PANEL, the pointer's x maps to a virtual day PAST the window
            // (the "zoom lands on an arbitrary next-week day" bug) → deliberate target instead.
            if fromPanel {
                daily.dom = min(daysInMonth(year, focus), max(1, panelPinchRelDom()))
            } else if let d = dayAtPointInWeek(p.x, g) {
                let rd = relDomOf(year, focus, d.year, d.month, d.day) ?? d.day
                daily.dom = min(daysInMonth(year, focus), max(1, rd))
            }
            // Zoom-OUT carries (invisible unless the pinch leaves week level): the month view
            // centers on the week window's center day, and — should the same pinch continue past
            // month — the year quarter mirrors that month scroll, vertically centered on focus.
            carryWeekCenterIntoMonth()
            carryMonthIntoQuarter()
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY)
        default: break
        }
        pushChrome()
    }
}
