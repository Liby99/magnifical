// Touch paging/scroll drivers for the iPhone calendar — the native-touch twins of the Mac's
// invisible NSScrollView-backed pagers (MonthPager/WeekPager/DayPager in CalendarUI). Same
// architecture: a real (but invisible) SwiftUI ScrollView supplies the physics, we observe the
// content offset and project it onto the engine's state; the engine pins the scroll position
// back through its onSet… closures during flips/zooms. Unlike the Mac there is no AppKit
// catcher forwarding events — these ScrollViews ARE the touch surface (mounted behind the
// non-hit-testing render layers), so iOS's own touch physics and rubber-banding drive the
// engine's overscroll-pull flips directly.
//
// Snap behaviors (MonthPagingBehavior / WeekScrollBehavior / DayScrollBehavior) come from
// CalendarRender, shared verbatim with the Mac so both platforms page with the same feel.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI
import UIKit

/// Mounts the right driver for the current zoom level.
///
/// PHONE V1.4: all four levels. Year = vertical scroll with per-quarter horizontal strips;
/// month = vertical month↕month pager nested with the focused month's horizontal day strip;
/// week = a two-axis window over the month's own days; day = a two-axis full-width day pager
/// (no dashboard panel on the phone — engine.hasDailyDashboard = false pins the split to 1).
/// Level navigation is the two-finger pinch (PhoneCalendarView.pinch → engine.onMagnify)
/// plus empty-space double-taps; the breadcrumb zooms out.
struct PhoneDriverLayer: View {
    let engine: CalendarEngine
    let vp: Viewport
    var frozen = false // a semantic-zoom pinch is in flight (see PhoneCalendarView.pinch)

    var body: some View {
        Group {
            // chrome.level is @Observable and set to the TARGET at tween start, so the driver
            // swaps the moment a zoom begins.
            switch engine.chrome.level {
            case 0: PhoneYearDriver(engine: engine, vp: vp)
            case 1: PhoneMonthDriver(engine: engine, vp: vp)
            case 2: PhoneWeekDriver(engine: engine, vp: vp, frozen: frozen)
            default: PhoneDayDriver(engine: engine, vp: vp, frozen: frozen)
            }
        }
        // Two fingers down for the pinch must NOT also pan the drivers. A driver that mounts
        // MID-pinch (the level flips at z 1.5) captures the still-down fingers as a scroll:
        // phase `interacting` clears its pendingRestore guard and mirrors whatever offset the
        // fresh ScrollView happens to have — 0, the month's first days — into the engine,
        // yanking the just-carried week window to the month start on every zoom-in.
        .scrollDisabled(frozen)
    }
}

/// Year view: vertical scroll over the 12-month column (overscroll at the top/bottom edge
/// arms the year flip), with each QUARTER hosting its own nested horizontal ScrollView —
/// on the phone the min-width day cells (Layout.yearMinDayW) overflow the screen, and the
/// quarter strips scroll independently (engine.setYearQuarterScroll → SceneInput.yearQX).
/// UIKit's nested-scroll arbitration axis-locks vertical vs horizontal drags natively.
private struct PhoneYearDriver: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()
    /// iOS auto-extends a ScrollView that touches the status-bar edge and compensates with a
    /// top CONTENT INSET (~59pt under a Dynamic Island). All engine mirroring + strip layout
    /// below works in INSET-ADJUSTED space (0 = scrolled to top), or the whole render would
    /// draw ~59pt below the touch strips (phantom top gap + off-by-a-quarter swipes).
    @State private var topInset: CGFloat = 0
    /// Restore target on (re)mount. Until the ScrollView reaches it (or the user grabs the
    /// view), geometry callbacks are NOT mirrored into the engine — a fresh ScrollView fires
    /// an initial offset-0 callback BEFORE the restore pin lands, which would overwrite the
    /// engine's remembered scroll (year view "jumping back to January" after a month trip).
    @State private var pendingRestore: CGFloat?

    var body: some View {
        let quarterH = Layout.qHeaderH + 3 * Layout.monthH
        let gridW = max(1, vp.w - Layout.labelW)
        let maxScroll = max(0, yearMaxScroll(vp))
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: vp.h + maxScroll)
                ForEach(0 ..< 4, id: \.self) { q in
                    // Content y is in RAW content space, which displays topInset lower than
                    // the canvas's geometry space — subtract it so strip q sits exactly over
                    // the rendered quarter q at every scroll position.
                    quarterStrip(q, quarterH: quarterH, gridW: gridW)
                        .offset(x: Layout.padLeft + Layout.labelW,
                                y: Layout.yearTop + CGFloat(q) * (quarterH + Layout.qGap) - topInset)
                }
            }
        }
        .scrollPosition($pos)
        // A freshly-mounted ScrollView starts at the engine's remembered scroll (July stays
        // centered after a month round-trip). This is INITIAL-LAYOUT state — an imperative
        // scrollTo in onAppear races the attachment and can silently drop, leaving the view
        // at offset 0 (January) while the engine says July.
        .defaultScrollAnchor(UnitPoint(x: 0, y: maxScroll > 0 ? min(max(engine.scrollY / maxScroll, 0), 1) : 0))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentInsets.top }) { _, v in
            topInset = v
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            if let target = pendingRestore {
                if abs(y - target) < 1 {
                    pendingRestore = nil // restore landed → mirror live
                } else {
                    // Not landed yet — RE-PIN rather than just ignoring: the one-shot restore
                    // can drop silently (mount races, mid-zoom layout), and the next touch
                    // would then clear the guard and mirror a stale offset into the engine
                    // (the "view jumps to the start" family of bugs). Re-pinning on every
                    // blocked callback converges the strip onto the engine before that.
                    pos.scrollTo(y: target)
                    return
                }
            }
            engine.setYearScroll(y)
        }
        // NOTE: no begin/endYearScrollGesture here — those arm the overscroll year FLIP,
        // which is disabled on the phone for now (edge pulls just rubber-band back).
        .onScrollPhaseChange { _, new in
            // An actual DRAG makes the user's offset truth. (Not .tracking — a mere touch-down
            // grazing a freshly-mounted strip must not bless a restore that hasn't landed yet.)
            if new == .interacting {
                pendingRestore = nil
            }
        }
        .onAppear {
            let p = $pos
            pendingRestore = engine.scrollY
            p.wrappedValue.scrollTo(y: engine.scrollY)
            engine.onSetYearScroll = { y in p.wrappedValue.scrollTo(y: y) }
        }
    }

    /// One quarter's horizontal driver: an invisible 31-day-wide strip (header + 3 month
    /// bands tall). Its content offset mirrors into the engine, which shifts that quarter's
    /// grid while the month names (gutter) stay put.
    private func quarterStrip(_ q: Int, quarterH: CGFloat, gridW: CGFloat) -> some View {
        QuarterStrip(engine: engine, q: q, contentW: 31 * yearDayW(vp), viewportW: gridW)
            .frame(width: gridW, height: quarterH)
    }
}

/// A quarter strip's ScrollView with its own position state, so re-entering year view
/// (or remounting after a month round-trip) restores the engine's stored offset instead
/// of snapping the strip back to day 1 while the render stays put.
private struct QuarterStrip: View {
    let engine: CalendarEngine
    let q: Int
    let contentW: CGFloat
    let viewportW: CGFloat
    @State private var pos = ScrollPosition()
    @State private var pendingRestore: CGFloat? // see PhoneYearDriver — same remount race

    var body: some View {
        let maxX = max(0, contentW - viewportW)
        ScrollView(.horizontal) {
            Color.clear.frame(width: contentW).frame(maxHeight: .infinity)
        }
        .scrollPosition($pos)
        // Initial-layout restore of the engine's stored offset (see PhoneYearDriver).
        .defaultScrollAnchor(UnitPoint(
            x: maxX > 0 ? min(max((engine.yearQX.indices.contains(q) ? engine.yearQX[q] : 0) / maxX, 0), 1) : 0,
            y: 0
        ))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x + $0.contentInsets.leading }) { _, x in
            if let target = pendingRestore {
                if abs(x - target) < 1 {
                    pendingRestore = nil
                } else {
                    pos.scrollTo(x: target) // re-pin until landed (see PhoneYearDriver)
                    return
                }
            }
            engine.setYearQuarterScroll(q, x)
        }
        .onScrollPhaseChange { _, new in
            if new == .interacting { // drag only — see PhoneYearDriver
                pendingRestore = nil
            }
        }
        .onAppear {
            let x = engine.yearQX.indices.contains(q) ? engine.yearQX[q] : 0
            pendingRestore = x
            pos.scrollTo(x: x)
        }
        // The engine repositioned the quarters (launch: today's column centered in its
        // quarter — goToCurrent("year")) — re-sync the strip. Guarded by pendingRestore so
        // the mirror can't write a stale offset while the pin lands (mount-order safe).
        .onChange(of: engine.chrome.yearResync) { _, _ in
            let x = engine.yearQX.indices.contains(q) ? engine.yearQX[q] : 0
            pendingRestore = x
            pos.scrollTo(x: x)
        }
    }
}

/// Month view: an outer VERTICAL pager (12 pages, one per month — swipe up/down to turn,
/// the Mac's MonthPagingBehavior supplies the feel) nested with an inner HORIZONTAL strip
/// over the focused month's 31 min-width day columns. UIKit's nested-scroll arbitration
/// axis-locks the two: vertical pans page months, horizontal pans scroll days.
private struct PhoneMonthDriver: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()
    @State private var topInset: CGFloat = 0 // see PhoneYearDriver — same adjusted-space contract
    @State private var pendingRestore: CGFloat? // see PhoneYearDriver — same remount race

    var body: some View {
        let pageH = vp.h
        let gridW = max(1, vp.w - Layout.labelW)
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0 ..< 12, id: \.self) { m in
                        Color.clear.frame(maxWidth: .infinity).frame(height: pageH).id(m)
                    }
                }
                .scrollTargetLayout()
                // The day strip rides the FOCUSED page (chrome.focus is @Observable, so a
                // completed page turn re-seats it). Content space is raw — subtract the
                // auto content inset like the year driver's quarter strips.
                MonthHStrip(engine: engine, vp: vp)
                    .frame(width: gridW, height: pageH)
                    .offset(x: Layout.padLeft + Layout.labelW,
                            y: CGFloat(engine.chrome.focus) * pageH - topInset)
            }
        }
        .scrollPosition($pos)
        // Initial-layout landing on the focused month's page (see PhoneYearDriver): content
        // is 12 pages, scrollable range 11 — fraction focus/11 puts page `focus` at the top.
        .defaultScrollAnchor(UnitPoint(x: 0, y: CGFloat(engine.focus) / 11))
        .scrollTargetBehavior(MonthPagingBehavior()) // one gesture = at most one month
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentInsets.top }) { _, v in
            topInset = v
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            if let target = pendingRestore {
                if abs(y - target) < 1 {
                    pendingRestore = nil
                } else {
                    pos.scrollTo(y: target) // re-pin until landed (see PhoneYearDriver)
                    return
                }
            }
            engine.setMonthProgress(y, pageH: pageH)
        }
        .onScrollPhaseChange { old, new in
            if new == .interacting { // drag only — see PhoneYearDriver
                pendingRestore = nil
            }
            if new == .interacting || new == .tracking {
                engine.beginMonthGesture()
            } else if old == .interacting || old == .tracking {
                engine.endMonthGesture()
            }
        }
        .onAppear {
            let p = $pos
            let target = CGFloat(engine.focus) * pageH
            pendingRestore = target
            p.wrappedValue.scrollTo(y: target)
            engine.onSetMonthPage = { m in p.wrappedValue.scrollTo(y: CGFloat(m) * pageH) }
        }
        // A boundary flip changed year+focus without leaving month view — land on the new focus.
        .onChange(of: engine.chrome.monthResync) { _, _ in
            pos.scrollTo(y: CGFloat(engine.focus) * pageH)
        }
    }
}

/// The focused month's horizontal day-column driver (nested inside PhoneMonthDriver's
/// vertical pager). Mirrors into engine.setMonthHScroll, which shifts the whole month
/// scene (band lanes, day headers, timeline columns, events) while the gutter stays.
private struct MonthHStrip: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()
    @State private var pendingRestore: CGFloat? // see PhoneYearDriver — same remount race

    var body: some View {
        let contentW = 31 * yearDayW(vp)
        let maxX = max(0, contentW - max(1, vp.w - Layout.labelW))
        ScrollView(.horizontal) {
            Color.clear
                .frame(width: contentW)
                .frame(maxHeight: .infinity)
        }
        .scrollPosition($pos)
        // Initial-layout restore of the seeded quarter-offset carry-over (see PhoneYearDriver).
        .defaultScrollAnchor(UnitPoint(x: maxX > 0 ? min(max(engine.monthQX / maxX, 0), 1) : 0, y: 0))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x + $0.contentInsets.leading }) { _, x in
            if let target = pendingRestore {
                if abs(x - target) < 1 {
                    pendingRestore = nil
                } else {
                    // Re-pin until landed: this strip mounts MID-ZOOM (year→month), where the
                    // one-shot restore drops most easily — a stale 0 mirrored on first touch
                    // is exactly the "month view jumps to the start of the month" bug.
                    pos.scrollTo(x: target)
                    return
                }
            }
            engine.setMonthHScroll(x)
        }
        .onScrollPhaseChange { _, new in
            if new == .interacting { // drag only — see PhoneYearDriver
                pendingRestore = nil
            }
        }
        .onAppear {
            // The engine seeded monthQX from the tapped month's quarter offset (navigate) —
            // land the driver there so the first touch doesn't jump the columns.
            pendingRestore = engine.monthQX
            pos.scrollTo(x: engine.monthQX)
        }
    }
}

/// Zero-size probe that flips `isDirectionalLockEnabled` on the enclosing UIScrollView — the
/// iOS twin of the Mac's WeekScrollGrabber introspection. SwiftUI's two-axis ScrollView pans
/// FREELY (diagonal drift: a vertical timeline scroll that wanders sideways also nudges the
/// day window); the UIKit lock makes each drag pick a primary axis at gesture start, so a
/// scroll is either a page (x) or a timeline scroll (y), never a diagonal smear.
private struct DirectionalLockProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        UIView()
    }

    func updateUIView(_ v: UIView, context: Context) {
        DispatchQueue.main.async {
            var s = v.superview
            while let cur = s, !(cur is UIScrollView) {
                s = cur.superview
            }
            if let sv = s as? UIScrollView, !sv.isDirectionalLockEnabled {
                sv.isDirectionalLockEnabled = true
            }
        }
    }
}

/// Week view: one two-axis ScrollView — x is the day window (day-aligned nudges, week-boundary
/// flings, month-edge pulls; Layout.weekDaysVisible cells wide — 3 on the phone), y is the hour
/// timeline. Each drag axis-locks (DirectionalLockProbe); the timeline height is sized at the
/// SETTLED week zoom (the driver mounts mid-zoom, when the live timeline is barely revealed).
private struct PhoneWeekDriver: View {
    let engine: CalendarEngine
    let vp: Viewport
    var frozen = false // pinch in flight — scrolling is disabled by PhoneDriverLayer
    @State private var pos = ScrollPosition()
    /// See PhoneYearDriver — the same remount race, and it BITES HARDER here: this driver
    /// mounts MID-ZOOM (the level flips at z 1.5, while the month↔week blend is on screen), so
    /// an unguarded initial offset-(0,0) callback stomped `week` to 0 — the render lurched to
    /// the month's LEFT-MOST window (leading spillover) and then fought the restore pin,
    /// flickering — and the stomped `week` poisoned the next zoom-out's centering carry too.
    @State private var pendingRestore: CGPoint?

    var body: some View {
        let gridW = max(1, vp.w - Layout.labelW)
        let dayW = gridW / Layout.weekDaysVisible
        // MONTH-BOUNDED strip: the content is the focus month's OWN days only — no neighbor
        // spillover slots — so the scroll physically cannot leave the month and both edges get
        // UIKit's native rubber-band. Strip-local day 0 is the month's day 1, which sits at
        // engine week-grid slot `fdow`; the ±fdow·dayW shift converts both ways.
        let fdow = CGFloat(firstDOW(engine.chrome.year, engine.chrome.focus))
        let dim = CGFloat(daysInMonth(engine.chrome.year, engine.chrome.focus))
        let stripX = { (w: CGFloat) in w * 7 * dayW - fdow * dayW } // engine week → strip offset
        let maxDay = max(0, dim - Layout.weekDaysVisible) // strip-local last window start
        let maxX = max(0, dim * dayW - gridW)
        let maxY = max(0, engine.timelineMaxScroll(atZ: 2)) // settled-week height, not mid-zoom
        ScrollView([.horizontal, .vertical]) {
            Color.clear
                .frame(width: dim * dayW,
                       height: vp.h + maxY)
                .scrollTargetLayout()
                .background(DirectionalLockProbe())
        }
        .scrollPosition($pos)
        // Initial-layout restore of the seeded window position (see PhoneYearDriver: the
        // imperative scrollTo alone races the attachment and can silently drop).
        .defaultScrollAnchor(UnitPoint(
            x: maxX > 0 ? min(max(stripX(engine.week) / maxX, 0), 1) : 0,
            y: maxY > 0 ? min(max(engine.tlScroll / maxY, 0), 1) : 0
        ))
        .scrollTargetBehavior(WeekScrollBehavior(dayW: dayW, maxDay: maxDay,
                                                 liveDay: { MainActor.assumeIsolated { engine.week * 7 - fdow } }))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .frame(width: gridW, height: vp.h)
        .offset(x: Layout.padLeft + Layout.labelW)
        .onScrollGeometryChange(for: CGPoint.self,
                                of: { CGPoint(x: $0.contentOffset.x, y: $0.contentOffset.y) }) { _, o in
            if let t = pendingRestore {
                if abs(o.x - t.x) < 1, abs(o.y - t.y) < 1 {
                    pendingRestore = nil // restore landed → mirror live
                } else {
                    pos.scrollTo(x: t.x, y: t.y) // re-pin until landed (see PhoneYearDriver)
                    return
                }
            }
            engine.setWeekProgress(o.x + fdow * dayW, dayW: dayW)
            engine.setTlScroll(o.y)
        }
        .onScrollPhaseChange { old, new in
            if new == .interacting { // drag only — see PhoneYearDriver
                pendingRestore = nil
            }
            if new == .interacting || new == .tracking {
                engine.beginWeekGesture()
            } else if old == .interacting || old == .tracking {
                engine.endWeekGesture()
            }
        }
        .onAppear {
            let p = $pos
            // Clamp into the strip's reachable range: a week seeded outside the month bounds
            // (any non-pinch entry path) would otherwise pin to a clamped offset that never
            // matches pendingRestore, freezing the mirror until the first touch.
            let target = CGPoint(x: min(max(stripX(engine.week), 0), maxX),
                                 y: min(max(engine.tlScroll, 0), maxY))
            pendingRestore = target
            p.wrappedValue.scrollTo(x: target.x, y: target.y)
            // On this TWO-AXIS ScrollView a single-axis scrollTo ZEROES the other axis —
            // traced live: the pinch's per-frame zoom-anchor y-pins (applyZoomAnchor →
            // onSetTlScroll) marched x to 0 in viewport-sized steps the moment fingers
            // landed, yanking the window to the month start. Every pin names BOTH axes,
            // reading the missing one from the engine's own state (which the strip mirrors).
            // onSetWeekScroll delivers weekOffset(week) = week·7·dayW in ENGINE content space —
            // shift into the strip's month-local space. (fdow/dayW captured at mount: on the
            // phone the focus month can't change while week view is up — flips are disabled —
            // and any level change remounts this driver, re-capturing both.)
            // While a restore is pending, an engine pin REPLACES the restore target: the zoom
            // anchor moves tlScroll every frame of the month→week zoom, and a target frozen at
            // mount would fight those pins — the strip loses, parks at the stale y (often 0),
            // and the first touch mirrors it back as "jump to 12am".
            engine.onSetWeekScroll = { x in
                let t = CGPoint(x: min(max(x - fdow * dayW, 0), maxX),
                                y: min(max(engine.tlScroll, 0), maxY))
                if pendingRestore != nil {
                    pendingRestore = t
                }
                p.wrappedValue.scrollTo(x: t.x, y: t.y)
            }
            engine.onSetTlScroll = { y in
                let t = CGPoint(x: min(max(engine.week * 7 * dayW - fdow * dayW, 0), maxX),
                                y: min(max(y, 0), maxY))
                if pendingRestore != nil {
                    pendingRestore = t
                }
                p.wrappedValue.scrollTo(x: t.x, y: t.y)
            }
        }
        // A month-edge flip re-anchored focus/week — re-sync the strip to the new resting week.
        .onChange(of: engine.chrome.weekResync) { _, _ in
            let t = CGPoint(x: min(max(stripX(engine.week), 0), maxX),
                            y: min(max(engine.tlScroll, 0), maxY))
            if pendingRestore != nil {
                pendingRestore = t
            }
            pos.scrollTo(x: t.x, y: t.y)
        }
        // The mount-time restore can silently drop while the zoom blend is still settling (the
        // PhoneYearDriver race, aggravated by mounting mid-gesture). No phase change can clear
        // the guard while the pinch holds the drivers frozen — so once the fingers lift,
        // re-issue any unlanded restore before the first real touch mirrors a stale offset.
        .onChange(of: frozen) { _, f in
            if !f, let t = pendingRestore {
                pos.scrollTo(x: t.x, y: t.y)
            }
        }
    }
}

/// Day view: an outer HORIZONTAL pager — one page per day of the focus month, native
/// `.paging` (the phone's day column fills the grid, so page == container: the genuine
/// iPhone-home-screen pager — half-screen commit, FAST snap, never more than one page per
/// swipe, hard edges at day 1 / the last day) — nested with an inner vertical timeline
/// ScrollView riding the focused page (PhoneMonthDriver's construction, rotated). UIKit's
/// nested-scroll arbitration axis-locks the two natively, and each ScrollView is SINGLE-
/// axis, so the two-axis hazards (a one-axis pin zeroing the other; a custom snap target
/// re-routing the other axis's momentum) vanish by construction. The previous one-ScrollView
/// two-axis build snapped pages through a custom target, and SwiftUI kept the NATURAL
/// fling's settle duration while traveling only one page — the "huge momentum, page crawls"
/// feel this replaces.
private struct PhoneDayDriver: View {
    let engine: CalendarEngine
    let vp: Viewport
    var frozen = false // pinch in flight — scrolling is disabled by PhoneDriverLayer
    @State private var pos = ScrollPosition()
    @State private var pendingRestore: CGFloat? // see PhoneYearDriver — same remount race

    var body: some View {
        let gridW = max(1, vp.w - Layout.labelW)
        let dayW = max(1, engine.daily.frac * gridW) // frac is pinned to 1 on the phone → dayW == gridW == one page
        let days = max(1, daysInMonth(engine.chrome.year, engine.chrome.focus))
        let maxX = CGFloat(days - 1) * dayW
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0 ..< days, id: \.self) { d in
                        Color.clear.frame(width: dayW).frame(maxHeight: .infinity).id(d)
                    }
                }
                .scrollTargetLayout()
                // The timeline strip rides the FOCUSED day page (chrome.dailyDom is
                // @Observable, so a completed page turn re-seats it — like MonthHStrip).
                DayTimelineStrip(engine: engine, vp: vp)
                    .frame(width: dayW, height: vp.h)
                    .offset(x: CGFloat(engine.chrome.dailyDom - 1) * dayW)
            }
        }
        .scrollPosition($pos)
        // Initial-layout restore of the landing day (see PhoneYearDriver: the imperative
        // scrollTo alone races the attachment and can silently drop).
        .defaultScrollAnchor(UnitPoint(
            x: maxX > 0 ? min(max(CGFloat(engine.daily.dom - 1) * dayW / maxX, 0), 1) : 0, y: 0
        ))
        .scrollTargetBehavior(.paging) // NATIVE paging — the authentic pager physics
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .frame(width: gridW, height: vp.h)
        .offset(x: Layout.padLeft + Layout.labelW)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x + $0.contentInsets.leading }) { _, x in
            if let t = pendingRestore {
                if abs(x - t) < 1 {
                    pendingRestore = nil // restore landed → mirror live
                } else {
                    pos.scrollTo(x: t) // re-pin until landed (see PhoneYearDriver)
                    return
                }
            }
            engine.setDayProgress(x)
        }
        .onScrollPhaseChange { old, new in
            if new == .interacting { // drag only — see PhoneYearDriver
                pendingRestore = nil
            }
            if new == .interacting || new == .tracking {
                engine.beginDayGesture()
            } else if old == .interacting || old == .tracking {
                engine.endDayGesture()
            }
        }
        .onAppear {
            let target = min(max(CGFloat(engine.daily.dom - 1) * dayW, 0), maxX)
            pendingRestore = target
            pos.scrollTo(x: target)
        }
        // Jump-to-today / zoom-in landing / split change — re-sync the pager to the day.
        .onChange(of: engine.chrome.dailyResync) { _, _ in
            let x = min(max(CGFloat(engine.daily.dom - 1) * dayW, 0), maxX)
            pendingRestore = x
            pos.scrollTo(x: x)
        }
        // Restore retry once a pinch's freeze lifts (see PhoneWeekDriver).
        .onChange(of: frozen) { _, f in
            if !f, let t = pendingRestore {
                pos.scrollTo(x: t)
            }
        }
    }
}

/// The focused day's vertical hour-timeline driver, nested inside PhoneDayDriver's pager —
/// single-axis, so its momentum is fully native and the engine's timeline pins
/// (`onSetTlScroll`, e.g. the pinch zoom-anchor) can't touch the day pager's x.
private struct DayTimelineStrip: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()
    @State private var pendingRestore: CGFloat? // see PhoneYearDriver — same remount race

    var body: some View {
        let maxY = max(0, engine.timelineMaxScroll(atZ: 3)) // settled-day height, not mid-zoom
        ScrollView(.vertical) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: vp.h + maxY)
        }
        .scrollPosition($pos)
        .defaultScrollAnchor(UnitPoint(x: 0, y: maxY > 0 ? min(max(engine.tlScroll / maxY, 0), 1) : 0))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            if let t = pendingRestore {
                if abs(y - t) < 1 {
                    pendingRestore = nil
                } else {
                    pos.scrollTo(y: t) // re-pin until landed (see PhoneYearDriver)
                    return
                }
            }
            engine.setTlScroll(y)
        }
        .onScrollPhaseChange { _, new in
            if new == .interacting { // drag only — see PhoneYearDriver
                pendingRestore = nil
            }
        }
        .onAppear {
            let p = $pos
            let target = min(max(engine.tlScroll, 0), maxY)
            pendingRestore = target
            p.wrappedValue.scrollTo(y: target)
            // Single-axis → safe; and while a restore is pending an engine pin REPLACES the
            // restore target (the zoom anchor moves tlScroll every frame of the week→day
            // zoom — a mount-frozen target would fight it and snap to a stale y on first
            // touch; see PhoneWeekDriver).
            engine.onSetTlScroll = { y in
                let t = min(max(y, 0), maxY)
                if pendingRestore != nil {
                    pendingRestore = t
                }
                p.wrappedValue.scrollTo(y: t)
            }
        }
    }
}
