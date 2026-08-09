// The demo-mode overlay views: the drawn synthetic cursor + the live FPS HUD.
// Split from DemoController.swift (audit round, 2026-08-02).

import AppKit
import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

/// The drawn synthetic cursor (a macOS arrow + an optional press ring). Positioned in the calendar view's
/// local space by the controller.
public struct DemoCursorOverlay: View {
    let demo: DemoController
    public init(demo: DemoController) {
        self.demo = demo
    }

    public var body: some View {
        // Pinch-zoom gesture: two fingertips joined by a dotted line through the pinch centre (the exact
        // point being zoomed into), all in the app's red accent.
        if let (a, b) = demo.pinchDots {
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            ZStack {
                // Dotted line spanning the two fingertips (passes through the centre).
                Path { p in p.move(to: a); p.addLine(to: b) }
                    .stroke(Theme.accent.opacity(0.7),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                // Centre marker: the month/week/day the pinch is zooming into.
                Circle().fill(Theme.accent)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5).frame(width: 9, height: 9))
                    .position(mid)
                // The two fingertips.
                ForEach([a, b].indices, id: \.self) { i in
                    Circle().fill(Theme.accent.opacity(0.9))
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 22, height: 22))
                        .position(i == 0 ? a : b)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        // Floating keycap (e.g. "⌘ B") for keyboard-driven beats — scenes can't show a real
        // keystroke, so the pressed chord is drawn as a keyboard-style cap, lower-center.
        if let key = demo.keyCap {
            VStack {
                Spacer()
                Text(key)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .padding(.bottom, 70)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        if let p = demo.cursor {
            let img = NSCursor.arrow.image
            let hs = NSCursor.arrow.hotSpot
            ZStack {
                // Press ring — centered EXACTLY on the pointer tip (`p`), in the app's red accent.
                if demo.pressed {
                    Circle().stroke(Theme.accent, lineWidth: 2.5)
                        .frame(width: 30, height: 30)
                        .position(p)
                }
                // The arrow, offset so its hotspot (tip) lands on `p`.
                Image(nsImage: img)
                    .interpolation(.high)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .position(x: p.x + img.size.width / 2 - hs.x, y: p.y + img.size.height / 2 - hs.y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // fill the overlay so .position uses view coords
            .allowsHitTesting(false)
        }
    }
}

/// Live frame-rate readout (CC_FPS_HUD=1): fps + p95/max frame time over the last second, refreshed twice a
/// second from the render loop's own tick (benchTick). Green = holding refresh, yellow = missing frames,
/// red = visible hitches. Shows "idle" while the render loop is paused (no frames — nothing to judge).
struct FPSHUD: View {
    let demo: DemoController
    @State private var text = "fps —"
    @State private var tint = Color.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)
            .allowsHitTesting(false)
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                if let s = demo.hudStats() {
                    text = String(format: "%3.0f fps · p95 %4.1f ms · max %4.1f", s.fps, s.p95ms, s.maxms)
                    tint = s.p95ms > 17 ? .red : (s.p95ms > 9.5 ? .yellow : .green)
                } else {
                    text = "idle"; tint = .secondary
                }
            }
    }
}
