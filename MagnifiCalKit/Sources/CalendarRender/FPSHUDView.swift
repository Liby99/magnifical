// Portable live frame-rate readout: fps + p95/max frame time over the last second, refreshed
// twice a second from the render loop's own tick. The phone twin of the Mac's FPSHUD
// (CalendarUI/DemoOverlays.swift), parameterized by a stats provider and the display's frame
// budget so the tints are display-rate-aware: green = holding refresh, yellow = missing frames
// (> budget × 1.14 — 9.5 ms at 120 Hz, 19.0 ms at 60 Hz), red = visible hitches (> budget × 2).
// Shows "idle" while the render loop is paused (no frames — nothing to judge).

import SwiftUI

public struct FPSHUDView: View {
    let stats: () -> (fps: Double, p95ms: Double, maxms: Double)?
    let budgetMs: Double
    @State private var text = "fps —"
    @State private var tint = Color.secondary

    public init(stats: @escaping () -> (fps: Double, p95ms: Double, maxms: Double)?, budgetMs: Double) {
        self.stats = stats
        self.budgetMs = budgetMs
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)
            .allowsHitTesting(false)
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                if let s = stats() {
                    text = String(format: "%3.0f fps · p95 %4.1f ms · max %4.1f", s.fps, s.p95ms, s.maxms)
                    tint = s.p95ms > budgetMs * 2 ? .red : (s.p95ms > budgetMs * 1.14 ? .yellow : .green)
                } else {
                    text = "idle"
                    tint = .secondary
                }
            }
    }
}
