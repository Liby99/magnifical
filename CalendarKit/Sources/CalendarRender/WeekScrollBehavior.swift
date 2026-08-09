// Snap policy for the week window's horizontal scroll. Lives in CalendarRender (not the
// AppKit-bound WeekPager) so the iPhone's touch pager can reuse the exact same feel.

import SwiftUI

/// Snap policy: a gentle scroll nudges by a few days (day-aligned); only a deliberate hard fling
/// snaps to a week boundary — and always to the boundary in the DIRECTION of the fling, never the
/// "nearest" one (which could sit behind you and yank you backward).
///
/// Two knobs tune the feel:
///   • weekVelocity — the small/large threshold. High so week-snapping only happens on a real fling;
///     lower it if you want week jumps to trigger more easily.
///   • maxDayStep   — the farthest a *small* scroll may travel from where the gesture began (SwiftUI's
///     momentum otherwise projects a light flick many days out; this caps it).
public struct WeekScrollBehavior: ScrollTargetBehavior {
    var dayW: CGFloat
    var maxDay: CGFloat // last valid left-edge day index (= maxWeek·7)
    var liveDay: () -> CGFloat // the CURRENT content position in day-units (from the engine)
    var weekVelocity: CGFloat = 1100 // |velocity| above this → a week jump (deliberate only)
    var maxDayStep: CGFloat = 3 // a small scroll moves at most this many days per gesture
    /// Reports each snap decision: the landing day index + whether it was a week jump. The
    /// engine uses it to drive the weekly-dashboard carousel (cruise on a jump, settle after
    /// a catch) — the policy's classification IS the big/small-scroll distinction.
    var onTarget: ((_ day: CGFloat, _ weekJump: Bool) -> Void)?

    public init(dayW: CGFloat, maxDay: CGFloat, liveDay: @escaping () -> CGFloat,
                weekVelocity: CGFloat = 1100, maxDayStep: CGFloat = 3,
                onTarget: ((_ day: CGFloat, _ weekJump: Bool) -> Void)? = nil) {
        self.dayW = dayW
        self.maxDay = maxDay
        self.liveDay = liveDay
        self.weekVelocity = weekVelocity
        self.maxDayStep = maxDayStep
        self.onTarget = onTarget
    }

    public func updateTarget(_ target: inout ScrollTarget, context: ScrollTargetBehaviorContext) {
        guard dayW > 0 else { return }
        // Anchor on where the content ACTUALLY IS right now — not `context.originalTarget`, which
        // reports the settled rest the gesture STARTED from (day 0 of a fling), so catching mid-flight
        // would cap `maxDayStep` from day 0 and always land ~mid-week regardless of the catch point.
        let cur = liveDay()
        let proposedDay = target.rect.origin.x / dayW // SwiftUI's momentum projection
        let v = context.velocity.dx
        let landed: CGFloat
        // A catch near the end of a fling has decelerated (low velocity) → the day path settles near
        // where you grabbed it. Only a genuinely fast gesture jumps to a week boundary.
        if abs(v) > weekVelocity {
            let weekStart = (cur / 7).rounded(.down) * 7 // Sunday of the current week
            landed = v > 0 ? weekStart + 7
                : ((cur - weekStart < 0.5) ? weekStart - 7 : weekStart)
        } else {
            let step = min(maxDayStep, max(-maxDayStep, proposedDay - cur))
            landed = (cur + step).rounded() // nearest day near the live position
        }
        let bounded = min(max(0, landed), maxDay)
        // Write x ONLY when it actually changes: on a two-axis ScrollView (the phone's week
        // driver) a rewritten target re-routes the y momentum through the snap animation, so
        // an unconditional write made vertical timeline flicks die early.
        if abs(target.rect.origin.x - bounded * dayW) > 0.5 {
            target.rect.origin.x = bounded * dayW
        }
        onTarget?(bounded, abs(v) > weekVelocity)
    }
}
