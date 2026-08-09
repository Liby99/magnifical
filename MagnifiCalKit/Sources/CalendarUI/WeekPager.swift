// Week window horizontal scrolling, driven by a real (but invisible) SwiftUI ScrollView —
// the horizontal twin of MonthPager. A strip of 1-day cells; a small scroll snaps the 7-day
// window to the nearest DAY, a large (fast) scroll snaps to a WEEK boundary. SwiftUI supplies
// the native deceleration; we observe contentOffset.x and project it onto the engine's `week`.
//
// Month-scoped: the strip is just this month's weeks, so the window can't leave the month yet
// (crossing the edge = a flip, TODO). The AppKit catcher forwards horizontal week-view scroll
// into this ScrollView's backing NSScrollView via `bridge`, axis-locking against the vertical
// hour-timeline scroll.

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// Shared handle between the SwiftUI week driver and the AppKit `CatcherView`. Positioning is
/// IMPERATIVE (scroll the backing NSScrollView), NOT via `.scrollPosition` — a two-way scroll
/// position binding re-renders the pager on every day boundary crossed, re-applying itself
/// mid-scroll and jumping the offset. This way nothing in the pager re-renders while scrolling.
@MainActor final class WeekPagerBridge {
    weak var scrollView: NSScrollView? {
        didSet {
            if let p = pending {
                pending = nil; scrollTo(p)
            }
        }
    }

    private var pending: CGFloat?
    /// The initial engine→scroll-view sync has been APPLIED. Until then the geometry callback must
    /// not write into the engine: a freshly-created pager (window closed and reopened while AT week
    /// level — the engine outlives the window) first reports contentOffset 0, and adopting that
    /// would snap the surviving week back to the month's first week before onAppear positions it.
    private(set) var primed = false
    func scrollTo(_ x: CGFloat) {
        guard let sv = scrollView else { pending = x; return } // not captured yet → apply on capture
        sv.contentView.scroll(to: NSPoint(x: max(0, x), y: 0))
        sv.reflectScrolledClipView(sv.contentView)
        primed = true
    }
}

struct WeekPager: View {
    let engine: CalendarEngine
    let bridge: WeekPagerBridge

    var body: some View {
        GeometryReader { geo in
            // The visible window's grid width (matches the engine's dayW = (vp.w − labelW)/weekDaysVisible).
            let gridW = geo.size.width - Layout.padLeft - Layout.padRight - Layout.labelW
            let dayW = max(1, gridW / Layout.weekDaysVisible)
            // Reactive to the month via @Observable chrome, so the cell count follows weeksInMonth.
            let weeks = max(1, weeksInMonth(engine.chrome.year, engine.chrome.focus))
            let maxDay = max(0, CGFloat(weeks * 7) - Layout.weekDaysVisible)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0 ..< (weeks * 7), id: \.self) { d in
                        Color.clear.frame(width: dayW, height: 1).id(d)
                    }
                }
                .scrollTargetLayout()
                .background(WeekScrollGrabber(bridge: bridge))
            }
            .frame(width: gridW, height: 8) // viewport = one 7-day window
            // liveDay reads the engine's CURRENT week (updated every frame by onScrollGeometryChange)
            // — the true position even mid-animation. Read on the main actor (updateTarget runs there).
            .scrollTargetBehavior(WeekScrollBehavior(
                dayW: dayW, maxDay: maxDay,
                liveDay: { MainActor.assumeIsolated { engine.week * 7 } },
                // The snap decision drives the weekly-dashboard carousel: a hard fling cruises
                // it over the whole glide; a small landing settles a frozen (caught) carousel.
                onTarget: { day, jump in
                    MainActor.assumeIsolated { engine.weekGlideWillLand(atDay: day, weekJump: jump) }
                }
            ))
            .scrollBounceBehavior(.always)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                guard bridge.primed else { return } // pre-sync offset 0 must not clobber the engine
                engine.setWeekProgress(x, dayW: dayW)
            }
            .onAppear { bridge.scrollTo(engine.week * 7 * dayW) }
            // Entering week view (from month/day): position the strip on the current week.
            .onChange(of: engine.chrome.level) { _, lvl in
                if lvl == 2 {
                    bridge.scrollTo(engine.week * 7 * dayW)
                }
            }
            // A month-edge flip re-anchored focus/week to the neighbor month → re-sync the strip
            // (the cell count also changed with weeksInMonth) to the new resting week.
            .onChange(of: engine.chrome.weekResync) { _, _ in
                bridge.scrollTo(engine.week * 7 * dayW)
            }
        }
    }
}

/// Zero-size probe that hands the SwiftUI ScrollView's backing NSScrollView to the bridge.
private struct WeekScrollGrabber: NSViewRepresentable {
    let bridge: WeekPagerBridge
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main
            .async {
                if let sv = v.enclosingScrollView, bridge.scrollView !== sv {
                    bridge.scrollView = sv
                }
            }
    }
}
