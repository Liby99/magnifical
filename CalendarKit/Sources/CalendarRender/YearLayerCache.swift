// Year-scroll layer cache: record-once, translate-per-frame.
//
// At rest-year (z == 0, no month page-turn) the whole year scene is RIGID under scroll — yearFrame()
// consumes scrollY as a pure vertical translation. Yet the per-frame Canvas closures re-recorded the
// full display list every frame (grid rows, ~700 dashed separator segments, labels, band stickers),
// and the profile showed that re-record + re-tessellation IS the remaining year-fling frame cost
// (display-list infra ~3.3ms/f; RB::Stroke dasher hot in self time).
//
// So: build a scroll-FREE SceneInput (`yearCacheInput`) — scrollY 0, hover cleared, `now` rounded to
// the minute, viewport tall enough for the whole year — and render the rigid slices into Canvases
// wrapped in Equatable views. While that input is unchanged, SwiftUI skips the body, the display list
// survives, and CoreAnimation just translates the cached layer by -scrollY. Hover highlights (which
// move relative to content) and the now/cursor/pull chrome stay in thin per-frame passes.
//
// CC_YEARCACHE_OFF=1 disables the cache (same-binary A/B benchmarking).

import CalendarGeometry
import SwiftUI

private let yearCacheKill = ProcessInfo.processInfo.environment["CC_YEARCACHE_OFF"] != nil

/// The scroll-free input the rigid layers render against — nil when the cache can't apply
/// (zoomed, mid page-turn, mid year-flip, phone quarter-scroll active, or killed via env).
public func yearCacheInput(_ input: SceneInput) -> SceneInput? {
    guard !yearCacheKill, input.z == 0, input.monthAnim == nil, input.flipFade == 1,
          input.yearQX == [0, 0, 0, 0] else { return nil }
    var g = input
    g.scrollY = 0
    g.hover = .none
    g.yearPull = nil
    g.animating = false // flips per scroll-tween start/stop; the rigid content doesn't care
    // Normalize everything the z==0 scene provably doesn't render: `focus` TRACKS the viewport
    // while the year scrolls (it would re-record the cache ~12× per sweep), but at z==0 focus
    // only feeds buildDetail (reveal 0 → no items) and the focus-band border emphasis
    // (clamp((z−0.82)/0.18) → 0). Same for the week/day sub-state and detail scroll.
    g.focus = 0
    g.dashPin = 0 // panel reveal is 0 at z==0 either way; keep the pin toggle out of the cache key
    g.week = 0
    g.tlScroll = 0
    g.daily = DailyState()
    g.monthPull = nil
    g.weekPull = nil
    g.dayPull = nil
    g.weekFlipDir = 0
    g.weekFlipFade = 0
    g.monthFlipShift = 0
    // `now` ticks every frame; the year view only uses it at day granularity (today tint/tag).
    // Round to the minute so the cache key is stable (re-records at most once a minute).
    g.now = Date(timeIntervalSinceReferenceDate:
        (input.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    // Tall viewport = the whole year's content, so per-month culling keeps every month.
    g.vp = Viewport(w: input.vp.w, h: yearCacheHeight())
    return g
}

/// Full content-space height of the cached layers (yearTop inset + 4 quarters + bottom pad).
public func yearCacheHeight() -> CGFloat {
    Layout.yearTop + yearContentH() + Layout.bottomPad
}

/// The rigid below-events slice (grid rows, washes, today tint, day labels) at full year height.
public struct YearRigidBelow: View, Equatable {
    let g0: SceneInput
    let theme: Theme
    public init(g0: SceneInput, theme: Theme) {
        self.g0 = g0
        self.theme = theme
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.g0 == b.g0 && a.theme.dark == b.theme.dark && a.theme.accentDark == b.theme.accentDark
    }

    public var body: some View {
        Canvas { ctx, _ in
            var c = ctx
            c.translateBy(x: Layout.padLeft, y: 0)
            RenderProf.measure("rigidBelow", "1s_rigidBelow") {
                SceneRenderer.drawBelow(input: g0, filter: .rigid, in: &c, theme: theme)
            }
        }
    }
}

/// The rigid above-events slice (gutter month names, track names, gutter borders) at full height.
public struct YearRigidAbove: View, Equatable {
    let g0: SceneInput
    let tracks: [[String]]
    let hideTrack: Int2? // (month, track) being edited inline — its name is hidden
    let theme: Theme
    public init(g0: SceneInput, tracks: [[String]], hideTrack: (Int, Int)?, theme: Theme) {
        self.g0 = g0
        self.tracks = tracks
        self.hideTrack = hideTrack.map { Int2(a: $0.0, b: $0.1) }
        self.theme = theme
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.g0 == b.g0 && a.tracks == b.tracks && a.hideTrack == b.hideTrack
            && a.theme.dark == b.theme.dark && a.theme.accentDark == b.theme.accentDark
    }

    public var body: some View {
        Canvas { ctx, _ in
            var c = ctx
            c.translateBy(x: Layout.padLeft, y: 0)
            RenderProf.measure("rigidAbove", "5s_rigidAbove") {
                SceneRenderer.drawAbove(input: g0, tracks: tracks,
                                        hideTrack: hideTrack.map { ($0.a, $0.b) },
                                        filter: .rigid, in: &c, theme: theme)
            }
        }
    }
}

/// Equatable pair (tuples aren't Equatable as stored properties).
public struct Int2: Equatable {
    let a: Int
    let b: Int
}
