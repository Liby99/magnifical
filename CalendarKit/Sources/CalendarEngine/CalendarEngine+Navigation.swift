// CalendarEngine+Navigation — zoom + travel choreography: z tweens, jumpToDay's
// fly-out/travel/fly-in, setView/selectYear, wheel routing, the year-view scroll mirror,
// and the year boundary flip.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// Scroll offset that vertically centers month `m`'s band; caller clamps to range.
    func centerScroll(for m: Int) -> CGFloat {
        yearFrame(m, viewport, 0).bandY + 2 * Layout.trackH - viewport.h / 2
    }

    /// ── Year selection (breadcrumb picker) ────────────────────────────────────────
    /// Selectable years: 2024 … systemYear+3, matching the web (CalendarCanvas.tsx).
    public var yearOptions: [Int] {
        Array(2024 ... (systemYear + 3))
    }

    /// Zoom back out to the yearly view (breadcrumb "Year" crumb from a deeper level).
    public func zoomToYear() {
        carryMonthIntoQuarter()
        tweenZ(to: 0)
    }

    /// ── Zoom-out scroll carries (the reverse of navigate's drill-in seeding) ───────────
    /// Mirror the month view's horizontal scroll back to its quarter (phone overflow; both
    /// stay 0 on desktop) so the year view shows the same day columns after a zoom-out.
    func carryMonthIntoQuarter() {
        if yearQX.indices.contains(focus / 3) {
            yearQX[focus / 3] = clamp(monthQX, 0, yearQuarterMaxX(viewport))
        }
    }

    /// Seed the MONTH view's horizontal scroll so the WEEK window's center day lands at the
    /// month viewport's horizontal center (clamped at the strip's ends). Self-neutralizes to 0
    /// wherever the month grid doesn't overflow (desktop: 31 columns always fit), so it's safe
    /// on every zoom-out path. `week·7` is the window's left slot in the month's week grid;
    /// slot → day-of-month shifts by the month's leading spillover (firstDOW).
    func carryWeekCenterIntoMonth() {
        let dayW = monthDayW(viewport, pin: dashPin, frac: dashMonthFrac)
        let gridW = viewport.w - Layout.labelW
        let centerDOM = 1 - CGFloat(firstDOW(year, focus)) + week * 7 + Layout.weekDaysVisible / 2
        monthQX = clamp((centerDOM - 1) * dayW - gridW / 2, 0, max(0, 31 * dayW - gridW))
    }

    /// The INVERSE carry, for a MONTH → WEEK zoom-in on an OVERFLOWING month grid (phone): the
    /// week window centers on the day column at the month viewport's visible center — the zoom
    /// keeps what you're looking at. The window start rounds to a whole day slot (the pager
    /// rests day-aligned) and clamps to the last valid window. Returns false where the grid
    /// FITS the viewport (desktop) — there the caller keeps the pinch-point week capture, whose
    /// "zoom into the week under the fingers" semantic is right when the whole month is visible.
    @discardableResult
    func carryMonthCenterIntoWeek() -> Bool {
        let dayW = monthDayW(viewport, pin: dashPin, frac: dashMonthFrac)
        let gridW = viewport.w - Layout.labelW
        guard 31 * dayW > gridW + 0.5 else { return false }
        let centerSlot = (monthQX + gridW / 2) / dayW + CGFloat(firstDOW(year, focus))
        let b = weekBounds // month-bounded on a partial window: no spillover-day landings
        week = clamp((centerSlot - Layout.weekDaysVisible / 2).rounded() / 7, b.min, b.max)
        return true
    }

    /// Breadcrumb "Month" crumb: jump to the focused month's view. `focus` is already the shown month;
    /// tweenZ sets chrome.level=1 immediately, so the MonthPager re-syncs its page to `focus`.
    public func zoomToMonth() {
        if level(z) >= 2 { // zooming OUT of week/day → keep the window's center day centered
            carryWeekCenterIntoMonth()
        }
        tweenZ(to: 1)
        chrome.monthResync &+= 1 // ensure the pager lands on `focus` even if the level didn't change
    }

    /// Breadcrumb "Week" crumb: jump to the focused week's view. Snap the (possibly fractional) window
    /// to the whole week the crumb names; the WeekPager re-syncs to `week` on the level change.
    public func zoomToWeek() {
        week = week.rounded()
        tweenZ(to: 2)
        chrome.weekResync &+= 1 // ensure the strip lands on `week` even if the level didn't change
    }

    /// "Today" button. Picks the lightest path that lands on today's day view, by where we are now:
    ///   • day view   — same month: scroll the strip to today; else fly out to the year and back in.
    ///   • week view  — today in the week: zoom straight in; same month: scroll to its week then zoom;
    ///                  else fly via the year.
    ///   • month view — today's month: zoom in (week→day); else fly via the year.
    ///   • year view  — zoom straight in.
    /// Cross-year always routes through the year with a SINGLE flip to today's year, then zooms in.
    public func goToToday() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        jumpToDay(c.year ?? year, (c.month ?? 1) - 1, c.day ?? 1)
    }

    /// View ▸ "Go to Current …": land on TODAY's year/month/week/day at the named level (unlike the
    /// breadcrumb zoomTo* funcs, which keep the currently-focused period). Cross-year routes through
    /// selectYear's flip; "day" reuses goToToday's lightest-path logic.
    public func goToCurrent(_ zoom: String) {
        wake()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let ty = c.year ?? year, tm = (c.month ?? 1) - 1, td = c.day ?? 1
        switch zoom.lowercased() {
        case "day":
            goToToday()
        case "week":
            if ty != year {
                selectYear(ty)
            }
            focus = tm
            week = CGFloat(weekOfDate(ty, tm, td))
            daily.dom = td
            zoomToWeek()
        case "month":
            if ty != year {
                selectYear(ty)
            }
            focus = tm
            daily.dom = td
            zoomToMonth()
        default: // "year"
            if ty != year {
                selectYear(ty)
            }
            focus = tm
            // Center TODAY's day column in its quarter strip (phone: the quarters overflow
            // horizontally; clamps to 0 — a no-op — wherever the quarter fits the viewport).
            if yearQX.indices.contains(tm / 3) {
                let gridW = viewport.w - Layout.labelW
                yearQX[tm / 3] = clamp((CGFloat(td) - 0.5) * yearDayW(viewport) - gridW / 2,
                                       0, yearQuarterMaxX(viewport))
                chrome.yearResync &+= 1 // re-sync the quarter strips to the new offset
            }
            zoomToYear()
            ensureMonthVisible(tm, animated: true) // glide the year scroll so the current month shows
        }
    }

    /// The general "fly to a specific day" animation (goToToday is `jumpToDay(today)`). `onLand` fires
    /// once it finally settles at that day's view — used to open the NOTE tab for a daily-note todo.
    /// Target month `tm` is 0-based; `td` is 1-based day-of-month.
    public func jumpToDay(_ ty: Int, _ tm: Int, _ td: Int, onLand: (() -> Void)? = nil) {
        wake()
        let tWeek = CGFloat((firstDOW(ty, tm) + td - 1) / 7)
        cancelTween(); anim.flipAnim = nil
        anim.zTweenDone = nil; anim.weekTweenDone = nil; anim.flipDone = nil; anim.scrollTweenDone = nil
        anim.weekLandDone = nil; anim.monthLandDone = nil; anim.monthGlide = nil // supersede other jumps
        anim.dayLandDone = onLand

        // At the year layout: set focus/week/day, GLIDE the vertical scroll to centre the target month
        // (avoids the old instant snap), then zoom in. Used by every path that routes through the year.
        let flyFromYear: () -> Void = { [weak self] in
            guard let self else { return }
            self.placeDayAtYear(ty, tm, td, tWeek)
            let target = clamp(self.centerScroll(for: tm), 0, yearMaxScroll(self.viewport))
            if abs(target - self.scrollY) < 1 {
                self.tweenZ(to: 3, dur: Motion.flyInFarDur) // already centred → zoom straight in
            } else {
                self.anim.scrollTween = Tween(
                    from: self.scrollY,
                    to: target,
                    start: Date(),
                    duration: Motion.yearGlideDur,
                    ease: easeInOut
                )
                self.anim.scrollTweenDone = { [weak self] in self?.tweenZ(to: 3, dur: Motion.flyInFarDur) }
            }
        }
        let flyOutThenIn: () -> Void = { [weak self] in // zoom OUT to the year, then fly in
            guard let self else { return }
            if self.level(self.z) == 0 {
                flyFromYear()
            } else {
                self.anim.zTweenDone = flyFromYear; self.tweenZ(to: 0, dur: Motion.flyOutDur)
            }
        }

        // ── Cross-year: out to the year, ONE flip to the target year (skips intervening years), then in. ──
        if ty != year {
            let dir = ty > year ? 1 : -1
            let startFlip: () -> Void = { [weak self] in
                guard let self else { return }
                self.anim.flipDone = flyFromYear
                self.anim.flipAnim = FlipAnim(
                    dir: dir,
                    fromYear: self.year,
                    toYear: ty,
                    startScroll: self.scrollY,
                    start: Date()
                )
            }
            if level(z) == 0 {
                startFlip()
            } else {
                anim.zTweenDone = startFlip; tweenZ(to: 0, dur: Motion.flyOutDur)
            }
            return
        }

        // ── Same year. ──
        let sameMonth = focus == tm
        switch level(z) {
        case 3: // day view
            if sameMonth { // glide the day strip to the target (no zoom out)
                if daily.dom == td {
                    fireDayLand(); break
                }
                let dist = abs(td - daily.dom)
                anim.dayTween = Tween(from: CGFloat(daily.dom), to: CGFloat(td), start: Date(),
                                      duration: min(
                                          Motion.dayGlideMax,
                                          Motion.dayGlideBase + Motion.dayGlidePerDay * Double(dist)
                                      ), ease: easeInOut)
            } else {
                flyOutThenIn()
            }
        case 2: // week view
            if weekContains(tm, td) { // target is on screen → zoom straight into it
                daily.dom = td; pushChrome(); chrome.dailyResync &+= 1
                tweenZ(to: 3, dur: Motion.flyInNearDur)
            } else if sameMonth { // scroll to its week, then zoom in
                daily.dom = td
                anim.weekTween = Tween(
                    from: week,
                    to: tWeek,
                    start: Date(),
                    duration: Motion.weekGlideDur,
                    ease: easeInOut
                )
                anim.weekTweenDone = { [weak self] in self?.tweenZ(to: 3, dur: Motion.flyInNearDur) }
            } else {
                flyOutThenIn()
            }
        case 1: // month view
            if sameMonth { // zoom in through the week into the day
                week = tWeek; daily.dom = td
                pushChrome(); chrome.weekResync &+= 1; chrome.dailyResync &+= 1
                tweenZ(to: 3, dur: Motion.flyInMidDur)
            } else {
                flyOutThenIn()
            }
        default: // year view → straight in
            flyFromYear()
        }
    }

    /// Set focus/week/day + year to the target at the year layout. The vertical scroll is glided by the
    /// caller (flyFromYear) rather than snapped, so entering the year view doesn't jump.
    private func placeDayAtYear(_ ty: Int, _ tm: Int, _ td: Int, _ tWeek: CGFloat) {
        year = ty; focus = tm; week = tWeek; daily.dom = td
        daily.anim = nil; anim.monthAnim = nil; anim.weekTween = nil; anim.weekFlip = nil
        pushChrome()
        chrome.monthResync &+= 1; chrome.weekResync &+= 1; chrome.dailyResync &+= 1
    }

    /// Programmatic view navigation for the assistant's `set_view` tool. Mirrors the web set_view:
    /// optionally switch year, focus a month (0-based), and/or zoom to a named level. Unspecified
    /// arguments are left unchanged. UI-only — moves the view, never mutates data.
    /// ⌘B: toggle the pinned weekly/monthly dashboard. Only meaningful at month/week zoom — day
    /// view forces the panel out regardless, and the year view has no panel — so other levels
    /// no-op (per spec) rather than silently flipping hidden state.
    public func toggleDashPin() {
        let lv = level(z)
        guard lv == 1 || lv == 2 else { return }
        dashPinned.toggle()
        UserDefaults.standard.set(dashPinned, forKey: PrefKeys.dashPinned)
        anim.dashPinTween = Tween(from: dashPin, to: dashPinned ? 1 : 0,
                                  start: Date(), duration: Motion.dashPinDur, ease: easeInOut)
        chrome.dashPinned = dashPinned
        if dashPinned {
            chrome.dashPresented = true // pin ON: present immediately (retract clears on tween end)
        }
        wake()
    }

    /// Programmatic pin (no toggle semantics, valid at any level): make sure the ⌘B panel is out —
    /// e.g. landing on a weekly/monthly note from a gantt row must arrive with the panel open.
    public func pinDashboard() {
        guard !dashPinned else { return }
        dashPinned = true
        UserDefaults.standard.set(true, forKey: PrefKeys.dashPinned)
        anim.dashPinTween = Tween(from: dashPin, to: 1, start: Date(), duration: Motion.dashPinDur,
                                  ease: easeInOut)
        chrome.dashPinned = true
        chrome.dashPresented = true
        wake()
    }

    /// Land on the WEEK VIEW containing (year, month, dom) — the "go to this weekly note" jump.
    /// `onLand` fires once the zoom settles at week level (jumpToWeek always ends in a z tween,
    /// even from week level, so the completion hook in sceneInput always reaches it).
    public func jumpToWeek(_ ty: Int, _ m0: Int, _ dom: Int, onLand: (() -> Void)? = nil) {
        wake()
        anim.dayLandDone = nil; anim.monthLandDone = nil; anim.monthGlide = nil // supersede other jumps
        anim.weekLandDone = onLand
        if ty != year {
            selectYear(ty)
        }
        let m = max(0, min(11, m0))
        focus = m
        week = CGFloat(weekOfDate(ty, m, max(1, min(daysInMonth(ty, m), dom))))
        chrome.monthResync &+= 1; chrome.weekResync &+= 1
        tweenZ(to: 2)
        pushChrome()
    }

    /// Land on the MONTH VIEW showing (year, month) — the "go to this monthly note" jump. Already
    /// resting at month level in the same year → an ANIMATED month glide (fast pagination toward
    /// the target, not a snap). Cross-year or from another level → the setView path (year flip /
    /// zoom), whose final z tween fires the landing. `onLand` fires once the month view settles.
    public func jumpToMonth(_ ty: Int, _ m0: Int, onLand: (() -> Void)? = nil) {
        wake()
        anim.dayLandDone = nil; anim.weekLandDone = nil // supersede other jumps
        anim.monthLandDone = onLand
        let m = max(0, min(11, m0))
        if ty == year, level(z) == 1, anim.tween == nil, !isMonthFlipping {
            if focus == m, anim.monthAnim == nil, anim.monthGlide == nil {
                fireMonthLand() // already resting on the target month
                return
            }
            // Glide from the CURRENT continuous position (mid page-turn included) to the target.
            let from = CGFloat(focus) + (anim.monthAnim.map { CGFloat($0.dir) * $0.p } ?? 0)
            anim.monthGlide = Tween(
                from: from, to: CGFloat(m), start: Date(),
                duration: min(Motion.monthGlideMax,
                              Motion.monthGlideBase + Motion.monthGlidePerPage * Double(abs(from - CGFloat(m)))),
                ease: easeInOut
            )
            return
        }
        setView(year: ty, zoom: "month", focusedMonth: m)
        if level(z) == 1, anim.tween == nil {
            fireMonthLand() // setView had no zoom to run (e.g. cross-year at month level, flip only)
        }
    }

    public func setView(year targetYear: Int? = nil, zoom: String? = nil, focusedMonth: Int? = nil,
                        day: Int? = nil) {
        wake()
        // A concrete day → fly straight there (jumpToDay handles cross-year travel, focus, and
        // landing in the day view). The day IS the destination; other args just refine it.
        if let d = day {
            let ty = targetYear ?? year
            let m = max(0, min(11, focusedMonth ?? focus))
            jumpToDay(ty, m, max(1, min(daysInMonth(ty, m), d)))
            return
        }
        if let ty = targetYear, ty != year {
            selectYear(ty)
        }
        if let m = focusedMonth, (0 ... 11).contains(m) {
            focus = m
            chrome.monthResync &+= 1 // land the pager on the newly-focused month
        }
        switch zoom?.lowercased() {
        case "year": zoomToYear()
        case "month": zoomToMonth()
        case "week": zoomToWeek()
        case "day": tweenZ(to: 3)
        default: break
        }
    }

    /// Jump to another calendar year. Resets vertical scroll to the top, like the web's selectYear.
    public func selectYear(_ y: Int) {
        guard y != year, !isFlipping else { return }
        wake()
        // Don't swap instantly: fade the whole year out, swap the data at the midpoint, fade
        // the new year in (a pure cross-fade, no scroll motion — see advanceFlip's fadeOnly path).
        anim.flipAnim = FlipAnim(dir: 0, fromYear: year, toYear: y, startScroll: scrollY, start: Date(), fadeOnly: true)
    }

    /// ── Levels + anim.tween helpers ────────────────────────────────────────────────────
    func level(_ z: CGFloat) -> Int {
        z < 0.5 ? 0 : (z < 1.5 ? 1 : (z < 2.5 ? 2 : 3))
    }

    func pushChrome(level lvl: Int? = nil) {
        // Assign only on change: @Observable fires on every SET (not just changes), so writing the
        // same value still invalidates readers. During a week scroll `week` changes every frame but
        // year/focus/level don't — deduping keeps the WeekPager (which reads year/focus) from
        // re-rendering per frame and re-applying `.scrollPosition`, which would jump the scroll.
        let newLevel = lvl ?? level(z)
        if chrome.level != newLevel {
            chrome.level = newLevel
        }
        if chrome.year != year {
            chrome.year = year
        }
        if chrome.focus != focus {
            chrome.focus = focus
        }
        if chrome.week != Double(week) {
            chrome.week = Double(week)
        }
        if chrome.dailyDom != daily.dom {
            chrome.dailyDom = daily.dom
        }
        // Breadcrumb "most visible" month/day: once a month page (or day page) is more than halfway in,
        // the crumb shows the incoming one — so it updates mid-animation, not on landing. (A year-edge
        // flip swaps `focus`/`daily.dom` at its own midpoint, so this tracks those too.)
        let df = anim.monthAnim.map { $0.p >= 0.5 ? min(11, max(0, focus + $0.dir)) : focus } ?? focus
        if chrome.displayFocus != df {
            chrome.displayFocus = df
        }
        let dd = daily.anim
            .map { $0.p >= 0.5 ? min(daysInMonth(year, focus), max(1, daily.dom + $0.dir)) : daily.dom } ?? daily.dom
        if chrome.displayDom != dd {
            chrome.displayDom = dd
        }
    }

    func cancelTween() {
        if let t = anim.tween {
            z = t.value(at: Date()); anim.tween = nil
            // A zoom interrupted in its last breath settles ON the level: leaving z at e.g. 2.9885
            // is visually identical to 3 but breaks exact-rest consumers (the day-note editor's
            // scopeT gate wedged on it; the gutter z-fade would idle at ~0.04%).
            if abs(z - z.rounded()) < 0.02 {
                z = z.rounded()
            }
        }
        if let st = anim.scrollTween {
            scrollY = st.value(at: Date()); anim.scrollTween = nil
        }
        if let wt = anim.weekTween {
            week = wt.value(at: Date()); anim.weekTween = nil
        }
        if anim.dayTween != nil {
            anim.dayTween = nil; daily.anim = nil
        } // settle a day-glide on its current day
        if anim.monthGlide != nil {
            anim.monthGlide = nil; anim.monthAnim = nil
            chrome.monthResync &+= 1 // re-sync the pager strip to wherever the glide was cut
        }
        // A manual navigation takes over → any pending jump landing is superseded (a stale land
        // callback would otherwise fire on the USER's next arrival at that level and hijack it).
        anim.dayLandDone = nil; anim.weekLandDone = nil; anim.monthLandDone = nil
        anim.zoomAnchorHour = nil; anim.zoomAnchorY = nil // interrupted zoom → drop the anchor; next zoom recaptures
        snapWork?.cancel()
    }

    // (zoom anchor helpers live near sceneInput)

    func scheduleWeekSnap(_ bounds: (min: CGFloat, max: CGFloat)) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let target = clamp((self.week * 7).rounded() / 7, bounds.min, bounds.max)
            self.anim.weekTween = Tween(
                from: self.week,
                to: target,
                start: Date(),
                duration: Motion.weekSnapDur,
                ease: easeInOut
            )
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    public func tweenZ(to target: CGFloat, dur: TimeInterval? = nil) {
        wake()
        if anim.zoomAnchorHour == nil {
            captureZoomAnchor()
        } // fresh for a button/click zoom; kept for a pinch settle
        anim.tween = Tween(
            from: z,
            to: clamp(target, 0, 3),
            start: Date(),
            duration: dur ?? Motion.zoomDur,
            ease: easeInOut
        )
        pushChrome(level: level(clamp(target, 0, 3)))
    }

    /// ── Gestures ──────────────────────────────────────────────────────────────────
    public func onWheel(dx: CGFloat, dy: CGFloat) {
        wake()
        let b = level(z)
        if b == 0 { // fallback; the NSScrollView normally drives year scroll
            setYearScroll(clamp(scrollY - dy, 0, yearMaxScroll(viewport)))
            return
        }
        cancelTween()
        if abs(dy) >= abs(dx) {
            // Fallback only; the invisible NSScrollView driver normally drives the timeline scroll.
            tlScroll = min(max(0, tlScroll - dy), timelineInfo(snapshot()).maxScroll)
        } else if b == 2 {
            anim.weekTween = nil
            let bounds = weekBounds
            // px per WEEK of travel = 7·dayW (the grid is weekDaysVisible day cells wide).
            let weekSpanPx = (viewport.w - Layout.labelW) * 7 / Layout.weekDaysVisible
            week = clamp(week - dx / weekSpanPx, bounds.min, bounds.max) // swipe-left → later days
            scheduleWeekSnap(bounds)
        } else if b == 3 {
            scroll.wheelAccumX += dx
            if abs(scroll.wheelAccumX) > 55 {
                daily.dom = min(daysInMonth(year, focus), max(
                    1,
                    daily.dom + (scroll.wheelAccumX < 0 ? 1 : -1)
                )) // swipe-left → next day
                scroll.wheelAccumX = 0
            }
        }
        pushChrome()
    }

    /// Content-offset x of the week pager that shows fractional week `w` (= `w · 7 · dayW`, where
    /// dayW = (viewport.w − labelW) / weekDaysVisible — the visible window is weekDaysVisible cells,
    /// so on desktop (7 visible) this reduces to `w · (viewport.w − labelW)`).
    func weekOffset(_ w: CGFloat) -> CGFloat {
        w * max(0, viewport.w - Layout.labelW) * 7 / Layout.weekDaysVisible
    }

    public var timelineMaxScroll: CGFloat {
        timelineInfo(snapshot()).maxScroll
    }

    /// The timeline's max scroll AT a given zoom, independent of the current (possibly mid-
    /// transition) z. The phone's week/day drivers mount MID-ZOOM and size their scrollable
    /// height once — sizing from the live `timelineMaxScroll` baked in the partially-revealed
    /// timeline's (much smaller) range, leaving the vertical scroll permanently truncated
    /// ("sticky" — the rubber band hit far above the timeline's real bottom).
    public func timelineMaxScroll(atZ zz: CGFloat) -> CGFloat {
        var g = snapshot()
        g.z = zz
        return timelineInfo(g).maxScroll
    }

    /// Mirror the driver's live offset (may be < 0 or > maxScroll during the elastic bounce — that
    /// overscroll is exactly what we render). Only meaningful in week/day view.
    public func setTlScroll(_ y: CGFloat) {
        wake(); tlScroll = y
    }

    /// ── Year-view scroll: mirror of the native NSScrollView driver ───────────────────
    public var isYearLevel: Bool {
        level(z) == 0
    }

    /// Fingers-down phase begins. Record whether we were already resting at an edge —
    /// a flip is only allowed for a pull that STARTS from the edge (not a fast scroll
    /// from the middle that happens to overshoot into it).
    public func beginYearScrollGesture() {
        wake()
        scroll.liveScrolling = true
        let maxY = yearMaxScroll(viewport)
        scroll.startedAtTop = scrollY <= 2
        scroll.startedAtBottom = scrollY >= maxY - 2
    }

    /// Mirror the scroll view's live offset (may be < 0 or > maxScroll during elastic
    /// overscroll, which is exactly what gives the native bounce). Computes the pull
    /// hint only while a finger-driven gesture is live.
    public func setYearScroll(_ y: CGFloat) {
        wake()
        scrollY = y
        let maxY = yearMaxScroll(viewport)
        let over: CGFloat = y < 0 ? -y : (y > maxY ? y - maxY : 0)
        let atTop = y < 0
        scroll.lastOverscroll = (over, atTop)
        if scroll.liveScrolling, over > 2 {
            let eligible = (atTop && scroll.startedAtTop) || (!atTop && scroll.startedAtBottom)
            let target = atTop ? year - 1 : year + 1
            scroll.yearPull = eligible
                ? YearPull(targetYear: target, atTop: atTop, over: over, armed: over >= Layout.yearFlipOver) : nil
        } else {
            scroll.yearPull = nil
        }
    }

    /// Fingers lifted — if the pull passed the threshold, flip the year (landing on the
    /// continuous edge: prev→bottom, next→top). Otherwise the scroll view bounces back
    /// natively and we do nothing.
    public func endYearScrollGesture() {
        scroll.liveScrolling = false
        scroll.yearPull = nil
        guard yearFlipEnabled, !isFlipping else { return }
        let (over, atTop) = scroll.lastOverscroll
        guard over >= Layout.yearFlipOver else { return }
        guard (atTop && scroll.startedAtTop) || (!atTop && scroll.startedAtBottom)
        else { return } // must start from the edge
        let dir = atTop ? -1 : 1
        let target = year + dir // unbounded — flip any number of years
        anim.flipAnim = FlipAnim(dir: dir, fromYear: year, toYear: target, startScroll: scrollY, start: Date())
    }

    /// Two-phase year-flip transition, evaluated per frame. Phase 1: the outgoing year
    /// keeps scrolling in the pull direction (off-screen) and fades out. Phase 2: the
    /// incoming year slides in from the opposite edge and fades in to its resting edge
    /// (next → Jan at top; prev → Dec at bottom).
    func advanceFlip(_ fa: FlipAnim, at date: Date) {
        // Fade-only (selectYear): cross-fade the whole calendar with no scroll movement —
        // fade the outgoing year to 0, swap year + reset scroll at the midpoint, fade the
        // incoming year back to 1.
        if fa.fadeOnly {
            let t = clamp(CGFloat(date.timeIntervalSince(fa.start) / Motion.yearFadeSwapDur), 0, 1)
            if t >= 1 {
                year = fa.toYear; anim.flipFade = 1; anim.flipAnim = nil
                pushChrome()
                if let cb = anim.flipDone {
                    anim.flipDone = nil; cb()
                }
                return
            }
            if t < 0.5 { // outgoing year fades out
                let p = t / 0.5
                if year != fa.fromYear {
                    year = fa.fromYear; pushChrome()
                }
                anim.flipFade = 1 - easeInOut(p)
            } else { // swap data, incoming year fades in
                let p = (t - 0.5) / 0.5
                if year != fa.toYear {
                    year = fa.toYear; scrollY = 0; onSetYearScroll?(0); pushChrome()
                }
                anim.flipFade = easeInOut(p)
            }
            return
        }
        let vpH = viewport.h
        let maxY = yearMaxScroll(viewport)
        let dir = CGFloat(fa.dir)
        let rest: CGFloat = fa.dir > 0 ? 0 : maxY // where the new year settles
        let t = clamp(CGFloat(date.timeIntervalSince(fa.start) / Motion.yearFlipDur), 0, 1)
        if t >= 1 {
            year = fa.toYear; scrollY = rest; anim.flipFade = 1; anim.flipAnim = nil
            pushChrome(); onSetYearScroll?(rest) // resync the scroll-view driver
            if let cb = anim.flipDone {
                anim.flipDone = nil; cb()
            } // sequenced next phase (go-to-today)
            return
        }
        if t < 0.5 { // outgoing year exits + fades
            let p = t / 0.5
            if year != fa.fromYear {
                year = fa.fromYear; pushChrome()
            }
            scrollY = fa.startScroll + dir * easeInOut(p) * vpH
            anim.flipFade = 1 - p
        } else { // incoming year enters + fades
            let p = (t - 0.5) / 0.5
            if year != fa.toYear {
                year = fa.toYear; pushChrome()
            }
            let enter = rest - dir * vpH // from the opposite edge (off-screen)
            scrollY = enter + (rest - enter) * easeOut(p)
            anim.flipFade = p
        }
    }
}
