// Day↔day paging, driven by a real (but invisible) SwiftUI ScrollView — the horizontal twin of
// MonthPager, one page per DAY. A strip of 1-day cells (the focus month's days); SwiftUI supplies
// the native deceleration and we project the content offset onto the engine's (daily.dom, daily.anim)
// state that the Canvas already renders. Nothing here is drawn — it's purely an input/physics proxy.
//
// Month-scoped for now: the strip is just this month's days, clamped at the month edges (crossing to
// the next/previous month is a later flip, like the week pager). The AppKit catcher sits on top and
// forwards horizontal day-view scroll into this ScrollView's backing NSScrollView via `bridge`,
// axis-locked against the vertical hour-timeline scroll.

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// Shared handle between the SwiftUI day driver and the AppKit `CatcherView`. Positioning is
/// IMPERATIVE (scroll the backing NSScrollView), NOT via `.scrollPosition` — a two-way binding
/// re-renders the pager on every day crossed and re-applies itself, jumping the offset.
@MainActor final class DayPagerBridge {
    weak var scrollView: NSScrollView? {
        didSet {
            if let p = pending {
                pending = nil; scrollTo(p)
            }
        }
    }

    private var pending: CGFloat?
    /// The initial engine→scroll-view sync has been APPLIED. Until then the geometry callback must
    /// not write into the engine: a freshly-created pager (window closed and reopened while AT day
    /// level — the engine outlives the window) first reports contentOffset 0, and adopting that
    /// would snap the surviving day back to the 1st before onAppear positions the strip.
    private(set) var primed = false
    func scrollTo(_ x: CGFloat) {
        guard let sv = scrollView else { pending = x; return }
        sv.contentView.scroll(to: NSPoint(x: max(0, x), y: 0))
        sv.reflectScrolledClipView(sv.contentView)
        primed = true
    }
}

struct DayPager: View {
    let engine: CalendarEngine
    let bridge: DayPagerBridge

    var body: some View {
        GeometryReader { geo in
            // One "page" = the day column's width (daily.frac of the content area) — the same width
            // the day slides by in dayFrame, so the finger tracks the content 1:1.
            let contentW = geo.size.width - Layout.padLeft - Layout.padRight - Layout.labelW
            let dayW = max(1, engine.daily.frac * contentW)
            let days = max(1, daysInMonth(engine.chrome.year, engine.chrome.focus))
            let maxDay = CGFloat(days - 1)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0 ..< days, id: \.self) { d in
                        Color.clear.frame(width: dayW, height: 1).id(d)
                    }
                }
                .scrollTargetLayout()
                .background(DayScrollGrabber(bridge: bridge))
            }
            .frame(width: dayW, height: 8) // viewport = one day
            .scrollTargetBehavior(DayScrollBehavior(dayW: dayW, maxDay: maxDay))
            .scrollBounceBehavior(.always)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                guard bridge.primed else { return } // pre-sync offset 0 must not clobber the engine
                engine.setDayProgress(x)
            }
            .onAppear { bridge.scrollTo(CGFloat(engine.daily.dom - 1) * dayW) }
            // Entering day view (from week): position the strip on the chosen day.
            .onChange(of: engine.chrome.level) { _, lvl in
                if lvl == 3 {
                    bridge.scrollTo(CGFloat(engine.daily.dom - 1) * dayW)
                }
            }
            // A non-scroll change to the day (jump-to-today, zoom-in landing) or the split width
            // (dayW changed) — re-sync the strip (setDayProgress is guarded off during the resync).
            .onChange(of: engine.chrome.dailyResync) { _, _ in
                bridge.scrollTo(CGFloat(engine.daily.dom - 1) * dayW)
            }
        }
    }
}

/// Zero-size probe that hands the SwiftUI ScrollView's backing NSScrollView to the bridge.
private struct DayScrollGrabber: NSViewRepresentable {
    let bridge: DayPagerBridge
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
