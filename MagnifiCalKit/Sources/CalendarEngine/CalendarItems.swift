// The user's calendar data, composed: the single mutable source of truth the engine edits,
// undo snapshots, and the sync layer persists. First step of the engine's field-composition
// hierarchy (items / caches / cursor / … instead of one flat sea of properties).

import CalendarGeometry
import CoreGraphics
import Foundation

public struct CalendarItems: Sendable {
    public internal(set) var events: [TimedEvent] = []
    public internal(set) var bands: [BandEvent] = []
    public internal(set) var deadlines: [Deadline] = []
    public init() {}

    /// Rich per-item overlays (tags, notes, repeat config, promote-track, hidden flags),
    /// keyed by stable item id — including overlay keys for imported items.
    var richById: [String: RichFields] = [:]

    /// Daily notepad bodies keyed by ISO date ("YYYY-MM-DD"); empty entries are pruned.
    var dailyNotes: [String: String] = [:]

    /// Per-month lane labels (12 × 4). Read-only outside the engine module.
    public internal(set) var trackNames = Array(repeating: TRACKS.map(\.name), count: 12)
}

/// Derived-display caches + their invalidation generations — rebuilt on demand, keyed by
/// `editGen`, never persisted. Composed so the engine's cache state is one visible unit.
struct DisplayCaches {
    /// Bumped on every edit → invalidates all the per-(year, gen) caches below.
    var editGen = 0
    /// Bumped on daily/scope NOTE edits only. Notes never affect the calendar display, so a
    /// notepad keystroke must not invalidate the event/band caches above — but the dashboard
    /// payload (dashJSONCache) keys on (editGen, noteGen) and must see it.
    var noteGen = 0
    /// Bumped when the deadline-label sides must re-solve.
    var deadlineGen = 0
    /// Keyed by display year, NOT a single slot: week/day view in Jan (Dec) reads the focus year AND
    /// the boundary year every frame (`boundaryYears`), so one slot would evict one with the other and
    /// rebuild both caches on every frame of a swipe. Writers prune entries from older generations, so
    /// the maps only ever hold the current gen's visited years.
    var band: [Int: (gen: Int, bands: [BandEvent], badges: [String: EventBadges], byMonth: [Int: [BandEvent]])] = [:]
    var event: [Int: (gen: Int, events: [TimedEvent], badges: [String: EventBadges], byDay: [Int: [TimedEvent]])] = [:]
    var ddl: [Int: (gen: Int, deadlines: [Deadline])] = [:]
    var ddlSides: [String: Bool] = [:]
    var ddlSidesKey: (focus: Int, incoming: Int, year: Int, gen: Int, detail: Bool, zRest: CGFloat)?
    var search: (gen: Int, docs: [CalendarEngine.SearchDoc])?
    /// The tag universe (View ▸ Filter by Tags), indexed once per edit generation. Rebuilt lazily on the
    /// next read after any mutation (editGen bump), then reused across every popover render / search keystroke.
    var tag: (gen: Int, rows: [(key: String, label: String, count: Int)], untagged: Int)?
}

/// Read-only items imported from Apple Calendar (EventKit). Kept SEPARATE from `items` so they
/// never persist to disk / push to iCloud (they're re-fetched) and can't be edited.
public struct ImportedItems: Sendable {
    public internal(set) var events: [TimedEvent] = []
    public internal(set) var bands: [BandEvent] = []
    /// EventKit identifier → our item id, for opening the original in Calendar.app.
    var appleEventIds: [String: String] = [:]
    /// ICS-feed series id ("gcal-<key>-<uid>") → the RAW VEVENT UID, for building the
    /// "Edit original" Google Calendar deep link (the id's uid part is sanitized/truncated).
    var gcalUids: [String: String] = [:]
    public init() {}
}

/// The keyboard-navigation cursor family: the block cursor (month/day/hour), the band-lane and
/// track-name cursors, and the day-view dashboard stops. One unit of "where keyboard focus is".
public struct CursorState {
    /// Keyboard mode is ON (arrow keys drive a cursor; mouse motion turns it off).
    public internal(set) var keyboardActive = false
    public internal(set) var blockMonth = 0
    public internal(set) var blockDay = 1
    public internal(set) var blockHour: CGFloat = 12
    public internal(set) var bandCursorActive = false
    public internal(set) var bandCurTrack = 0
    public internal(set) var trackNameCursor: Int?
    public internal(set) var dashStop: CalendarEngine.DashStop?
    public internal(set) var dashNoteEditing = false
    /// The event to re-select when ⇧Tab leaves the TODO stop.
    var dashReturnEvent: String?
    /// One-step directional memory: the last event move, so the exact reverse arrow returns.
    var lastEventMove: (from: String, dx: Int, dy: Int, to: String)?
    public init() {}
}

/// In-flight animation machinery: active tweens, year/month/week/day flips with their fades,
/// zoom anchoring, and the one-shot completion callbacks that sequence multi-phase navigations
/// (e.g. jumpToDay: fly out → flip year → fly in). All transient; never persisted.
struct AnimState {
    var tween: Tween? // the z (zoom-level) tween
    var scrollTween: Tween? // year-view vertical scroll glide (before a zoom-in)
    var tlScrollTween: Tween? // timeline (hour) scroll glide
    var weekTween: Tween?
    var dayTween: Tween? // fractional-day glide (day view "scroll to today")
    var monthGlide: Tween? // fractional-month glide (month view jumpToMonth — animated pagination)
    var shiftTween: Tween? // drawer canvas-shift
    var gutterTween: Tween? // gutter hide/show slide (narrow window + pinned dashboard)
    var dashPinTween: Tween? // pinned weekly/monthly dashboard slide (⌘B toggle)
    var zTweenDone: (() -> Void)?
    var weekTweenDone: (() -> Void)?
    var scrollTweenDone: (() -> Void)?
    var flipDone: (() -> Void)?
    var dayLandDone: (() -> Void)?
    var weekLandDone: (() -> Void)? // jumpToWeek settled at week view (e.g. open a weekly note's NOTE tab)
    var monthLandDone: (() -> Void)? // jumpToMonth settled at month view (glide or zoom path)
    var zoomAnchorHour: CGFloat? // hour held at `zoomAnchorY` for the duration of a zoom
    var zoomAnchorY: CGFloat? // viewport y to hold it at (nil = viewport centre)
    var monthAnim: PageAnim? // vertical month↕month page-turn (nil = settled)
    var flipAnim: CalendarEngine.FlipAnim?
    var flipFade: CGFloat = 1
    var monthFlip: CalendarEngine.MonthFlip?
    var monthFlipShift: CGFloat = 0
    var weekFlip: CalendarEngine.WeekFlip?
    var weekFlipFade: CGFloat = 0 // 0→1 cross-fade of the dim/bright swap
    var dayFlip: CalendarEngine.DayFlip?
}

/// Transient scroll-GESTURE bookkeeping: which pager is in its fingers-down phase, edge pulls,
/// and overscroll flip-arming. Distinct from view position (z/focus/week/scrollY/tlScroll stay
/// on the engine) — this is only the in-progress gesture state.
struct ScrollGestureState {
    var didInitialScroll = false // center the current month once, at first layout
    var liveScrolling = false // fingers-down phase of a trackpad gesture (year view)
    var liveMonthScrolling = false
    var liveWeekScrolling = false
    var liveDayScrolling = false
    var startedAtTop = false // the drag began already resting at an edge —
    var startedAtBottom = false // only then does an overscroll pull arm a flip
    var lastOverscroll: (over: CGFloat, atTop: Bool) = (0, false)
    var wheelAccumX: CGFloat = 0
    var yearPull: YearPull? // pull-to-change-year hint (nil when not pulling)
    var monthPull: YearPull?
    var weekPull: WeekPull?
    var dayPull: DayPull?
    var daySettleWork: DispatchWorkItem? // safety-net: snap a residual day-page if the pager stalls
}
