// Scroll-snap policies for the month and day pagers. Pure SwiftUI (no AppKit), so they live
// in CalendarRender and both the Mac's invisible NSScrollView-backed pagers and the iPhone's
// touch pagers share the exact same paging feel. WeekScrollBehavior is in its own file.

import SwiftUI

/// Month paging that's lighter than the built-in `.paging`: one gesture turns at most one
/// month, and it commits on a small drag OR a gentle flick (both tunable) — so it doesn't feel
/// like you have to heave a full screen to advance. SwiftUI still supplies the native
/// deceleration to whichever page we pick.
public struct MonthPagingBehavior: ScrollTargetBehavior {
    var commitFraction: CGFloat = 0.18 // drag ≥ this fraction of a page → turn
    var flickVelocity: CGFloat = 180 // …or fling faster than this (pts/sec) → turn

    public init(commitFraction: CGFloat = 0.18, flickVelocity: CGFloat = 180) {
        self.commitFraction = commitFraction
        self.flickVelocity = flickVelocity
    }

    public func updateTarget(_ target: inout ScrollTarget, context: ScrollTargetBehaviorContext) {
        let page = context.containerSize.height
        guard page > 0 else { return }
        let start = context.originalTarget.rect.origin.y // page we began the gesture on
        let startPage = (start / page).rounded()
        let dragged = target.rect.origin.y - start // SwiftUI's projected landing
        let v = context.velocity.dy
        var dest = startPage
        if dragged > page * commitFraction || v > flickVelocity {
            dest = startPage + 1
        } else if dragged < -page * commitFraction || v < -flickVelocity {
            dest = startPage - 1
        }
        dest = min(11, max(0, dest)) // never target beyond the 12 months (an edge
        // flick at Jan/Dec must NOT snap to page -1/12,
        // which is what overshot the year on a flip)
        target.rect.origin.y = dest * page // land exactly on a month
    }
}

/// Snap the momentum-projected landing to the nearest DAY: a gentle nudge advances one day, a fast
/// fling carries several (SwiftUI projects farther), and either way lands exactly on a day boundary
/// with the native deceleration curve. Clamped to the month. (The Mac's day pager; the phone's
/// PhoneDayDriver pages with native `.paging` — its day column fills the container.)
public struct DayScrollBehavior: ScrollTargetBehavior {
    var dayW: CGFloat
    var maxDay: CGFloat // last valid day index (= daysInMonth − 1)

    public init(dayW: CGFloat, maxDay: CGFloat) {
        self.dayW = dayW
        self.maxDay = maxDay
    }

    public func updateTarget(_ target: inout ScrollTarget, context: ScrollTargetBehaviorContext) {
        guard dayW > 0 else { return }
        let day = (target.rect.origin.x / dayW).rounded()
        target.rect.origin.x = min(max(0, day), maxDay) * dayW
    }
}
