// Portable bench statistics: the math behind bench.json, the FPS HUD readout, and the
// results-log line. Extracted verbatim from CalendarUI/DemoController+Bench.swift so the
// iPhone bench runner can share it; the Mac DemoController delegates here. Formulas, keys,
// and rounding are pinned by BenchStatsTests — bench.json output must stay byte-compatible
// across the extraction or results.log history stops being comparable.

import Foundation

public enum BenchStats {
    /// Frame-time stats over recorded per-frame timestamps — the bench.json payload.
    /// `frames` are TimelineView-evaluation timestamps (one per rendered frame);
    /// `moves` are (start, end) gesture windows for the moving-phase-only stats.
    /// Returns nil when there aren't enough frames to judge (mirrors the original
    /// `benchFrames.count > 2` + non-empty-deltas guards).
    public static func results(frames: [Double], moves: [(Double, Double)]) -> [String: Any]? {
        guard frames.count > 2 else { return nil }
        let deltas = zip(frames.dropFirst(), frames).map { $0 - $1 }.filter { $0 > 0 }
        guard !deltas.isEmpty else { return nil }
        // Moving-phase-only stats (frames inside recorded gesture windows): the number that
        // matches what the EYE sees — a slow frame on a static screen is invisible.
        var movingDeltas: [Double] = []
        var hitchOffsets: [Double] = [] // hitch position within its turn window (0 = turn start), seconds
        if !moves.isEmpty {
            for (t2, t1) in zip(frames.dropFirst(), frames) {
                if let win = moves.first(where: { t2 > $0.0 && t2 <= $0.1 + 0.02 }) {
                    movingDeltas.append(t2 - t1)
                    if t2 - t1 > 1.0 / 30.0 {
                        hitchOffsets.append(((t2 - win.0) * 1000).rounded() / 1000)
                    }
                }
            }
        }
        let sorted = deltas.sorted()
        func pctMs(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000
        }
        func r2(_ x: Double) -> Double {
            (x * 100).rounded() / 100
        }
        let seconds = frames.last! - frames.first!
        // The WORST 1-second rolling window's fps — exactly what the on-screen HUD shows as "lowest
        // framerate," which the avg/p95 summary hides (a cluster of hitches inside one second reads far
        // lower than p95). For each frame, count frames in the trailing 1s and take the min fps over the run.
        func hudMinFps() -> Double {
            guard frames.count > 5 else { return r2(Double(deltas.count) / seconds) }
            var worst = Double.infinity
            var lo = 0
            for hi in 1 ..< frames.count {
                while frames[hi] - frames[lo] > 1.0 {
                    lo += 1
                }
                let span = frames[hi] - frames[lo]
                let n = hi - lo
                if span >= 0.5, n >= 3 {
                    worst = min(worst, Double(n) / span)
                } // need a near-full window
            }
            return worst.isFinite ? r2(worst) : r2(Double(deltas.count) / seconds)
        }
        var out: [String: Any] = [
            "frames": deltas.count + 1,
            "seconds": r2(seconds),
            "avg_fps": r2(Double(deltas.count) / seconds),
            "hud_min_fps": hudMinFps(),
            "frame_ms_p50": r2(pctMs(0.50)),
            "frame_ms_p95": r2(pctMs(0.95)),
            "frame_ms_max": r2(sorted.last! * 1000),
            "hitches_over_33ms": deltas.filter { $0 > 1.0 / 30.0 }.count,
        ]
        if !movingDeltas.isEmpty {
            let ms = movingDeltas.sorted()
            out["moving_avg_fps"] = r2(Double(movingDeltas.count) / movingDeltas.reduce(0, +))
            out["moving_p95_ms"] = r2(ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))] * 1000)
            out["moving_max_ms"] = r2(ms.last! * 1000)
            out["moving_hitches"] = movingDeltas.filter { $0 > 1.0 / 30.0 }.count
            out["hitch_offsets_s"] = hitchOffsets
        }
        return out
    }

    /// Stats over the last second of rendered frames (nil while idle/paused — no frames to
    /// judge). SLEEP-AWARE: the render clock legitimately sleeps between animations, and raw
    /// wall-time deltas diluted the fps readout to "30-50" during toggle sessions even when
    /// every animated frame hit cadence. The engine's recorded sleep spans (via `sleepOverlap`)
    /// are subtracted from each delta and from the window, so the HUD reads the ANIMATED frame
    /// rate — while real main-thread blocks (which are not sleeps) still count as jank.
    public static func hudStats(
        ring: [Double],
        now: Double = Date().timeIntervalSinceReferenceDate,
        sleepOverlap: (Double, Double) -> Double
    ) -> (fps: Double, p95ms: Double, maxms: Double)? {
        let recent = ring.filter { $0 > now - 1.0 }
        guard recent.count >= 5 else { return nil }
        let deltas = zip(recent.dropFirst(), recent).map { b, a in
            max(0.0001, (b - a) - sleepOverlap(a, b))
        }
        guard !deltas.isEmpty else { return nil }
        let sorted = deltas.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let span = (recent.last! - recent.first!) - sleepOverlap(recent.first!, recent.last!)
        guard span > 0.001 else { return nil }
        return (Double(deltas.count) / span, p95 * 1000, sorted.last! * 1000)
    }

    /// One results.log line in exactly bench-year.sh's Python format, so device-side output can
    /// be pasted into bench/results-ios.log and read by the same eyes/tools as the Mac history.
    /// `timestamp` is injectable for tests; defaults to now in the script's `%Y-%m-%d %H:%M`.
    public static func resultsLogLine(results: [String: Any], tag: String, timestamp: String? = nil) -> String {
        func d(_ key: String) -> Double {
            (results[key] as? Double) ?? (results[key] as? Int).map(Double.init) ?? .nan
        }
        func i(_ key: String) -> Int {
            (results[key] as? Int) ?? (results[key] as? Double).map(Int.init) ?? 0
        }
        let ts = timestamp ?? {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: Date())
        }()
        var line = String(
            format: "%@ [%@] avg %.1f fps | HUD-min %.1f fps | p50 %.2f ms | p95 %.2f ms | max %.1f ms | hitches(>33ms) %d | ",
            ts, tag, d("avg_fps"), d("hud_min_fps"), d("frame_ms_p50"), d("frame_ms_p95"),
            d("frame_ms_max"), i("hitches_over_33ms")
        )
        if results["moving_avg_fps"] != nil {
            line += String(
                format: "MOVING: %.1f fps p95 %.1f ms hitches %d | ",
                d("moving_avg_fps"), d("moving_p95_ms"), i("moving_hitches")
            )
        }
        line += String(format: "%d frames / %.2f s", i("frames"), d("seconds"))
        return line
    }
}
