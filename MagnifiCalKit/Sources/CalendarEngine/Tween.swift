// A single scalar tween driven by wall-clock time. The animation system rides on
// these instead of nested rAF callbacks — a tween is data, evaluated per frame.

import CalendarGeometry
import CoreGraphics
import Foundation

struct Tween {
    var from: CGFloat
    var to: CGFloat
    var start: Date
    var duration: TimeInterval
    var ease: (CGFloat) -> CGFloat
    /// First-evaluation latch: the z/scroll tween advance REBASES `start` to the first frame
    /// that actually renders (see sceneInput). The wall-clock otherwise starts at creation —
    /// and the first frame after a zoom can arrive late (launch-time cache fills, view
    /// mounts), so a fixed start had the animation half-over or DONE before it was ever
    /// seen (the "instant first zoom" bug). One frame of latency buys a visible animation.
    var ticked = false

    func progress(at date: Date) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(1, max(0, date.timeIntervalSince(start) / duration)))
    }

    func value(at date: Date) -> CGFloat {
        from + (to - from) * ease(progress(at: date))
    }

    func isComplete(at date: Date) -> Bool {
        date.timeIntervalSince(start) >= duration
    }
}
