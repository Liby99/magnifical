// One animation-clock sample per runloop cycle (see the comment in sceneInput).
//
// The generation counter is bumped by PresentGuard's runloop observers (CalendarUI) at
// BeforeSources and BeforeWaiting — every cycle boundary, including starved cycles that never
// sleep. Two evals with the same generation are inside the same cycle (typically: the same CA
// commit's layout loop) and must see the same animation clock, or the commit's layout loop
// re-dirties itself on every pass and never converges.
//
// Inert until `enabled` is set (PresentGuard.install does it): hosts that never bump the
// generation (iOS, tests, headless tools) keep plain per-call dates.

import Foundation

@MainActor
public enum RenderLoopClock {
    /// Bumped at every main-runloop cycle boundary by PresentGuard. Monotonicity not required —
    /// any change means "new cycle".
    public static var generation: UInt64 = 0
    /// Set by PresentGuard.install(); without it sample() is a pass-through.
    public static var enabled = false

    private static var lastGeneration: UInt64 = .max
    private static var lastDate = Date.distantPast

    /// The animation clock for this eval: the given date on the first call of a runloop cycle,
    /// the SAME frozen date for every further call within that cycle.
    public static func sample(_ date: Date) -> Date {
        guard enabled else { return date }
        if generation == lastGeneration {
            return lastDate
        }
        lastGeneration = generation
        lastDate = date
        return date
    }
}
