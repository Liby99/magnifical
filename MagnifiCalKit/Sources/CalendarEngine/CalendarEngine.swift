// The mutable view-state + anim.tween clock. Geometry is stateless; this is where z,
// focus, week, scroll, hover, and the animation live. SwiftUI observes it directly.

import CalendarGeometry
import CoreGraphics
import Foundation

/// iCloud connectivity as the settings UI needs to describe it. `localOnly` means this
/// build isn't entitled for CloudKit (the unsigned dev binary), so it never touches iCloud;
/// the rest mirror `CKAccountStatus` once entitled.
public enum ICloudStatus: Sendable {
    case localOnly, available, noAccount, restricted, unavailable, unknown
}

/// The note-content edit generation, as an OBSERVABLE object on the otherwise non-observable
/// engine (the RenderClock pattern). Views that display note content at REST (the dashboard
/// NOTE preview) read `gen` in their body: a checkbox toggle on a static screen then repaints
/// through Observation immediately — the render loop's TimelineView can't be relied on for
/// this, because ProMotion idles a static display and the 0.4s idle-sleep can pause the
/// timeline before a single tick delivers the new state (the "preview repaints only on the
/// next mouse move" bug).
@MainActor @Observable public final class NoteEditGen {
    public internal(set) var gen = 0
}

/// Drives whether the calendar's per-frame `TimelineView` renders. The engine is a plain (non-
/// @Observable) type redrawn every frame; without this, `TimelineView(.animation)` burns a full-scene
/// render at display rate even when nothing changes. `awake` is the ONE observable bit the view reads:
/// `paused: !awake`. The engine wakes it on any input/animation/edit and sleeps it after a short idle.
@MainActor @Observable public final class RenderClock {
    public internal(set) var awake = true
}

/// Plain reference type (not @Observable): the view redraws every frame via
/// TimelineView(.animation), which reads a fresh SceneInput and advances the anim.tween
/// from the display clock — so observation isn't needed and can't cause update loops.
@MainActor
public final class CalendarEngine {
    /// Render loop: the calendar's TimelineView pauses when `renderClock.awake` is false (idle).
    public let renderClock = RenderClock()
    /// Observable note-edit generation — see NoteEditGen. Bumped by setDailyNote.
    public let noteEdits = NoteEditGen()
    private var sleepWork: DispatchWorkItem?

    /// Kick the render loop — call at every input / animation-start / edit entry point. Cheap +
    /// idempotent, so over-calling is fine. Wakes the clock (if asleep) and (re)arms the idle sleep.
    /// The sleep runs OFF the render pass (a work item, not inside sceneInput) so we never mutate the
    /// observable `awake` during a SwiftUI view update.
    public func wake() {
        if !renderClock.awake {
            renderClock.awake = true
            if let began = sleepBegan {
                recentSleeps.append((began, Date.timeIntervalSinceReferenceDate))
                if recentSleeps.count > 16 {
                    recentSleeps.removeFirst(8)
                }
                sleepBegan = nil
            }
            if CalendarEngine.traceOn {
                NotificationCenter.default.post(name: .ccTraceClock, object: true)
            }
        }
        armSleep()
    }

    /// Recent render-clock sleep spans (start, end), newest last — the HUD subtracts these so
    /// its fps reflects ANIMATED cadence, not wall time diluted by legitimate idle sleeps.
    public private(set) var recentSleeps: [(start: Double, end: Double)] = []
    private var sleepBegan: Double?

    /// Total sleep time overlapping [a, b] (timeIntervalSinceReferenceDate space).
    public func sleepOverlap(_ a: Double, _ b: Double) -> Double {
        var total = 0.0
        for s in recentSleeps {
            total += max(0, min(b, s.end) - max(a, s.start))
        }
        if let open = sleepBegan { // currently asleep
            total += max(0, b - max(a, open))
        }
        return total
    }

    /// CC_TRACE: clock transitions feed the interaction trace (sleep vs stall separation).
    static let traceOn = ProcessInfo.processInfo.environment["CC_TRACE"] != nil

    /// (Re)schedule the idle sleep. While anything is animating the timer keeps deferring; once the
    /// scene is fully at rest for `Motion.idleSleep`, it pauses the TimelineView.
    private func armSleep() {
        sleepWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.needsRender {
                self.armSleep()
            } else {
                self.renderClock.awake = false
                self.sleepBegan = Date.timeIntervalSinceReferenceDate
                if CalendarEngine.traceOn {
                    NotificationCenter.default.post(name: .ccTraceClock, object: false)
                }
            }
        }
        sleepWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.idleSleep, execute: w)
    }

    /// Anything that changes the scene frame-to-frame (so the loop must stay awake). `isAnimating`
    /// covers the z/scroll/week/day tweens + flips; add the rest of the live/elastic/drag states.
    private var needsRender: Bool {
        isAnimating || anim.shiftTween != nil || anim.gutterTween != nil || anim.dashPinTween != nil || anim
            .monthFlip != nil || drag != nil || daily.anim != nil
            // An unsettled week-dash hold MUST keep ticking: its idle-settle fallback (0.3s) and the
            // settle tween itself only advance in the tick — sleeping mid-settle froze the carousel
            // progress at a mid value, which left the week panel's tab row permanently un-clickable
            // (its hit gate requires the turn to be at an endpoint).
            || weekDashHold != nil || weekDashSettle != nil
            || scroll.liveScrolling || scroll.liveMonthScrolling || scroll.liveWeekScrolling || scroll.liveDayScrolling
            || scroll.yearPull != nil || scroll.monthPull != nil || scroll.weekPull != nil || scroll.dayPull != nil
    }

    /// View state
    public internal(set) var z: CGFloat = 0
    /// Upper semantic-zoom bound for this client (year 0 … day 3): the pinch path clamps here
    /// so a zoom can't land on a level whose touch driver isn't mounted. Both platforms
    /// currently expose all four levels.
    public var maxZ: CGFloat = 3
    /// The daily DASHBOARD panel exists on this client (Mac: notes/todos webview beside the
    /// day timeline). The iPhone mounts none — it pins the daily split to 1 (full-width day
    /// column) and skips the first-layout "roomier dashboard" default (see setViewport).
    public var hasDailyDashboard = true
    public internal(set) var focus: Int
    public internal(set) var week: CGFloat = 0
    public internal(set) var scrollY: CGFloat = 0
    public internal(set) var tlScroll: CGFloat = 0

    /// Pinned (⌘B) weekly/monthly dashboard: the persisted user intent…
    public internal(set) var dashPinned = UserDefaults.standard.bool(forKey: PrefKeys.dashPinned)
    /// …and its animated presentation value (0 retracted … 1 out), tweened on toggle.
    public internal(set) var dashPin: CGFloat = UserDefaults.standard.bool(forKey: PrefKeys.dashPinned) ? 1 : 0
    /// Per-scope pinned panel widths (persisted; defaults month 0.25 < week 0.35 < daily.frac split).
    public internal(set) var dashWeekFrac: CGFloat = {
        let v = UserDefaults.standard.double(forKey: PrefKeys.dashWeekFrac); return v > 0 ? v : 0.35
    }()

    public internal(set) var dashMonthFrac: CGFloat = {
        let v = UserDefaults.standard.double(forKey: PrefKeys.dashMonthFrac); return v > 0 ? v : 0.25
    }()

    /// ── Weekly-dashboard carousel override (big-fling cruise / catch-freeze / release-settle) ──
    /// nil hold → the pure wed→thu band mapping of `week` drives the carousel (the default).
    /// A hard fling arms a CRUISE (progress rides the whole glide, proportionally); catching the
    /// glide freezes the hold; releasing settles it back onto the band. See weekGlideWillLand.
    struct WeekDashHold {
        var from: Int // week index of panel A
        var to: Int // week index of panel B
        var q: CGFloat // live carousel progress
    }

    var weekDashHold: WeekDashHold?
    var weekDashCruise: (wStart: CGFloat, wTarget: CGFloat, qStart: CGFloat, qTarget: CGFloat)?
    var weekDashSettle: Tween?
    var weekDashIdleAt = Date.distantPast // last time `week` moved (idle-settle fallback)

    /// Autocomplete entity index (projects/people/tags) as JSON, cached per editGen — feeds the
    /// drawer note editor's completions. Non-persistent. See entityIndexJSON().
    var entityIdxCache: (gen: Int, json: String)?
    var entityIdxWork: DispatchWorkItem? // coalesced async refresh (never scans on a keystroke)

    /// The native TODO feed: the fully-parsed index over the whole store, cached per
    /// (editGen, noteGen, today) — see CalendarEngine+TodoFeed.
    var todoFeedCache: (gen: Int, noteGen: Int, today: String, todos: [ParsedTodo])?
    /// The native PROJECTS index, same cadence — see ProjIndex.
    var projFeedCache: (gen: Int, noteGen: Int, today: String, projects: [Project])?
    var todoFeedWork: DispatchWorkItem? // coalesced burst refresh (never rebuilds on the frame path)
    // Land callbacks fire when the jump's final tween completes — which happens INSIDE sceneInput,
    // i.e. mid-render. The callbacks write SwiftUI state (the dashboard tab), so defer them off the
    // render pass; the hop also sequences them AFTER any chrome.level onChange work already queued
    // (the "leaving day view → TODO tab" reset must not clobber a landing's NOTE-tab switch).
    func fireDayLand() {
        if let cb = anim.dayLandDone {
            anim.dayLandDone = nil
            DispatchQueue.main.async { cb() }
        }
    }

    func fireWeekLand() {
        if let cb = anim.weekLandDone {
            anim.weekLandDone = nil
            DispatchQueue.main.async { cb() }
        }
    }

    func fireMonthLand() {
        if let cb = anim.monthLandDone {
            anim.monthLandDone = nil
            DispatchQueue.main.async { cb() }
        }
    }

    public internal(set) var daily: DailyState
    public internal(set) var hover: Hover = .none
    public internal(set) var pointerPos: CGPoint? // last hover point (calendar space) → is the cursor on the deadline
    // "+"?
    /// The cursor is near the timeline's left border (week/day) → reveal the scale bar.
    public internal(set) var nearTlEdge = false
    public internal(set) var year: Int
    public let systemYear: Int // the real "today" year at launch — anchors the picker range
    public var mainTz: String = "auto" // deadline main timezone (for origin-tz labels); "auto" = device zone
    public var altTz: String = "none" // View ▸ Alternative Timezone → the second hour column; "none" = off
    public internal(set) var now: Date = .init()

    /// Fractional-hour shift for the alt-tz hour column (nil = off). DST-aware at `now`.
    private var altDeltaHours: CGFloat? {
        guard altTz != "none", !altTz.isEmpty, altTz != mainTz else { return nil }
        return CGFloat(DeadlineTZ.hourShift(from: mainTz, to: altTz, at: now))
    }

    /// Header abbreviation for the alt-tz column (e.g. "JST"), nil when off.
    private var altColumnLabel: String? {
        guard altTz != "none", !altTz.isEmpty, altTz != mainTz else { return nil }
        return DeadlineTZ.shortLabel(altTz, at: now)
    }

    public internal(set) var weekHourH: CGFloat = 60 // set via setWeekHourH (clamped + persisted)
    public internal(set) var viewport: Viewport = .init(w: 1, h: 1)
    /// The user's calendar DATA — the single mutable source of truth that edits mutate, undo
    /// snapshots, and the sync layer persists. (Historically the flat `items.events`/`items.bands`/
    /// `items.deadlines` fields; composed here so the engine's state has visible structure.)
    public internal(set) var items = CalendarItems()

    /// Derived-display caches + invalidation generations (see DisplayCaches).
    var caches = DisplayCaches()

    /// Read-only Apple Calendar imports (see ImportedItems) — separate from `items` by design.
    public internal(set) var imported = ImportedItems()

    /// The keyboard-navigation cursor family (see CursorState).
    public internal(set) var cursor = CursorState()

    /// In-flight animation machinery (see AnimState): tweens, flips, fades, zoom anchors, and
    /// the one-shot completion callbacks that sequence multi-phase navigations.
    var anim = AnimState()

    /// Transient scroll-gesture bookkeeping (see ScrollGestureState): live-phase flags, edge
    /// pulls, and overscroll arming. All internal — nothing here is view position.
    var scroll = ScrollGestureState()
    /// Read-only events imported from Apple Calendar (EventKit). Kept SEPARATE from the seed arrays so
    /// they never persist to disk / push to iCloud (they're re-fetched) and can't be edited — every edit
    /// path targets the seed arrays. They're merged into the display caches (see ensureEventCache /
    /// ensureBandCache). User overlays (tags/notes/promote) attach via `items.richById` by the stable id.
    /// Imported id → EKEvent.eventIdentifier, rebuilt each merge. Transient (not persisted): only used to
    /// build the `ical://ekevent/…` deep-link for "Edit original", which is only offered on a live import.
    let appleImporter = AppleCalendarImporter() // internal: +AppleImport (stored props can't move to extensions)
    /// UI-provided: the subscribed ICS feed URLs (stored in the UI-side Keychain). Lets engine-
    /// initiated refreshes (Sync Now) re-import feeds without the engine touching secrets.
    public var icsFeedURLs: (() -> [String])?
    /// Feed key ("gcal-<key>-…" id prefix) → the subscribed feed URL, recorded at import time —
    /// resolves an imported box back to its feed for provenance labels + Edit-original links.
    var icsFeedByKey: [String: String] = [:]
    public var trackEditing = false // an inline track-name field is open (freezes scroll)
    public let chrome = CalendarChrome() // breadcrumb state for the toolbar

    public internal(set) var selectedId: String? { // internal(set): +Extensions files
        // The single "primary" selection. A multi-select op owns both fields (guarded); every OTHER write
        // (click, create, paste, keyboard nav, deselect) is a single selection, so mirror it into the set.
        didSet {
            if !inMultiSelect {
                selectedIds = selectedId.map { [$0] } ?? []
            }
        }
    }

    /// The FULL selection (multi-select). Equals `{selectedId}` for a single selection, empty when nothing
    /// is selected. `selectedId` stays the primary/anchor (drawer, cursor, single-item ops read it).
    public internal(set) var selectedIds: Set<String> = []
    public var multiSelectActive: Bool {
        selectedIds.count > 1
    } // → single-item edit ops are disabled
    var inMultiSelect = false // a multi-select op is writing both fields → skip the didSet sync
    public internal(set) var hoveredEventId: String? // band/timed/deadline under the cursor

    /// ── Keyboard navigation cursor ────────────────────────────────────────────────
    /// `cursor.keyboardActive` gates only the CURSOR VISUAL (last-input-wins): a mouse move/click flips it off,
    /// a dispatched nav key flips it on. The position below always persists. Block-cursor position is
    /// interpreted per view (year → month; month → day; week/day → day + hour); grown one view at a time.
    /// Band cursor = the block cursor's time position (cursor.blockMonth/cursor.blockDay) PLUS a lane. Only these two
    /// extra bits of state: whether we're in band-cursor mode, and which of the 4 lanes.
    /// One-step directional memory (see the doc): the last event move, so the exact reverse arrow returns.
    /// Month view's extra Tab stops: which of the 4 track NAMES is focused (nil = not on a track name).
    public var onEditTrackName: ((_ month: Int, _ track: Int, _ rect: CGRect) -> Void)?

    /// Day view's extra Tab stops: the dashboard TODO list and the daily NOTE become 2 keyboard focus
    /// targets after the event cursor (see tabCursor). `cursor.dashStop` is the focused one (nil = not on the
    /// dashboard); `cursor.dashNoteEditing` flips true once Enter focuses the note editor (the WebView owns keys
    /// then). The focus ring itself is drawn INSIDE the WebView, driven via `onDashCommand`.
    public enum DashStop: Equatable { case todo, note }
    /// Commands to the dashboard WebView bridge — CalendarView wires this to the native TODO/NOTE tab
    /// and the carousel's JS `CK.nav*` calls (row cursor, toggle, open, focus-the-editor).
    public enum DashCmd: Equatable {
        case focus(DashStop?), move(Int), activate, open, fold(Bool)
        /// ⌘E: enter the note editor. `ring` = keyboard mode was ALREADY active, so the dashed
        /// nav ring stays visible around the editor while the caret blinks inside it.
        case editNote(ring: Bool)
    }

    public var onDashCommand: ((DashCmd) -> Void)?

    /// ── Gutter hide (narrow window + pinned week/month dashboard) ──────────────────
    /// The animated width by which the month-name/track gutter (section A) is slid off-screen
    /// left: 0 = shown, labelW + padLeft = fully hidden with the calendar band's left edge flush
    /// against the WINDOW border (the gutter AND the window's left margin both yield). The scene's
    /// SceneInput viewport is inflated by this amount (sceneInput) and every layer translates left
    /// by it (sceneDX / CSS panel motion / pointer compensation).
    ///
    /// Two factors, recomposed each tick: `gutterHide` (the tweened BINARY decision, 0…1 — narrow
    /// window + pinned dashboard) × a CONTINUOUS z-fade riding the zoom itself — full through
    /// month↔week, ramping out across week→day and month→year with the same easing the scope
    /// reveal uses. So zooming to day view slides the gutter back IN STEP with the pinch instead
    /// of snapping when the level boundary is crossed.
    public internal(set) var gutterShift: CGFloat = 0
    var gutterHide: CGFloat = 0 // tweened hide decision (0 shown … 1 hidden)

    /// The binary decision: with the dashboard PINNED (the intent bit — flips immediately on ⌘B,
    /// so the tween runs in parallel with the pin slide), hide when the calendar band would fall
    /// below its minimum width beside the pinned panel. Level-agnostic — the z-fade handles scope.
    private var gutterHideTarget: CGFloat {
        guard chrome.dashPinned else { return 0 }
        let dashW = z < 1.5
            ? dashMonthPanelW(viewport, frac: chrome.dashMonthFrac)
            : chrome.dashWeekFrac * (viewport.w - Layout.labelW)
        return viewport.w - dashW - Layout.labelW < Motion.gutterHideMinW ? 1 : 0
    }

    /// The timed event currently being moved/resized/created (an ACTIVE drag). The overlay floats it
    /// full-width above its day and excludes it from the others' overlap packing so they don't reflow
    /// mid-edit; nil at rest, so the normal side-by-side layout resumes on drop.
    public var activeTimedDragId: String? {
        guard let d = drag, d.activated else { return nil }
        switch d.kind {
        case .move, .resizeTop, .resizeBottom, .create: return d.eventId
        default: return nil
        }
    }

    // Drawer canvas-shift: while the detail drawer is open the whole calendar slides left so
    // the selected item centers in the free area beside the drawer (ports the web's
    // .cc-drawer-open .app-shell transform). Tweened per-frame like z / week.
    public internal(set) var drawerShift: CGFloat = 0
    var snapWork: DispatchWorkItem?
    // Year-view scroll is driven by a real NSScrollView (native elastic bounce + momentum).
    // The input bridge forwards wheel events to it and mirrors its offset back here via
    // setYearScroll(_:); onSetYearScroll moves it programmatically (flip / year switch).
    public var onSetYearScroll: ((CGFloat) -> Void)?
    public var onEditBand: ((_ id: String, _ rect: CGRect) -> Void)? // open inline title editor
    public var bandEditing = false // an inline band-title field is open (freezes scroll)
    public var onEditTimed: ((_ id: String, _ rect: CGRect) -> Void)? // open inline timed-title editor
    public var timedEditing = false // an inline timed-event-title field is open (freezes scroll)
    /// Open the detail drawer for a just-created item (deadline "+"); `selectTitle` → focus + select-all
    /// the default title so typing replaces it. Wired to the UI (ui.openEventId + ui.selectTitleOnOpen).
    public var onRequestOpenDrawer: ((_ id: String, _ selectTitle: Bool) -> Void)?
    public var drawerOpen = false // the detail drawer is open → suppress calendar hover
    // Fired after an EXTERNAL data change (Apple re-import / iCloud remote apply) that may have removed the
    // item a drawer/dialog is showing. The UI re-validates and closes anything pointing at a vanished item.
    public var onExternalDataChange: (() -> Void)?
    // A blocking modal (the delete-confirm dialog) is up. Mirrored from the UI so the signed app's
    // menu-driven shortcuts (⌘I assistant, ⌘Z undo) — which bypass the calendar's key monitor — can
    // refuse to fire while it's open, matching the monitor's own block on ⌘K/⌘F/etc.
    public var inputModalUp = false
    public var yearFlipEnabled = true // gate the prev/next-year flip
    /// Gate the MONTH view's Dec↔Jan cross-year flip (elastic overscroll past the first/last
    /// page). Off on the phone for now — the pager just rubber-bands at the year edges.
    public var monthYearFlipEnabled = true
    /// Gate the WEEK view's month-edge flip (elastic overscroll past the month's first/last
    /// window). Off on the phone — the window just rubber-bands at the month edges, so an
    /// energetic swipe can't silently land you in the neighbor month.
    public var weekMonthFlipEnabled = true
    /// Gate the DAY view's month-edge flip (overscroll past day 1 / the last day, incl. the
    /// neighbor-day slide-in preview). Off on the phone — same no-silent-month-change policy.
    public var dayMonthFlipEnabled = true
    // Year-flip transition: outgoing year scrolls out + fades, then the incoming year
    // slides in from the opposite edge + fades in. Driven by the per-frame clock.
    struct FlipAnim {
        var dir: Int; var fromYear: Int; var toYear: Int; var startScroll: CGFloat; var start: Date; var fadeOnly: Bool =
            false
    }

    public var isFlipping: Bool {
        anim.flipAnim != nil
    }

    /// Month-view boundary flip: at Jan/Dec, an overscroll pull past the edge flips to the
    /// adjacent year's Dec/Jan. Two-phase like the year flip, but at month level: the current
    /// month exits + fades (phase 1), then the cross-year month enters from the opposite edge
    /// + fades in (phase 2). Reuses `anim.flipFade` for the fade; `anim.monthFlipShift` for the movement.
    struct MonthFlip {
        var dir: Int; var fromYear: Int; var fromFocus: Int; var toYear: Int; var toFocus: Int; var startShift: CGFloat; var start: Date
    }

    public var isMonthFlipping: Bool {
        anim.monthFlip != nil
    }

    // week-view boundary flip (overscroll past a month edge in week view). The 7-day window
    // rubber-bands past the edge; on release, if armed, focus/week re-anchor to the neighbor month
    // and the dim/bright split cross-fades (`anim.weekFlipFade`). See setWeekProgress / endWeekGesture.
    struct WeekFlip { var dir: Int; var startWeek: CGFloat; var toWeek: CGFloat; var start: Date }
    public var isWeekFlipping: Bool {
        anim.weekFlip != nil
    }

    /// day-view boundary flip (overscroll past a month edge in day view). Like the week flip, but a
    /// single day: the day page previews the neighbor month's first/last day (via the spillover
    /// day-page), and on release, if armed, it completes and focus/day re-anchor to that neighbor day.
    /// No dim cross-fade — every day is distinct (there's no "same week" to reveal).
    struct DayFlip {
        var dir: Int; var toYear: Int; var toFocus: Int; var toDom: Int; var startP: CGFloat; var start: Date
    }

    public var isDayFlipping: Bool {
        anim.dayFlip != nil
    }

    public var dayFlipArmed: Bool {
        isDayLevel && (scroll.dayPull?.armed ?? false)
    }

    // pinch state
    var magStartZ: CGFloat = 0
    var magAccum: CGFloat = 0
    private var nowTimer: Timer?
    // pointer / editing state
    var drag: Drag?
    private var createCounter = 0
    // Bumped on every mutation (edits + remote merges) so the derived-band cache (displayBands)
    // invalidates precisely — navigation frames (scroll/zoom/flip) don't touch it, so recurrence
    // expansion runs only when the data actually changed.
    // Bumped only when the deadline set / positions change at COMMIT (add / move-after / delete /
    // remote) — so the OFFLINE deadline-label side assignment recomputes then, not during a drag.
    // undo / redo (whole-state snapshots, coalesced per gesture / typing burst). Snapshots the FULL
    // editable set — events/bands/deadlines AND the rich metadata (notes, tags, repeat, promote),
    // per-month track names, and daily notes — so every edit is undoable, matching the web.
    struct EditState: Equatable {
        var events: [TimedEvent]; var bands: [BandEvent]; var deadlines: [Deadline]
        var rich: [String: RichFields]; var trackNames: [[String]]; var dailyNotes: [String: String]
    }

    var editState: EditState {
        EditState(events: items.events, bands: items.bands, deadlines: items.deadlines,
                  rich: items.richById, trackNames: items.trackNames, dailyNotes: items.dailyNotes)
    }

    var undoStack: [EditState] = []
    var redoStack: [EditState] = []
    var pendingUndo: EditState?
    private var undoWork: DispatchWorkItem?
    /// The set of calendars ("documents"); guarantees a "Main" exists + migrates a legacy install.
    let registry = CalendarRegistry()
    /// Item counts of the INACTIVE calendars for the File ▸ Calendars submenu (see
    /// calendarMenuRows). A closed calendar's store can't change, so entries live until the
    /// calendar is switched away from (refreshed) or removed (dropped).
    var calCountCache: [String: Int] = [:]
    /// The ACTIVE calendar's on-disk store. Set in init() from `registry.activeId`; repointed by
    /// `switchCalendar`. Implicitly-unwrapped so property init needn't reference `registry`.
    var store: ItemStore!
    private var persistWork: DispatchWorkItem?
    /// Full-fidelity fields (notes/tags/recurrence/…) the lean seed arrays don't carry, keyed by
    /// item id. Loaded from / saved to the store and mapped to CloudKit by CloudSync; the renderer
    /// doesn't read these yet, so they just ride along untouched.
    /// Display-derivation caches — used by CalendarEngine+Display.swift:
    var colorPreview: (id: String, color: String)? // internal: +Display (stored caches stay in the class)
    /// Toolbar-search corpus — a pre-folded, flat index of every item across all years, rebuilt ONLY on a
    /// data change (caches.editGen), so each keystroke scans a cached array instead of re-expanding/​re-folding the
    /// whole calendar. See CalendarEngine+Search.swift.
    /// The daily-dashboard NOTE tab: one markdown note per day, keyed by ISO date "YYYY-MM-DD".
    /// ── Cloud-sync seam (Phase 1) ─────────────────────────────────────────────────
    /// The state the sync layer last saw, for computing per-record deltas at persist.
    var syncedState: PersistedState?
    /// Fired at the persist choke point with the record ids that changed since the last
    /// persist: (upserted, deleted). Phase 2's cloud layer maps these to CKSyncEngine
    /// pending changes. A change to the lane labels upserts `trackNamesRecordID`.
    public var onLocalChange: (([String], [String]) -> Void)?
    public static let trackNamesRecordID = "trackNames"
    /// Per-calendar item sync (repointed on switch). `registrySync` is always-on (the calendar LIST,
    /// synced independently of which calendar is open) — see RegistrySync.
    var cloud: CloudSync?
    var registrySync: RegistrySync?
    /// Observable "last synced" state for the Connectivity menu. Always present (shows "local only" in
    /// the unentitled dev build); CloudSync writes `markSynced()` on each successful round-trip.
    public let syncMonitor = SyncMonitor(cloudEnabled: CloudSync.isEntitled)

    enum PointerKind {
        case navigate, move, resizeTop, resizeBottom, create // timed
        case bandMove, bandResizeL, bandResizeR, bandCreate // all-day bands
        case promotedMove // promoted ghost band → lane-only drag
        case ddlMove // deadlines
        case marquee, negMarquee // shift-drag select / ⌘⇧-drag deselect
    }

    struct Drag {
        var kind: PointerKind
        var startPoint: CGPoint
        var eventId: String?
        var orig: TimedEvent?
        var anchorHour: CGFloat?
        var createYear: Int?
        var createMonth: Int?
        var createDay: Int?
        var origBand: BandEvent?
        var bandMonth: Int?
        var bandTrack: Int?
        var bandAnchorDay: Int?
        var origDdl: Deadline?
        var priorSelection: String? // selection at down → deselect-vs-navigate on a plain click
        var titleHit = false // down landed on the title text → a click there inline-edits it
        var marqueeBase: Set<String>? // selection before a marquee started (union/subtract each frame)
        var marqueeHitId: String? // box under a shift-DOWN → toggled if it turns out to be a click
        var activated = false
    }

    /// The live marquee rect (geometry space) + whether it's a NEGATIVE (deselect) drag — drives the
    /// dashed selection box overlay. nil when no marquee is in progress.
    public internal(set) var marqueeRect: CGRect?
    public internal(set) var marqueeNegative = false

    /// Read-only CLOUD mode (the iPhone viewer): sync fetches and applies remote changes but never
    /// pushes — no initial full push, no onLocalChange wiring, and the send path is hard-blocked in
    /// CloudSync/RegistrySync. Local engine mutations still work (they just stay on-device).
    public let cloudReadOnly: Bool

    public init(cloudReadOnly: Bool = false) {
        self.cloudReadOnly = cloudReadOnly
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        year = c.year ?? 2026
        systemYear = c.year ?? 2026
        focus = (c.month ?? 1) - 1
        cursor.blockMonth = focus; cursor.blockDay = c.day ?? 1
        daily = DailyState(dom: c.day ?? 1, frac: 0.45)
        // No placeholder seed events (regular OR recording mode) — a fresh install starts with an empty
        // calendar; the recording scenes seed their own ambient data. Existing users load from the store below.
        // Point the store at the ACTIVE calendar (registry already migrated a legacy install into "Main")
        // and restore its persisted content into `items`.
        store = ItemStore(calendarId: registry.activeId)
        restoreItemsFromStore()
        mainTz = UserDefaults.standard.string(forKey: PrefKeys.mainTz) ?? "auto" // View ▸ Current Timezone
        altTz = UserDefaults.standard.string(forKey: PrefKeys.altTz) ?? "none" // View ▸ Alternative Timezone
        migrateAnchors() // stamp anchorTz on legacy items (needs mainTz resolved above)
        // The timeline scale-bar's chosen hour height survives restarts.
        if UserDefaults.standard.object(forKey: PrefKeys.weekHourH) != nil {
            weekHourH = clampHourH(CGFloat(UserDefaults.standard.double(forKey: PrefKeys.weekHourH)))
        }
        if Self.isDemoMode {
            // Deterministic recordings: pin "now" to 4 pm so the CURRENT TIME pill, the now-line, and every
            // time-anchored scroll (jumpToDay centers around now) look identical whenever a scene runs.
            now = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date()) ?? now
        } else {
            nowTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.now = Date(); self?.wake() } // refresh the now-line (a render must run)
            }
        }
        pushChrome()
        enableCloudSyncIfEntitled()
        scheduleDisplayDumpIfRequested() // dev: CC_DUMP_DISPLAY=<path> → write the expanded display set
        armSleep() // an untouched app settles to a paused (idle) render after the initial frame
        // First LIVE engine wins. SwiftUI view-struct reconstruction spawns throwaway engines
        // (@State default values, discarded immediately); letting them clobber this weak static
        // left menus/notifications pointing at a dead engine. Weak → when the real engine dies,
        // the slot self-clears and the next engine claims it.
        if Self.mainInstance == nil {
            Self.mainInstance = self
        }
        NotificationScheduler.shared.start(engine: self) // local-notification schedule (no-op in demo/tests)
    }

    /// Reset `items` and load the ACTIVE calendar's store into it: restore the persisted content (or seed
    /// an empty store on first open), backfill legacy deadline origin-tz, resume the create-counter past
    /// the calendar's ids, and repair any duplicate ids. Shared by init() and switchCalendar() — each
    /// calendar's ids are independent, so the counter is reset per calendar.
    func restoreItemsFromStore() {
        items = CalendarItems()
        createCounter = 0
        if let s = store.load() {
            items.events = s.events; items.bands = s.bands; items.deadlines = s.deadlines
            items.richById = s.rich ?? [:]
            items.dailyNotes = s.dailyNotes ?? [:]
            // Backfill deadline origin tz from the rich side-map for stores written before Deadline carried
            // its own originTz (migrated data keeps it in rich); the field is canonical once set.
            for i in items.deadlines.indices where items.deadlines[i].originTz == nil {
                if let tz = items.richById[items.deadlines[i].id]?.originTz {
                    items.deadlines[i].originTz = tz
                }
            }
            if let names = s.monthTrackNames, names.count == 12, names.allSatisfy({ $0.count == 4 }) {
                items.trackNames = names
            }
        } else {
            persistNow() // seed the store on first open of this calendar
        }
        // Resume the create-counter past any persisted new-/newb- ids so fresh items don't collide with
        // reloaded ones (which produced duplicate SwiftUI ForEach ids).
        for id in items.events.map(\.id) + items.bands.map(\.id) {
            for pre in ["newb-", "new-"] where id.hasPrefix(pre) {
                if let n = Int(id.dropFirst(pre.count)) {
                    createCounter = max(createCounter, n)
                }
            }
        }
        // Repair any duplicate ids already on disk (from the earlier collision bug).
        var seenIds = Set<String>()
        for i in items.bands.indices where !seenIds.insert(items.bands[i].id).inserted {
            createCounter += 1; items.bands[i].id = "newb-\(createCounter)"
        }
        for i in items.events.indices where !seenIds.insert(items.events[i].id).inserted {
            createCounter += 1; items.events[i].id = "new-\(createCounter)"
        }
    }

    /// The most recently created engine — the AppKit menu bar (which has no engine reference) reads this to
    /// populate dynamic menus (View ▸ Filter by Tags needs the live tag universe). Weak: previews/tests may
    /// create short-lived engines; the app's real engine outlives the menus that query it.
    public private(set) weak static var mainInstance: CalendarEngine?

    /// ── Track names (editable lane labels, per month) ─────────────────────────────
    public func setTrackName(_ month: Int, _ track: Int, _ name: String) {
        guard month >= 0, month < items.trackNames.count, track >= 0, track < items.trackNames[month].count,
              items.trackNames[month][track] != name else { return }
        beginTxn()
        items.trackNames[month][track] = name
        scheduleCommit()
        schedulePersist()
    }

    /// Which track-name gutter slot is under the cursor (any zoom that shows a band gutter):
    /// its month, track index, and geometry-space rect — used to place the inline editor.
    public func trackNameHit(at p: CGPoint) -> (month: Int, track: Int, rect: CGRect)? {
        guard p.x >= Layout.mnameW, p.x <= Layout.labelW - Layout.rightPad else { return nil }
        let g = snapshot()
        for m in 0 ..< 12 {
            let f = frameFor(m, g)
            if f.opacity < 0.05 {
                continue
            }
            for i in 0 ..< 4 {
                let y = f.bandY + CGFloat(i) * f.trackH
                if p.y >= y, p.y < y + f.trackH {
                    return (
                        m,
                        i,
                        CGRect(
                            x: Layout.mnameW,
                            y: y,
                            width: Layout.labelW - Layout.mnameW - Layout.rightPad,
                            height: f.trackH
                        )
                    )
                }
            }
        }
        return nil
    }

    func schedulePersist() { // internal: +Extensions files persist too
        wake() // universal edit chokepoint (covers non-txn setters: notes, rich fields, daily notes)
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistNow() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// In keyboard block-cursor mode, the cursor drives the SAME soft highlight the mouse produces
    /// (year → whole month; month → the day column) — so `hover` is derived from the block position
    /// instead of the mouse. nil → fall back to the real mouse `hover`.
    private func blockHoverOverride() -> Hover? {
        guard cursor.keyboardActive, selectedId == nil, !drawerOpen else { return nil }
        if let t = cursor.trackNameCursor {
            return Hover(track: t)
        } // track-name cursor: highlight its lane
        if cursor.bandCursorActive { // band cursor: the month/week crosshair (lane + day)
            switch level(z) {
            case 0: return Hover(month: cursor.blockMonth, dom: cursor.blockDay, track: cursor.bandCurTrack)
            case 1, 2: return Hover(dom: cursor.blockDay, track: cursor.bandCurTrack)
            default: return nil // day view: ring only
            }
        }
        switch level(z) {
        case 0: return Hover(month: cursor.blockMonth)
        case 1: return Hover(dom: cursor.blockDay)
        case 2, 3: // day column (soft) + hour cell (strong), matching a mouse hover
            return Hover(dom: level(z) == 2 ? cursor.blockDay : daily.dom, hour: Int(cursor.blockHour.rounded()))
        default: return nil
        }
    }

    /// ── Frame snapshot ──────────────────────────────────────────────────────────
    func snapshot() -> SceneInput {
        // Gutter hide: the scene lays out `gutterShift` wider than the real window (the view slides
        // the whole stack left by the same amount) — inflate ONLY the SceneInput's viewport; the
        // stored `viewport` stays window-real (setViewport's same-size guard depends on it).
        let sceneVp = gutterShift > 0.01 ? Viewport(w: viewport.w + gutterShift, h: viewport.h) : viewport
        var g = SceneInput(z: z, focus: focus, week: week, vp: sceneVp, scrollY: scrollY, tlScroll: tlScroll,
                           now: now, year: year, hover: blockHoverOverride() ?? hover, weekHourH: weekHourH,
                           daily: daily,
                           monthAnim: anim.monthAnim, altDeltaHours: altDeltaHours, altLabel: altColumnLabel,
                           yearPull: scroll.yearPull, flipFade: anim.flipFade,
                           animating: anim.tween != nil || anim.scrollTween != nil || anim.tlScrollTween != nil || anim
                               .weekTween != nil || anim.dayTween != nil || anim.flipAnim != nil || anim
                               .monthAnim != nil || anim
                               .weekFlip != nil || anim.dayFlip != nil,
                           monthPull: scroll.monthPull, monthFlipShift: anim.monthFlipShift, weekPull: scroll.weekPull,
                           weekFlipDir: anim.weekFlip?.dir ?? 0, weekFlipFade: anim.weekFlipFade,
                           dayPull: scroll.dayPull,
                           mainTz: mainTz,
                           yearQX: yearQX,
                           monthQX: monthQX)
        g.dashPin = dashPin
        // Gutter hide: the pinned panel must stay PX-STABLE while the scene width inflates —
        // otherwise crossing the hide threshold with the split handle makes the panel lunge
        // (frac × inflated) past the cursor and the drag oscillates. Scale the fractions so
        // fracEff × (inflatedW − labelW) == frac × (realW − labelW): all reclaimed width goes
        // to the CALENDAR, the panel and the handle's absolute position never move.
        let fracScale: CGFloat = gutterShift > 0.01
            ? (viewport.w - Layout.labelW) / max(1, viewport.w + gutterShift - Layout.labelW)
            : 1
        g.dashWeekFrac = dashWeekFrac * fracScale
        g.dashMonthFrac = dashMonthFrac * fracScale
        g.weekDash = weekDashHold.map { SceneInput.WeekDashOverride(from: $0.from, to: $0.to, p: $0.q) }
        return g
    }

    /// Per-quarter horizontal scroll offsets for the year view (phone overflow; zeros on
    /// desktop). Mirrors the phone's per-quarter ScrollView drivers, like scrollY mirrors
    /// the vertical one.
    public internal(set) var yearQX: [CGFloat] = [0, 0, 0, 0]

    /// Month-view horizontal scroll offset (phone overflow; 0 on desktop). Seeded from the
    /// tapped month's quarter offset on drill-in and written back on zoom-out, so the
    /// visible day columns carry across the year↔month transition (see navigate/zoomToYear).
    public internal(set) var monthQX: CGFloat = 0

    /// Mirror a quarter's horizontal driver offset. Unclamped, like setYearScroll/setTlScroll:
    /// the elastic overscroll is exactly what renders the native bounce.
    public func setYearQuarterScroll(_ quarter: Int, _ x: CGFloat) {
        guard yearQX.indices.contains(quarter) else { return }
        wake()
        yearQX[quarter] = x
    }

    /// Mirror the month-view horizontal driver offset (same unclamped contract).
    public func setMonthHScroll(_ x: CGFloat) {
        wake()
        monthQX = x
    }

    /// Read-only current scene input (does NOT advance tweens). For a second view that must render the
    /// same frame the main TimelineView already computed — e.g. the lifted-event copy above the scrim.
    public func snapshotInput() -> SceneInput {
        snapshot()
    }

    /// Advance the anim.tween to `date` and return the immutable input for this frame.
    public func sceneInput(at date: Date, viewport vp: Viewport) -> SceneInput {
        // ONE animation-clock sample per runloop cycle. Inside a single CA commit, SwiftUI can
        // re-evaluate the scene repeatedly (the commit's layout loop) with a FRESH timeline date
        // each pass; advancing tweens on every pass moves views again, re-dirties layout, and the
        // commit never converges until the animation ends — a 300ms commit presenting nothing
        // (the ⌘J pop). Freezing the clock within a cycle makes every intra-commit eval
        // identical, so layout converges, the frame presents, and the NEXT cycle advances by the
        // real elapsed time — the animation stays wall-clock true. This is exactly SwiftUI's own
        // per-transaction time sampling, applied to the engine's manual tweens.
        let date = RenderLoopClock.sample(date)
        viewport = vp
        if var t = anim.tween {
            if !t.ticked { // first rendered frame → start the clock NOW (see Tween.ticked)
                t.ticked = true; t.start = date; anim.tween = t
            }
            z = t.value(at: date)
            let done = t.isComplete(at: date)
            if done {
                z = t.to; anim.tween = nil
            }
            // hourH (and thus maxScroll) changes with z. Hold the anchor hour centred so the focus area
            // doesn't drift + snap as you zoom between week and month (a fixed-pixel scroll would map to a
            // moving hour). Also resyncs the driver. Release the anchor once the zoom settles.
            applyZoomAnchor(at: z)
            if done {
                anim.zoomAnchorHour = nil; anim.zoomAnchorY = nil
                if let cb = anim.zTweenDone {
                    anim.zTweenDone = nil; cb()
                } // sequenced next phase (e.g. go-to-today)
                switch level(z) { // a jump's fly-in settled at its target level
                case 3: fireDayLand()
                case 2: fireWeekLand()
                case 1: fireMonthLand()
                default: break
                }
            }
        }
        if var st = anim.scrollTween {
            if !st.ticked { // launch glides stall the same way — same rebase (see Tween.ticked)
                st.ticked = true; st.start = date; anim.scrollTween = st
            }
            scrollY = st.value(at: date); onSetYearScroll?(scrollY)
            if st.isComplete(at: date) {
                scrollY = st.to; anim.scrollTween = nil; onSetYearScroll?(scrollY)
                if let cb = anim.scrollTweenDone {
                    anim.scrollTweenDone = nil; cb()
                } // then zoom in
            }
        }
        if let tt = anim.tlScrollTween {
            tlScroll = tt.value(at: date); onSetTlScroll?(tlScroll)
            if tt.isComplete(at: date) {
                tlScroll = tt.to; anim.tlScrollTween = nil; onSetTlScroll?(tlScroll)
            }
        }
        if let pt = anim.dashPinTween {
            dashPin = pt.value(at: date)
            if pt.isComplete(at: date) {
                dashPin = pt.to; anim.dashPinTween = nil
                if dashPin <= 0 {
                    chrome.dashPresented = false // retract finished → frames may leave the pinned edge
                }
            }
        }
        if let wt = anim.weekTween {
            week = wt.value(at: date)
            if wt.isComplete(at: date) {
                week = wt.to; anim.weekTween = nil
                if let cb = anim.weekTweenDone {
                    anim.weekTweenDone = nil; cb()
                } // sequenced next phase (go-to-today)
            }
        }
        // Weekly-dashboard carousel: advance a settle tween; or, if a caught (frozen) hold is
        // left over and everything week-related has come to rest without a snap decision (e.g.
        // a zero-movement release), settle it to the band as a fallback.
        if let st = weekDashSettle {
            weekDashHold?.q = st.value(at: date)
            if st.isComplete(at: date) {
                weekDashSettle = nil
                weekDashHold = nil // the settled endpoint matches the band's rest → follow it
            }
        } else if weekDashHold != nil, weekDashCruise == nil, !scroll.liveWeekScrolling,
                  anim.weekTween == nil, date.timeIntervalSince(weekDashIdleAt) > 0.3 {
            settleWeekDash(restWeek: (week * 7).rounded() / 7)
        }
        if let mg = anim.monthGlide {
            // Fractional-month glide (jumpToMonth): the tween is a continuous month position; floor →
            // the anchor month, the fraction → a page-turn — the same decomposition setMonthProgress
            // projects from the pager scroll, so the glide looks like fast pagination. The pager's
            // scroll view sits untouched during the glide (setMonthProgress is gated off); landing
            // re-syncs it to the new focus via monthResync.
            if mg.isComplete(at: date) {
                focus = max(0, min(11, Int(mg.to.rounded())))
                anim.monthAnim = nil; anim.monthGlide = nil
                pushChrome(); chrome.monthResync &+= 1
                fireMonthLand()
            } else {
                let f = mg.value(at: date)
                let m = max(0, min(11, Int(f.rounded(.down))))
                let frac = f - CGFloat(m)
                focus = m
                anim.monthAnim = frac > 0.001 ? PageAnim(dir: 1, p: min(0.999, frac)) : nil
                pushChrome()
            }
        }
        if let dt = anim.dayTween {
            // Fractional-day glide: floor → the anchor day, the fraction → a ±1 day-page so the day column
            // pans + cross-fades toward today (same visual as a manual day scroll), engine-side only.
            let dim = daysInMonth(year, focus)
            if dt.isComplete(at: date) {
                daily.dom = max(1, min(dim, Int(dt.to.rounded()))); daily.anim = nil; anim.dayTween = nil
                week = weekFor(dom: daily.dom)
                pushChrome(); chrome.dailyResync &+= 1
                fireDayLand() // a same-month jumpToDay glide landed
            } else {
                let f = dt.value(at: date)
                let dom = max(1, min(dim, Int(f.rounded(.down))))
                let frac = f - CGFloat(dom)
                daily.dom = dom
                daily.anim = frac > 0.001 ? PageAnim(dir: 1, p: min(0.999, frac)) : nil
                week = weekFor(dom: dom)
                pushChrome()
            }
        }
        if let st = anim.shiftTween {
            drawerShift = st.value(at: date)
            if st.isComplete(at: date) {
                drawerShift = st.to; anim.shiftTween = nil
            }
        }
        // ── Gutter hide/show: retarget + advance the BINARY decision tween, then recompose the
        // presented shift with the continuous z-fade (rides the zoom: full through month↔week,
        // zero at day and year — in step with the pinch, never snapping at a level boundary).
        let gTarget = gutterHideTarget
        if abs((anim.gutterTween?.to ?? gutterHide) - gTarget) > 0.001 {
            anim.gutterTween = Tween(from: gutterHide, to: gTarget, start: date,
                                     duration: Motion.drawerShiftDur, ease: easeOut)
        }
        if let gt = anim.gutterTween {
            gutterHide = gt.value(at: date)
            if gt.isComplete(at: date) {
                gutterHide = gt.to; anim.gutterTween = nil
            }
        }
        let gZFade = easeInOut(clamp(z, 0, 1)) * (1 - easeInOut(clamp(z - 2, 0, 1)))
        gutterShift = gutterHide * gZFade * (Layout.labelW + Layout.padLeft)
        if let fa = anim.flipAnim {
            advanceFlip(fa, at: date)
        }
        if let mf = anim.monthFlip {
            advanceMonthFlip(mf, at: date)
        }
        if let wf = anim.weekFlip {
            advanceWeekFlip(wf, at: date)
        }
        if let df = anim.dayFlip {
            advanceDayFlip(df, at: date)
        }
        return snapshot()
    }

    public func setViewport(_ size: CGSize) {
        let vp = Viewport(w: size.width - Layout.padLeft - Layout.padRight, h: size.height)
        // No-op guard: AppKit calls CatcherView.layout() (→ setViewport) on EVERY display cycle while the
        // calendar renders, and `sceneInput` already keeps `viewport` current each frame. Waking on a
        // same-size call created a layout→wake→render→layout feedback loop that pinned the CPU and
        // defeated the idle pause. Only act on a real resize (or the first layout).
        if scroll.didInitialScroll, vp.w == viewport.w, vp.h == viewport.h {
            return
        }
        wake() // genuine resize / initial layout → re-render the scene
        viewport = vp
        if !scroll.didInitialScroll, viewport.h > 1 {
            scroll.didInitialScroll = true // once: center today's month (clamped to top/bottom).
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            // Default the day-view timeline ~180px narrower (a roomier dashboard) — computed here,
            // once, now that the content width is known; the user can still drag the split. A
            // client with NO dashboard (iPhone) instead pins the split to 1: full-width day column.
            daily.frac = hasDailyDashboard
                ? clamp(
                    daily.frac - 180 / max(1, viewport.w - Layout.labelW),
                    Layout.dayFracDefaultMin,
                    Layout.dayFracMax
                )
                : 1
            // The driver is synced by CatcherView.layout after it sizes the document view.
        } else {
            scrollY = clamp(scrollY, 0, yearMaxScroll(viewport))
        }
    }

    /// ── Hour-timeline vertical scroll: mirror of an invisible NSScrollView (native elastic bounce) ──
    /// Same trick as the year scroll: AppKit computes the elastic overscroll + momentum on a hidden
    /// scroll view whose scrollable range == the timeline's maxScroll, and we mirror its offset here.
    /// `onSetTlScroll` moves the driver programmatically (sync on gesture start / after a zoom).
    public var onSetTlScroll: ((CGFloat) -> Void)?
    /// `onSetWeekScroll` moves the (invisible) week pager to a given content-offset x — used to PIN it
    /// to the flip animation each frame so its own decelerate/snap animation can't diverge and twitch.
    public var onSetWeekScroll: ((CGFloat) -> Void)?
    /// `onSetMonthPage` parks the (invisible) month pager on a month page — the boundary flip pins it
    /// EVERY FRAME (a one-shot resync loses to a live paging settle; see advanceMonthFlip).
    public var onSetMonthPage: ((Int) -> Void)?

    public func deleteSelected() {
        guard let id = selectedId else { return }
        beginTxn()
        items.events.removeAll { $0.id == id }
        items.bands.removeAll { $0.id == id }
        items.deadlines.removeAll { $0.id == id }
        selectedId = nil
        commitTxn()
    }

    /// ── Undo / redo ───────────────────────────────────────────────────────────────
    /// internal (not private): the CalendarEngine+*.swift extension files open/commit txns too.
    func beginTxn() {
        wake(); caches.editGen &+= 1; if pendingUndo == nil {
            pendingUndo = editState
        }
    }

    func commitTxn() { // internal: +Extensions files commit txns too
        undoWork?.cancel(); undoWork = nil
        guard let snap = pendingUndo else { return }
        pendingUndo = nil
        guard snap != editState else { return } // no-op edit → no entry
        caches.deadlineGen &+= 1 // an edit committed → re-solve deadline label sides
        undoStack.append(snap)
        if undoStack.count > 100 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        schedulePersist()
    }

    func scheduleCommit() { // coalesce a typing burst
        undoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitTxn() }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func restore(_ s: EditState) {
        wake()
        caches.editGen &+= 1
        items.events = s.events; items.bands = s.bands; items.deadlines = s.deadlines
        items.richById = s.rich; items.trackNames = s.trackNames; items.dailyNotes = s.dailyNotes
        selectedId = nil; schedulePersist()
    }

    public var canUndo: Bool {
        !undoStack.isEmpty || pendingUndo != nil
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    public func undo() {
        commitTxn()
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(editState)
        restore(snap)
    }

    public func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(editState)
        restore(snap)
    }

    /// ── Drawer support ──────────────────────────────────────────────────────────
    /// Any item (band / timed / deadline) under the point — for double-click to open.
    public func itemId(at p: CGPoint) -> String? {
        let g = snapshot()
        if let h = bandAt(p, g) {
            return h.id
        }
        if z >= 1.5, let h = eventAt(p, g) {
            return h.id
        }
        if z >= ViewConst.detailZ, let id = deadlineAt(p, g) {
            return id
        }
        return nil
    }

    /// Programmatic selection (right-click menu, demo scenes): select + repaint.
    public func select(_ id: String?) {
        selectedId = id; caches.editGen &+= 1; wake()
    }

    /// ── Drawer canvas-shift ───────────────────────────────────────────────────────
    /// Slide the calendar left so the drawer item centers in the free area beside the drawer.
    /// Formula ports dashboard.css: shift = clamp(0, evcenter − (X − D)/2, D), with X the
    /// window width, D the drawer width, evcenter the item's unshifted center (window coords).
    /// Begin (or re-solve) the shift for the item shown in the drawer. `drawerWidth` is the
    /// horizontal space the drawer occupies on the right.
    public func openDrawerShift(id: String, drawerWidth D: CGFloat) {
        wake()
        anim.shiftTween = Tween(from: drawerShift, to: drawerShiftTarget(id: id, drawerWidth: D),
                                start: Date(), duration: Motion.drawerShiftDur, ease: easeOut)
    }

    /// Slide the calendar back to rest when the drawer closes.
    public func closeDrawerShift() {
        wake()
        anim.shiftTween = Tween(from: drawerShift, to: 0, start: Date(), duration: Motion.drawerShiftDur, ease: easeOut)
    }

    /// Re-solve the shift immediately (no anim.tween) while the drawer is being resized, so the
    /// canvas tracks the drag frame-for-frame (like the web's `.cc-drawer-resizing`).
    public func updateDrawerShift(id: String, drawerWidth D: CGFloat) {
        wake()
        anim.shiftTween = nil
        drawerShift = drawerShiftTarget(id: id, drawerWidth: D)
    }

    private func drawerShiftTarget(id: String, drawerWidth D: CGFloat) -> CGFloat {
        guard z < 2.5 else { return 0 } // daily: dashboard owns the right
        // Center on the specific focused OCCURRENCE, not the series base. `selectedId` holds the
        // clicked box id (a recurrence occurrence carries a synthetic occKey), while `id` here is the
        // drawer's collapsed source id. Prefer the selected box when it belongs to this same series.
        let boxId = (selectedId.flatMap { sourceId(of: $0) == id ? $0 : nil }) ?? id
        // If we can't locate the box, DON'T shift — a bogus center (e.g. viewport middle) would
        // over-shift a left-edge item off-screen. With a real center the clamp keeps it on-screen.
        guard let X = itemCenterViewportX(boxId) else { return 0 }
        let W = viewport.w + Layout.padLeft + Layout.padRight // window width
        // Place the event at the centre of the free area left of the drawer, (W − D)/2: shift left by
        // X − (W − D)/2; never shift right (≥ 0); never more than a drawer width (≤ D).
        return min(max(0, X - (W - D) / 2), D)
    }

    /// The item's horizontal center in window coordinates (geometry x + padLeft), or nil if it
    /// has no on-screen rect right now. Looks up the DISPLAY arrays (recurrence + promoted ghosts),
    /// which is what hit-testing selects from — so a selected ghost id resolves instead of falling nil.
    private func itemCenterViewportX(_ id: String) -> CGFloat? {
        let g = snapshot()
        if let b = displayBands(for: year).first(where: { $0.id == id }), let r = bandEventRect(
            b,
            g,
            anim: g.monthAnim
        ) {
            return r.x + r.w / 2 + Layout.padLeft
        }
        if z >= 1.5, let e = displayEvents(for: year).first(where: { $0.id == id }) {
            let tl = timelineInfo(g)
            let sameDay = eventsOn(year, e.month, e.day)
            if let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) {
                return r.minX + r.width / 2 + Layout.padLeft
            }
        }
        if z >= 1.5, let d = displayDeadlines(for: year).first(where: { $0.id == id }), let pos = deadlinePos(d, g) {
            // Deadline spans both the moment line [x, x+colW] AND its side label pill — center on the
            // union of the two: (min of the two lefts + max of the two rights) / 2.
            let label = deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, g).rect
            let left = min(pos.x, label.minX), right = max(pos.x + pos.w, label.maxX)
            return (left + right) / 2 + Layout.padLeft
        }
        return nil
    }

    /// Open the inline title editor for the timed event `id` (a ghost's source), over its box. The
    /// keyboard "Enter → edit title" and the click-a-selected-event gesture both route here.
    public func editTimed(_ id: String, at p: CGPoint? = nil) {
        let g = snapshot()
        let tl = timelineInfo(g)
        guard z >= 1.5, tl.reveal > 0.05, tl.hourH > 0 else { return }
        let src = sourceId(of: id)
        // Position over the DISPLAY event's segment the user is on. A cross-midnight event draws across
        // several day columns; the editor should open on the segment you clicked (`p`), not always the
        // first. Segmenting the display copy (not the stored seed) keeps this right under tz conversion too.
        guard let disp = viewEvents().first(where: { $0.id == id }) else { return }
        func rectFor(_ sev: TimedEvent) -> CGRect? {
            guard let r = eventRect(
                sev,
                year,
                focus,
                tl,
                g.vp,
                layoutDay(eventsOn(sev.year, sev.month, sev.day))[sev.id]
            ) else { return nil }
            return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
        }
        let segs = timedSegments(disp)
        let rect = (p.flatMap { pt in segs.lazy.compactMap { rectFor($0.event) }.first { $0.contains(pt) } })
            ?? segs.first.flatMap { rectFor($0.event) }
        guard let rect else { return }
        onEditTimed?(src, rect)
    }

    /// The kind of the selected BOX — every display box (base, occurrence ghost, promoted band) is an
    /// independent item, so the kind comes from which display array the *exact* box id is in, NOT from
    /// its source. A promoted band therefore selects as a band even though its source is a timed event.
    /// Band takes precedence so a promoted-recurring box (whose id can appear as both a band and a timed
    /// ghost) reads as the band you see. Drives which keyboard state we're in.
    private enum SelKind { case none, timed, band, deadline }
    private var selectedKind: SelKind {
        guard let s = selectedId else { return .none }
        if viewBands().contains(where: { $0.id == s }) {
            return .band
        }
        if viewEvents().contains(where: { $0.id == s }) {
            return .timed
        }
        if viewDeadlines().contains(where: { $0.id == s }) {
            return .deadline
        }
        return .none
    }

    public var selectedIsTimed: Bool {
        selectedKind == .timed
    }

    public var selectedIsBand: Bool {
        selectedKind == .band
    }

    public var selectedIsDeadline: Bool {
        selectedKind == .deadline
    }

    var tabLink: (month: Int, day: Int, hour: CGFloat, eventId: String)? // internal: +KeyboardNav

    // ── View preferences ───────────────────────────────────────────────────────────────────────

    /// Set the week/day timeline's per-hour height (the scale-bar's zoom). Clamped + persisted.
    public func setWeekHourH(_ h: CGFloat) {
        wake()
        let clamped = clampHourH(h)
        guard clamped != weekHourH else { return }
        weekHourH = clamped
        UserDefaults.standard.set(Double(clamped), forKey: PrefKeys.weekHourH)
    }

    /// The "View ▸ Show Hidden Imported Events" toggle (UserDefaults-backed so the menu's checkmark and
    /// the renderer share one source of truth). When on, user-hidden imported events draw with a dotted bar.
    public var showHiddenImported: Bool {
        UserDefaults.standard.bool(forKey: PrefKeys.showHiddenImported)
    }

    /// A View-menu preference changed (posted via `.calendarViewPrefsChanged`) → invalidate the display
    /// cache and repaint. The pref value itself lives in UserDefaults; this just re-derives the scene.
    public func viewPrefsChanged() {
        mainTz = UserDefaults.standard.string(forKey: PrefKeys.mainTz) ?? "auto" // View ▸ Current Timezone
        altTz = UserDefaults.standard.string(forKey: PrefKeys.altTz) ?? "none" // View ▸ Alternative Timezone
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
    }

    /// Scroll the year view (if needed) so month `m`'s band is fully on screen. `animated` glides the
    /// scroll (a `anim.scrollTween`, like jumpToDay) rather than snapping — used when the cursor walks off
    /// the visible region.
    func ensureMonthVisible(_ m: Int, animated: Bool) {
        let cTop = yearFrame(m, viewport, 0).bandY - Layout.yearTop // scroll-independent content top
        let h = 4 * Layout.trackH
        let viewTop = Layout.yearTop, viewBottom = viewport.h - Layout.bottomPad
        // On-screen top = viewTop - scrollY + cTop. Keep [top, top+h] within [viewTop, viewBottom].
        let maxScrollForVisible = cTop // any more → top clips above
        let minScrollForVisible = cTop + h - (viewBottom - viewTop) // any less → bottom clips below
        // Base the clamp on where we're HEADED (an in-flight anim.tween's target) so rapid presses chain.
        var s = anim.scrollTween?.to ?? scrollY
        if s > maxScrollForVisible {
            s = maxScrollForVisible
        }
        if s < minScrollForVisible {
            s = minScrollForVisible
        }
        s = clamp(s, 0, yearMaxScroll(viewport))
        if abs(s - scrollY) < 0.5 {
            return
        } // already visible enough
        if animated {
            // Pace-locked like the day/week glides: duration scales with the scroll distance (~0.3s per
            // month band) so holding ↑/↓ scrolls at a CONSTANT speed instead of a fixed duration crawling
            // over a growing gap. ease OUT (not in-out) so each auto-repeat re-press kicks forward at full
            // speed rather than restarting in the slow ease-IN ramp. `scrollY` is already the live value.
            let dur = max(Motion.keyScrollMin, Motion.keyScrollPace * Double(abs(s - scrollY) / Layout.monthH))
            anim.scrollTween = Tween(from: scrollY, to: s, start: Date(), duration: dur, ease: easeOut)
        } else {
            anim.scrollTween = nil; scrollY = s; onSetYearScroll?(scrollY)
        }
    }
}

public extension Notification.Name {
    /// CC_TRACE: render-clock transitions (object: Bool awake).
    static let ccTraceClock = Notification.Name("cc.trace.clock")
}
