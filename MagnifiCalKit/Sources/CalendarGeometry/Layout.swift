// Layout constants + math helpers. Single source of truth for the calendar's fixed
// pixel dimensions. Ported from geometry/constants.ts.

import CoreGraphics

public enum Layout {
    /// Month/week/day top padding: the band's resting Y (the date row sits at bandY-20).
    /// The year→month accordion lands the band here, so this animates smoothly (no jump);
    /// year view is unaffected (it uses yearTop). Raise to move month content clear of the toolbar.
    /// Month/week/day content top inset. Write-once-at-launch like labelW: desktop keeps 78
    /// (clear of the transparent titlebar toolbar); the phone shrinks it — no top chrome there.
    public nonisolated(unsafe) static var topPad: CGFloat = 78
    // Year view top inset (no date row up there). Write-once-at-launch like labelW: the
    // desktop keeps 44 (clear of the transparent titlebar); the phone shrinks it — its
    // chrome floats at the BOTTOM, so the year grid starts right under the status bar.
    public nonisolated(unsafe) static var yearTop: CGFloat = 44
    public static let yearFlipOver: CGFloat = 30 // on-screen overscroll (px) that arms a year flip

    // Emphasized band-edge borders — thicker + more solid than the internal dividers. Shared
    // by the year view's quarter top/bottom and the month view's focus-band top/bottom.
    public static let bandEdgeWidth: CGFloat = 1.5
    public static let bandEdgeOpacity: CGFloat = 1.0
    public static let bandInnerWidth: CGFloat = 1.0
    public static let bandInnerOpacity: CGFloat = 0.6

    // (Month↕month paging is now handled natively by SwiftUI's .scrollTargetBehavior(.paging)
    // in MonthPager — no page-distance / commit-threshold tuning constants needed here.)

    // Hover-highlight + weekend-wash style guide — shared across year / month / week.
    public static let hlSoft: CGFloat = 0.03 // coarse: month-band row / week span
    public static let hlStrong: CGFloat = 0.08 // fine: hovered day / hour cell
    public static let weekendWashOpacity: CGFloat = 0.03 // toned down to match the hover feel
    // Breathing room below year content. Write-once-at-launch like labelW: desktop keeps 28;
    // the phone raises it so the last quarter can scroll clear of the floating glass toolbar.
    public nonisolated(unsafe) static var bottomPad: CGFloat = 28
    /// Left gutter width (track names + month name). A `var` with a write-once-at-launch
    /// contract: the desktop keeps 250; the iPhone app narrows it before the first render
    /// (a 250pt gutter would eat most of a 402pt portrait screen). Never mutate after
    /// startup — every cached geometry/scene assumes it is constant.
    public nonisolated(unsafe) static var labelW: CGFloat = 250
    /// Minimum year-view day-cell width. 0 on desktop (cells always fit the window); the
    /// iPhone sets 26 so cells stay legible and each QUARTER overflows into its own
    /// horizontal scroll (SceneInput.yearQX). Same write-once-at-launch contract as labelW.
    public nonisolated(unsafe) static var yearMinDayW: CGFloat = 0
    /// Day columns visible at once in the WEEK view's window. Write-once-at-launch like
    /// labelW: desktop keeps 7 (the whole week); the phone sets 3 so columns stay readable
    /// on a portrait screen. `week` stays in 7-day WEEK units everywhere — this knob only
    /// sets how many of those day cells fill the viewport (dayW = grid ÷ this), so the
    /// window scrolls day-aligned across the month's full week grid.
    public nonisolated(unsafe) static var weekDaysVisible: CGFloat = 7

    /// True when the gutter is collapsed to just the rotated month name (the phone).
    /// Year-view chrome adapts: month-name cells get full-width top/bottom rules and the
    /// quarter gutter rule spans the whole (tiny) gutter instead of stopping at rightPad.
    public static var isCompactGutter: Bool {
        labelW <= mnameW + 0.5
    }

    /// Rotated month-name zone within the gutter. Write-once-at-launch: the phone sets it
    /// equal to its (slightly wider) labelW so the compact gutter is all name zone — wide
    /// enough for the month timeline's in-gutter hour labels ("9AM").
    public nonisolated(unsafe) static var mnameW: CGFloat = 28
    /// Height reserved for the floating bottom toolbar (phone; 0 on desktop). The month/week
    /// timeline bottoms out above it: tlBottom = vp.h − 8 − bottomBarH.
    public nonisolated(unsafe) static var bottomBarH: CGFloat = 0
    /// The timeline's bottom edge for a viewport — single source for scene + hit-testing.
    public static func tlBottomY(_ vpH: CGFloat) -> CGFloat {
        vpH - 8 - bottomBarH
    }

    public static let rightPad: CGFloat = 24 // gap between gutter editor and day grid
    public static let trackH: CGFloat = 40 // fixed lane height (room for 13pt labels)
    public static let monthH: CGFloat = trackH * 4 // a month band = 4 lanes
    public static let qHeaderH: CGFloat = 24 // day-number header row per quarter
    public static let qGap: CGFloat = 32 // separation between quarters

    // Global insets for the whole calendar. The geometry works in a viewport shrunk
    // by padLeft+padRight; the render is translated right by padLeft (so x=0 in
    // geometry space lands padLeft px from the window's left edge).
    // padLeft shares labelW's write-once-at-launch contract: desktop keeps 20, the
    // iPhone app zeroes it before the first render (month names flush to the edge).
    public nonisolated(unsafe) static var padLeft: CGFloat = 20
    public static let padRight: CGFloat = 0

    /// Minimum pinned MONTHLY dashboard width (px) — the panel never squeezes below this, no
    /// matter the persisted fraction or window size.
    public static let dashMonthMinW: CGFloat = 300

    /// The zoom `z` where the day-detail timeline starts revealing (hour grid, timed-event
    /// hit-testing, sub-labels). Below it the month grid is flat; the reveal ramps over
    /// `detailRamp` and completes at z = detailZ + detailRamp = 1 (month level).
    public static let detailZ: CGFloat = 0.82
    /// Width of the detail reveal ramp in z units (1 − detailZ); the divisor in every
    /// `(z − detailZ) / detailRamp` reveal fraction.
    public static let detailRamp: CGFloat = 0.18

    /// Eviction threshold shared by the string-measurement caches (band label widths, sticker
    /// truncation, renderer text, panel day strings): drop the whole cache past this many
    /// entries. (The chip IMAGE cache uses a smaller deliberate cap — images cost more.)
    public static let measureCacheCap = 4096

    /// ── Viewport-overflow edge indicators (week/day hour timelines) ────────────────
    /// THE hand-tunable size of the Apple-Calendar-style scrolled-off-event indicators
    /// (see EdgeIndicators.swift). One knob, four duties: the innermost card's height,
    /// the stack's per-level indentation step, the per-level HEIGHT step of the card
    /// staircase (1st card = H, 2nd = 2H, 3rd = 3H tall, all edge-pinned), AND the
    /// clamp remnant (an event stops shrinking once this many px remain visible at the
    /// edge). All widths/offsets/heights derive from it — 1 indicator → full event
    /// width, H tall; 2 → each (full − H) wide, stepped H apart, H/2H tall; 3 → each
    /// (full − 2H), stepped 0/H/2H, H/2H/3H tall — so one edit re-tunes the feature.
    public static let edgeIndicatorH: CGFloat = 5
    /// Scroll distance (px past the clamp point) over which each indicator morph plays
    /// out: joining/leaving the stack, indent shifts, the 4th-event handoff. The layout
    /// is a continuous piecewise-linear function of each event's overshoot — purely
    /// scroll-driven, never a timed animation.
    public static let edgeIndicatorMorph: CGFloat = 14
    /// At most this many indicators per edge; deeper events hide behind the outermost.
    public static let edgeIndicatorMax = 3

    /// Day-view split fraction (timeline width ÷ content width) drag bounds: neither the
    /// timeline nor the dashboard may collapse.
    public static let dayFracMin: CGFloat = 0.22
    public static let dayFracMax: CGFloat = 0.82
    /// First-layout default clamp floor — roomier than the drag floor so the initial
    /// auto-narrowed split never starts at the extreme (the user can still drag to dayFracMin).
    public static let dayFracDefaultMin: CGFloat = 0.28
}

@inlinable public func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

@inlinable public func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    min(max(v, lo), hi)
}

@inlinable public func easeInOut(_ t: CGFloat) -> CGFloat {
    t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
}

@inlinable public func easeOut(_ t: CGFloat) -> CGFloat {
    1 - pow(1 - t, 3)
}
