// Shared value types for the calendar layout. Ported from geometry/types.ts.
// Everything here is a pure value type — Sendable, no reference semantics.

import CoreGraphics
import Foundation

public struct Viewport: Sendable, Equatable {
    public var w: CGFloat
    public var h: CGFloat
    public init(w: CGFloat, h: CGFloat) {
        self.w = w; self.h = h
    }
}

/// A month's geometry at the current zoom: where day 1 sits, day width, band top,
/// track-row height, and overall opacity.
public struct Frame: Sendable, Equatable {
    public var x0: CGFloat // pixel of day-1's left edge
    public var dayW: CGFloat // per-day column width
    public var bandY: CGFloat // top of the 4-lane band
    public var trackH: CGFloat // lane height
    public var opacity: CGFloat
    public init(x0: CGFloat, dayW: CGFloat, bandY: CGFloat, trackH: CGFloat, opacity: CGFloat) {
        self.x0 = x0; self.dayW = dayW; self.bandY = bandY; self.trackH = trackH; self.opacity = opacity
    }
}

/// Cursor-driven hover targets, resolved per zoom bucket.
/// The quick-add "+" affordance for a deadline: its on-screen point + the target date/hour it creates.
public struct DeadlineAddSpot: Sendable, Equatable {
    public let x: CGFloat
    public let y: CGFloat
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let hovering: Bool // the cursor is directly over the "+" → brighten it
    public init(x: CGFloat, y: CGFloat, year: Int, month: Int, day: Int, hour: Int, hovering: Bool = false) {
        self.x = x; self.y = y; self.year = year; self.month = month; self.day = day; self.hour = hour; self
            .hovering = hovering
    }
}

public struct Hover: Sendable, Equatable {
    public var month: Int?
    public var dom: Int?
    public var week: Int?
    public var track: Int? // hovered track lane 0…3 (month view)
    public var hour: Int?
    public var hourFrac: CGFloat?
    public var nameMonth: Int?
    public var nearLeft: Bool?
    public var overTimed: Bool // cursor is over a timed event → hide the cursor LINE, keep the end dots + tag
    public var overDeadline: Bool // cursor is over a deadline → hide the whole cursor (line, dots, tag)
    public init(month: Int? = nil, dom: Int? = nil, week: Int? = nil, track: Int? = nil, hour: Int? = nil,
                hourFrac: CGFloat? = nil, nameMonth: Int? = nil, nearLeft: Bool? = nil,
                overTimed: Bool = false, overDeadline: Bool = false) {
        self.month = month; self.dom = dom; self.week = week; self.track = track; self.hour = hour
        self.hourFrac = hourFrac; self.nameMonth = nameMonth; self.nearLeft = nearLeft
        self.overTimed = overTimed; self.overDeadline = overDeadline
    }

    public static let none = Hover()
}

public enum ItemKind: Sendable {
    case row, event, monthLabel, dayLabel, gridline, dim, hl, today, todayMonth, now
    case todayTag, nowLabel, timeTag, cursor, weekdayTag, weekend
}

public enum TextAlign: Sendable { case left, center, right }
public enum LineStyle: Sendable { case dashed, dotted }

/// One positioned visual primitive produced by buildScene(). Mirrors types.ts Item;
/// x/y/w/h are kept separate (as in the TS) so the port stays literal.
public struct Item: Sendable {
    public var key: String
    public var kind: ItemKind
    public var x: CGFloat
    public var y: CGFloat
    public var w: CGFloat
    public var h: CGFloat
    public var opacity: CGFloat
    public var z: Int = 0
    public var color: String? // palette key (red/blue/…) — rows & events
    public var text: String?
    public var fontSize: CGFloat?
    public var align: TextAlign = .center
    public var cols: Int? // row: number of day cells for the dotted verticals
    public var lineStyle: LineStyle?
    public var inner: Bool = false // row: inner lane (t>0) → dotted top separator
    public var instant: Bool = false // now/label: drop the opacity transition
    public var today: Bool = false // dayLabel: red capsule + white text
    public var gutter: Bool = false // lives in the left gutter [0, LABEL_W]:
    // month name, hour labels, gutter borders, gutter hover
    public var lineW: CGFloat = 1 // gridline stroke width
    public var hollow: Bool = false // cursor: draw only the end dots, not the connecting line

    public var rect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// NOTE: `z` is declared LAST-ish (Swift call-site args must follow declared order),
    /// so every call lists styling before z: color, text, fontSize, align, cols,
    /// lineStyle, inner, instant, today, then z, then gutter, then lineW, then hollow.
    public init(key: String, kind: ItemKind, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                opacity: CGFloat, color: String? = nil, text: String? = nil,
                fontSize: CGFloat? = nil, align: TextAlign = .center, cols: Int? = nil,
                lineStyle: LineStyle? = nil, inner: Bool = false, instant: Bool = false,
                today: Bool = false, z: Int = 0, gutter: Bool = false, lineW: CGFloat = 1,
                hollow: Bool = false) {
        self.key = key; self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h
        self.opacity = opacity; self.z = z; self.color = color; self.text = text; self.gutter = gutter
        self.lineW = lineW; self.hollow = hollow
        self.fontSize = fontSize; self.align = align; self.cols = cols; self.lineStyle = lineStyle
        self.inner = inner; self.instant = instant; self.today = today
    }
}

public struct Scene: Sendable {
    public var items: [Item]
    public init(items: [Item]) {
        self.items = items
    }
}

// ── Page-turn + daily state (was module-level globals in frames.ts) ──────────────

public struct PageAnim: Sendable, Equatable {
    public var dir: Int // +1 next, -1 prev
    public var p: CGFloat // 0…1 progress
    public init(dir: Int, p: CGFloat) {
        self.dir = dir; self.p = p
    }
}

public struct DailyState: Sendable, Equatable {
    public var dom: Int // chosen day (focus-relative day-of-month)
    public var frac: CGFloat // timeline width as a fraction of the content area
    public var anim: PageAnim? // day↔day paging
    public var over: CGFloat // month-boundary overscroll (px)
    public init(dom: Int = 1, frac: CGFloat = 0.45, anim: PageAnim? = nil, over: CGFloat = 0) {
        self.dom = dom; self.frac = frac; self.anim = anim; self.over = over
    }
}

/// Year-view overscroll pull state, for the pull-to-change-year hint. `over` is the
/// rubber-banded overscroll distance (px); `armed` means past the flip threshold.
public struct YearPull: Sendable, Equatable {
    public var targetYear: Int
    public var atTop: Bool // pulling down past the top (→ previous year) vs up past bottom
    public var over: CGFloat
    public var armed: Bool
    public init(targetYear: Int, atTop: Bool, over: CGFloat, armed: Bool) {
        self.targetYear = targetYear; self.atTop = atTop; self.over = over; self.armed = armed
    }
}

/// Week-view boundary pull state, for the overscroll flip hint. `shared` distinguishes a
/// dim-swap (the boundary week already shows the neighbor month, dimmed → it just brightens)
/// from an aligned advance (month ends/starts on a week boundary → a real move to a new week).
public struct WeekPull: Sendable, Equatable {
    public var dir: Int // +1 next month, -1 previous
    public var over: CGFloat // rubber-banded overscroll distance (px)
    public var armed: Bool // past the flip threshold
    public var shared: Bool // dim-swap boundary vs aligned advance
    public var targetMonth: Int // 0–11
    public var targetYear: Int
    public init(dir: Int, over: CGFloat, armed: Bool, shared: Bool, targetMonth: Int, targetYear: Int) {
        self.dir = dir; self.over = over; self.armed = armed
        self.shared = shared; self.targetMonth = targetMonth; self.targetYear = targetYear
    }
}

/// Day-view boundary pull state, for the overscroll flip hint. Simpler than WeekPull — a day flip is
/// always a plain advance to the neighbor month's first/last day (no shared-week reveal).
public struct DayPull: Sendable, Equatable {
    public var dir: Int // +1 next month, -1 previous
    public var over: CGFloat // rubber-banded overscroll distance (px)
    public var armed: Bool // past the flip threshold
    public var targetMonth: Int // 0–11
    public var targetYear: Int
    public init(dir: Int, over: CGFloat, armed: Bool, targetMonth: Int, targetYear: Int) {
        self.dir = dir; self.over = over; self.armed = armed
        self.targetMonth = targetMonth; self.targetYear = targetYear
    }
}

/// Everything a frame/scene needs, by value. Replaces the TS module-level singletons
/// (setDaily / syncWeekHourH / setCalendarYear) — so all geometry is a pure function
/// of its arguments and safe under strict concurrency.
public struct SceneInput: Sendable, Equatable {
    public var z: CGFloat
    public var focus: Int
    public var week: CGFloat
    public var vp: Viewport
    public var scrollY: CGFloat
    public var tlScroll: CGFloat
    public var now: Date
    public var year: Int
    public var hover: Hover
    public var weekHourH: CGFloat
    public var daily: DailyState
    public var monthAnim: PageAnim?
    public var detailMul: CGFloat
    public var altDeltaHours: CGFloat?
    public var altLabel: String?
    public var mainTz: String // the deadline main timezone id (for origin-tz labels)
    public var dimPast: Bool
    public var yearPull: YearPull?
    public var flipFade: CGFloat // whole-calendar opacity for the year/month-flip transition
    public var animating: Bool // a tween/flip/page-turn is in flight → cheaper rendering OK
    public var monthPull: YearPull? // month-view boundary pull (Jan→prev Dec / Dec→next Jan)
    public var monthFlipShift: CGFloat // vertical px offset applied to the month view during a flip
    public var weekPull: WeekPull? // week-view boundary pull (overscroll flip hint)
    public var weekFlipDir: Int // in-flight week-boundary flip direction (0 = none, ±1)
    public var weekFlipFade: CGFloat // 0→1 cross-fade progress of the dim/bright swap
    public var dayPull: DayPull? // day-view boundary pull (overscroll flip hint)
    /// Per-QUARTER horizontal scroll offsets for the year view (phone: min-width day cells
    /// overflow each quarter into its own scroll; desktop: always zeros). Grid content shifts
    /// left by yearQX[q]; gutter items (month names) don't, so they stick.
    public var yearQX: [CGFloat]
    /// MONTH-view horizontal scroll offset (phone: the focused month's 31 min-width columns
    /// overflow into one scroll; desktop: always 0). Same shift model as yearQX.
    public var monthQX: CGFloat

    /// Pinned (⌘B) weekly/monthly dashboard: 0 = retracted, 1 = out, animated on toggle. Drives
    /// the panel reveal at month/week zoom AND the week/month grid squeeze (the whole week/month
    /// stays visible, compressed left of the panel). Day view forces the panel regardless.
    public var dashPin: CGFloat = 0
    /// Per-scope pinned panel widths (fractions of the content area), persisted user prefs: the
    /// daily split is `daily.frac`; these cover week and month. Generally day > week > month —
    /// the panel MORPHS between them as the zoom crosses scopes (see dashboardLeftAnimated).
    public var dashWeekFrac: CGFloat = 0.35
    public var dashMonthFrac: CGFloat = 0.25
    /// Engine-driven override of the weekly-dashboard carousel (big-fling cruise, interception
    /// freeze, release settle). nil → the pure wed→thu band mapping of `week` applies.
    public var weekDash: WeekDashOverride?

    /// Weekly-dashboard carousel override: a fixed pair of week indexes + live progress, taking
    /// over from the band mapping while a week glide cruises / a caught glide is frozen / a
    /// release settles. Week indexes are month-relative (like `week`) and may spill outside.
    public struct WeekDashOverride: Equatable, Sendable {
        public var from: Int // week index of panel A
        public var to: Int // week index of panel B
        public var p: CGFloat // carousel progress between them (0 = A at rest … 1 = B at rest)
        public init(from: Int, to: Int, p: CGFloat) {
            self.from = from; self.to = to; self.p = p
        }
    }

    /// Month `m`'s quarter scroll offset (safe on a short/empty array).
    public func qx(_ m: Int) -> CGFloat {
        let q = m / 3
        return yearQX.indices.contains(q) ? yearQX[q] : 0
    }

    public init(z: CGFloat, focus: Int, week: CGFloat, vp: Viewport, scrollY: CGFloat,
                tlScroll: CGFloat, now: Date, year: Int, hover: Hover = .none,
                weekHourH: CGFloat = 60, daily: DailyState = DailyState(), monthAnim: PageAnim? = nil,
                detailMul: CGFloat = 1, altDeltaHours: CGFloat? = nil, altLabel: String? = nil,
                dimPast: Bool = false, yearPull: YearPull? = nil, flipFade: CGFloat = 1,
                animating: Bool = false, monthPull: YearPull? = nil, monthFlipShift: CGFloat = 0,
                weekPull: WeekPull? = nil, weekFlipDir: Int = 0, weekFlipFade: CGFloat = 0,
                dayPull: DayPull? = nil,
                mainTz: String = "auto",
                yearQX: [CGFloat] = [0, 0, 0, 0],
                monthQX: CGFloat = 0) {
        self.z = z; self.focus = focus; self.week = week; self.vp = vp; self.scrollY = scrollY
        self.tlScroll = tlScroll; self.now = now; self.year = year; self.hover = hover
        self.weekHourH = weekHourH; self.daily = daily; self.monthAnim = monthAnim
        self.detailMul = detailMul; self.altDeltaHours = altDeltaHours; self.altLabel = altLabel
        self.mainTz = mainTz
        self.dimPast = dimPast; self.yearPull = yearPull; self.flipFade = flipFade
        self.animating = animating; self.monthPull = monthPull; self.monthFlipShift = monthFlipShift
        self.weekPull = weekPull; self.weekFlipDir = weekFlipDir; self.weekFlipFade = weekFlipFade
        self.dayPull = dayPull
        self.yearQX = yearQX
        self.monthQX = monthQX
    }
}
