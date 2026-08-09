// Per-layer render profiler. Gated behind CC_PROF=1 (zero cost otherwise): emits os_signpost
// intervals so an Instruments "Points of Interest" lane attributes wall time to each draw layer
// (drawBelow / events / drawMid / deadlines / drawAbove) — and ALSO keeps a running per-layer
// millisecond accumulator the bench harness dumps into bench.json for hard numbers without a trace.
//
// IMPORTANT: this measures MAIN-THREAD CPU time only. Liquid-Glass (.glassEffect) compositing runs
// on the GPU/render-server AFTER the SwiftUI commit, so a GPU-bound stall shows here as CHEAP CPU —
// that asymmetry is itself the signal (pair with a Metal System Trace to see the GPU cost).

import Foundation
import os

@MainActor public enum RenderProf {
    public static let on = ProcessInfo.processInfo.environment["CC_PROF"] != nil

    private static let log = OSLog(subsystem: "com.calendarkit.render", category: .pointsOfInterest)

    /// key → (samples, total ms, max ms). Reset per bench window by the harness.
    public private(set) static var acc: [String: (n: Int, total: Double, peak: Double)] = [:]

    public static func reset() {
        acc.removeAll(keepingCapacity: true)
    }

    /// Time `body`, emit a signpost interval, and fold the sample into `acc[key]`. The signpost `name`
    /// must be a compile-time literal, so callers pass a fixed StaticString per layer.
    @inline(__always)
    public static func measure<T>(_ name: StaticString, _ key: String, _ body: () -> T) -> T {
        guard on else { return body() }
        let sid = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: sid)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = body()
        let dt = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000.0
        os_signpost(.end, log: log, name: name, signpostID: sid)
        var e = acc[key] ?? (0, 0, 0)
        e.n += 1; e.total += dt; e.peak = max(e.peak, dt)
        acc[key] = e
        return r
    }

    /// Point event marking a bench-phase boundary (benchBegin/benchEnd) — an exported Instruments
    /// trace windows its stack aggregation on these, so flamegraphs cover EXACTLY the scripted
    /// gesture phase (no app-launch or idle-tail contamination).
    public static func mark(_ name: StaticString) {
        guard on else { return }
        os_signpost(.event, log: log, name: name)
    }

    /// Per-layer summary: key → [samples, avg-ms, total-ms, peak-ms], JSON-ready for bench.json.
    public static func summary() -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for (k, v) in acc {
            let avg = v.n > 0 ? v.total / Double(v.n) : 0
            out[k] = [Double(v.n),
                      (avg * 1000).rounded() / 1000,
                      (v.total * 100).rounded() / 100,
                      (v.peak * 1000).rounded() / 1000]
        }
        return out
    }
}
