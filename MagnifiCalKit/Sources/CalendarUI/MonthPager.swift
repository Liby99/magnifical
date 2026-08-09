// Month↕month paging, driven by a real (but invisible) SwiftUI ScrollView.
//
// AppKit has no native vertical paging, but SwiftUI does: `.scrollTargetBehavior(.paging)`
// gives velocity-aware, snap-to-page scrolling with the native deceleration curve (the
// closest thing to iOS's isPagingEnabled). We host 12 empty page cells (one per month),
// let SwiftUI do all the physics, and observe the absolute content offset via
// `.onScrollGeometryChange` — projecting it onto the engine's (focus, anim.monthAnim) state that
// the Canvas already renders. Nothing here is drawn; it's purely an input/physics proxy.
//
// The AppKit input catcher sits on top (for clicks/hover/pinch), so it FORWARDS month-view
// scroll events into this ScrollView's backing NSScrollView — handed over through `bridge`.

import AppKit
import CalendarEngine
import SwiftUI

/// Shared handle between the SwiftUI paging driver and the AppKit `CatcherView`. Positioning is
/// IMPERATIVE (scroll the backing NSScrollView), NOT via `.scrollPosition` — a two-way position
/// binding re-renders the pager while scrolling and re-applies itself, which jumps the offset.
@MainActor final class MonthPagerBridge {
    weak var scrollView: NSScrollView? {
        didSet {
            if let p = pending {
                pending = nil; scrollTo(p)
            }
        }
    }

    var pageH: CGFloat = 0 // current page height, so the catcher can re-sync the SV to a focus after a flip
    private var pending: CGFloat?
    /// The initial engine→scroll-view sync has been APPLIED. Until then the geometry callback must
    /// not write into the engine: a freshly-created pager (window closed and reopened while AT this
    /// level — the engine outlives the window) first reports contentOffset 0, and adopting that
    /// would walk the surviving focus back to January before onAppear can position the strip.
    private(set) var primed = false
    func scrollTo(_ y: CGFloat) {
        guard let sv = scrollView else { pending = y; return }
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        sv.reflectScrolledClipView(sv.contentView)
        primed = true
    }

    /// Snap the backing scroll view to a month index (used to reset a stale offset left by a boundary flip).
    func scrollToFocus(_ focus: Int) {
        if pageH > 0 {
            scrollTo(CGFloat(focus) * pageH)
        }
    }
}

struct MonthPager: View {
    let engine: CalendarEngine
    let bridge: MonthPagerBridge

    var body: some View {
        GeometryReader { geo in
            let pageH = geo.size.height
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(0 ..< 12, id: \.self) { m in
                        Color.clear.frame(height: pageH).id(m)
                    }
                }
                .scrollTargetLayout()
                .background(ScrollViewGrabber(bridge: bridge)) // capture the backing NSScrollView
            }
            .scrollTargetBehavior(MonthPagingBehavior()) // lighter than .paging, still native decel
            .scrollBounceBehavior(.always) // elastic overscroll at Jan/Dec → boundary flip
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                guard bridge.primed else { return } // pre-sync offset 0 must not clobber the engine
                engine.setMonthProgress(y, pageH: pageH)
            }
            .onAppear { bridge.pageH = pageH; bridge.scrollTo(CGFloat(engine.focus) * pageH) }
            .onChange(of: pageH) { _, h in bridge.pageH = h }
            // Entering month view (from year/week): snap the pager to the focused month.
            .onChange(of: engine.chrome.level) { _, lvl in
                if lvl == 1 {
                    bridge.scrollTo(CGFloat(engine.focus) * pageH)
                }
            }
            // A boundary flip changed year+focus (Jan↔Dec across years) without leaving month
            // view — jump the pager to the new focus (setMonthProgress is guarded during the flip).
            .onChange(of: engine.chrome.monthResync) { _, _ in bridge.scrollTo(CGFloat(engine.focus) * pageH) }
        }
        // No allowsHitTesting(false): the AppKit catcher sits on top and shields this from all
        // direct events, and we want SwiftUI's paging machinery fully intact for forwarded events.
    }
}

/// Zero-size probe that hands its enclosing NSScrollView (the one SwiftUI's ScrollView is
/// backed by) up to the bridge, so the AppKit catcher can forward scroll events into it.
private struct ScrollViewGrabber: NSViewRepresentable {
    let bridge: MonthPagerBridge
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
