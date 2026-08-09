// Breaks the display-starvation livelock (the "⌘J pop"): when per-tick work (SwiftUI eval +
// canvas redraw + window layout) exceeds the display-link interval, the main runloop always
// has another tick pending, so it never reaches BeforeWaiting — and Core Animation, which
// flushes implicit transactions only there, never presents. The whole animation then plays
// "in the dark" (engine state tweens perfectly, evals run at 90-100/s) and the screen jumps
// straight to the end state hundreds of ms later.
//
// Observed in the Xcode app (trace 1785691503: pin 1.0→0.0 fully inside a 324ms display
// silence, zero commits) but never in the CLI bench shell: the app's toolbar drags a
// window-wide Auto Layout engine into every tick (+~46% per-tick cost), pushing identical
// work over the 8.3ms @120Hz budget. Saturation is a cliff — 1ms under = 120fps, 1ms over =
// 0fps presented.
//
// The guard makes the cliff a slope: a BeforeSources observer (which DOES run every runloop
// cycle, starved or not) force-flushes CA whenever no natural idle-flush happened for
// `staleLimit`. Under saturation the screen then updates every ~25ms (~40fps animation)
// instead of freezing; under normal load the natural BeforeWaiting flush runs every frame
// and the guard never fires.

import AppKit
import CalendarEngine
import QuartzCore

@MainActor
public enum PresentGuard {
    private static var installed = false
    private static var lastFlush = CFAbsoluteTimeGetCurrent()
    /// Longest the screen may go without a commit while the loop is spinning. 25ms ≈ a 40fps
    /// floor under total saturation; irrelevant when the loop idles normally.
    private static let staleLimit: CFTimeInterval = 0.025
    /// Diagnostic: total forced flushes (visible in traces via the E line below).
    public private(set) static var forcedFlushes = 0

    public static func install() {
        guard !installed else { return }
        installed = true
        RenderLoopClock.enabled = true // engine tweens sample time once per runloop cycle
        // Natural commit point reached → screen is fresh; note the time. Order is just past
        // CA's own BeforeWaiting transaction observer (2,000,000).
        let idle = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_002
        ) { _, _ in
            MainActor.assumeIsolated {
                lastFlush = CFAbsoluteTimeGetCurrent()
                RenderLoopClock.generation &+= 1
            }
        }
        // Every runloop cycle — including starved ones that never sleep. Phase boundary, so no
        // SwiftUI update is mid-flight; flushing here is the same work BeforeWaiting would do.
        let busy = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeSources.rawValue, true, 0
        ) { _, _ in
            MainActor.assumeIsolated {
                RenderLoopClock.generation &+= 1
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastFlush > staleLimit else { return }
                lastFlush = now
                forcedFlushes += 1
                CATransaction.flush()
                if CCTrace.on {
                    CCTrace.event("presentGuard flush")
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), idle, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), busy, .commonModes)
    }
}
