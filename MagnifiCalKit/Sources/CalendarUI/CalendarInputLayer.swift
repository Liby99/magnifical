// The AppKit input layer: CatcherView (the transparent NSView that owns every scroll/pinch/
// click/hover/key event and forwards it to the engine), its InputCatcher representable, and
// the invisible NSScrollView drivers that give scrolling native elastic feel.
// Split from CalendarView.swift (file diet).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// Transparent overlay that captures trackpad/mouse events and forwards them to the
/// engine. isFlipped so its coordinates match the SwiftUI/Canvas top-left origin.
struct InputCatcher: NSViewRepresentable {
    let engine: CalendarEngine
    let monthBridge: MonthPagerBridge
    let weekBridge: WeekPagerBridge
    let dayBridge: DayPagerBridge
    var forwarder: CatcherHandle?
    var onOpenEvent: (String) -> Void = { _ in }
    var onEventMenu: (String, CGRect) -> Void = { _, _ in } // right-click event → context callout
    var onSpaceMenu: (CalendarEngine.EmptySpot, CGRect) -> Void = { _, _ in
    } // right-click empty space → create/paste callout
    var onEditTrack: (TrackEdit) -> Void = { _ in }
    var onKey: (KeyToken) -> Bool = { _ in false } // dispatch a key; returns whether it was consumed
    var onKeyGuide: (Bool) -> Void = { _ in } // Cmd+K held → show/hide the shortcut guide
    var isEditingText: () -> Bool = { false } // a drawer inline editor owns the keyboard (pass keys to it)
    var onSearch: () -> Void = {} // Cmd+F → open the toolbar search field
    var isModalDelete: () -> Bool = { false } // the delete-confirm dialog is up
    var onDeleteDialogKey: (DeleteDialogKey) -> Void = { _ in }
    var onRequestDelete: () -> Void = {} // Delete on a selected event → raise the dialog
    var isTutorialUp: () -> Bool = { false } // the tutorial carousel is up
    var onTutorialKey: (DeleteDialogKey) -> Void = { _ in }
    var isBatchRenaming: () -> Bool = { false } // the batch-rename panel is up (modal-with-typing)
    var onBatchRenameCancel: () -> Void = {} // Esc anywhere → revert the live renames + close
    var onBatchRenameCommit: () -> Void = {} // Enter (field unfocused) → keep the renames + close

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.engine = engine
        v.monthBridge = monthBridge
        v.weekBridge = weekBridge
        v.dayBridge = dayBridge
        v.onOpenEvent = onOpenEvent
        v.onEventMenu = onEventMenu
        v.onSpaceMenu = onSpaceMenu
        v.onEditTrack = onEditTrack
        v.onKey = onKey
        v.onKeyGuide = onKeyGuide
        v.isEditingText = isEditingText
        v.onSearch = onSearch
        v.isModalDelete = isModalDelete
        v.onDeleteDialogKey = onDeleteDialogKey
        v.onRequestDelete = onRequestDelete
        v.isTutorialUp = isTutorialUp
        v.onTutorialKey = onTutorialKey
        v.isBatchRenaming = isBatchRenaming
        v.onBatchRenameCancel = onBatchRenameCancel
        v.onBatchRenameCommit = onBatchRenameCommit
        forwarder?.catcher = v // publish the catcher for menu/toolbar clipboard routing
        v.installYearScrollDriver()
        v.installTimelineScrollDriver()
        v.installKeyMonitor()
        v.installPanelScrollMonitor()
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.engine = engine; v.monthBridge = monthBridge; v.weekBridge = weekBridge; v.dayBridge = dayBridge
        v.onOpenEvent = onOpenEvent; v.onEventMenu = onEventMenu; v.onSpaceMenu = onSpaceMenu; v
            .onEditTrack = onEditTrack
        v.onKey = onKey; v.onKeyGuide = onKeyGuide; v.isEditingText = isEditingText; v.onSearch = onSearch
        v.isModalDelete = isModalDelete; v.onDeleteDialogKey = onDeleteDialogKey; v.onRequestDelete = onRequestDelete
        v.isTutorialUp = isTutorialUp; v.onTutorialKey = onTutorialKey
        v.isBatchRenaming = isBatchRenaming; v.onBatchRenameCancel = onBatchRenameCancel
        v.onBatchRenameCommit = onBatchRenameCommit
        forwarder?.catcher = v
    }
}

/// Flipped so its scroll origin (0 = top, increasing downward) matches our scrollY.
final class FlippedDocView: NSView { override var isFlipped: Bool {
    true
} }

/// A scroll physics driver. Overriding scrollWheel (a) disables concurrent "responsive
/// scrolling" — which otherwise grabs the gesture and swallows the .ended phase — so we
/// reliably see begin/end, and (b) is the same pattern the macOS pull-to-refresh libraries
/// use. super does the native elastic drag; begin/end are surfaced as closures so the same
/// class drives both the year scroll and the month↕month paging. `suppressSuperOnEnd` lets
/// the month driver run its own release-snap instead of AppKit's deceleration/bounce.
final class DriverScrollView: NSScrollView {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?
    var suppressSuperOnEnd = false
    override func scrollWheel(with e: NSEvent) {
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
        if e.phase.contains(.began) {
            onBegan?()
        }
        if ended && suppressSuperOnEnd {
            onEnded?(); return
        }
        super.scrollWheel(with: e)
        if ended {
            onEnded?()
        }
    }
}

/// The four keys the delete-confirm dialog reacts to (routed from the key monitor while the dialog is up).
enum DeleteDialogKey { case left, right, confirm, cancel }

final class CatcherView: NSView, NSMenuItemValidation {
    weak var engine: CalendarEngine?
    var onOpenEvent: ((String) -> Void)?
    var onEventMenu: ((String, CGRect) -> Void)? // right-click on an event → context callout (id, view-space box rect)
    var onSpaceMenu: ((CalendarEngine.EmptySpot, CGRect) -> Void)? // right-click on empty space → create/paste callout
    var onEditTrack: ((TrackEdit) -> Void)?
    var onKey: ((KeyToken) -> Bool)?
    var onKeyGuide: ((Bool) -> Void)?
    var isEditingText: (() -> Bool)? // drawer inline editor owns the keyboard → pass keys through
    var onSearch: (() -> Void)? // Cmd+F → open the toolbar search field
    var isModalDelete: (() -> Bool)? // the delete-confirm dialog is up → it owns ALL input
    var onDeleteDialogKey: ((DeleteDialogKey) -> Void)? // route ←/→/Enter/Esc to the dialog while it's up
    var onRequestDelete: (() -> Void)? // Delete on a selected event → raise the confirm dialog (no immediate delete)
    var isTutorialUp: (() -> Bool)? // the tutorial carousel is up → also a blocking modal
    var onTutorialKey: ((DeleteDialogKey) -> Void)? // route ←/→/Enter/Esc to the carousel
    var isBatchRenaming: (() -> Bool)? // the batch-rename panel is up (modal, but typing flows to its field)
    var onBatchRenameCancel: (() -> Void)? // Esc anywhere while renaming → revert + close
    var onBatchRenameCommit: (() -> Void)? // Enter with the field unfocused → keep + close
    /// A blocking modal is up → the canvas ignores every mouse/scroll/pinch event (the modal's backdrop
    /// captures them) and the key monitor swallows every non-modal key.
    private var modalActive: Bool {
        isModalDelete?() == true || isTutorialUp?() == true || isBatchRenaming?() == true
    }

    // Cmd+K guide currently displayed (so we hide once on release).
    var keyGuideShown = false // internal: read by CatcherView+Keyboard.swift
    private var trackingAreaRef: NSTrackingArea?
    // Invisible NSScrollView used purely as a physics driver: AppKit computes the elastic
    // bounce + momentum, and we mirror its offset into the engine (year-view scroll).
    private let yearScroll = DriverScrollView()
    private let docView = FlippedDocView()
    private var syncing = false // true while WE move/resize the driver — ignore its notifications
    // A second physics driver for the hour-timeline vertical scroll (week/day view) — native
    // elastic bounce + momentum, its scrollable range == the timeline's maxScroll.
    private let tlDriver = DriverScrollView()
    private let tlDoc = FlippedDocView()
    private var syncingTL = false
    // Month↕month paging is an invisible SwiftUI ScrollView (native .paging); we forward its
    // scroll events into the ScrollView's backing NSScrollView, handed to us via the bridge.
    weak var monthBridge: MonthPagerBridge?
    weak var weekBridge: WeekPagerBridge?
    weak var dayBridge: DayPagerBridge?
    // A boundary flip is triggered on fingers-up, but a hard fling keeps sending momentum
    // events that outlive the flip — which would then scroll the freshly-flipped month on to
    // the next/next-next. Swallow that trailing momentum until the momentum phase ends.
    private var swallowMonthMomentum = false
    private var swallowWeekMomentum = false // same, for the week-view month-edge flip
    private var swallowDayMomentum = false // same, for the day-view month-edge flip
    // A month boundary flip withholds `.ended` from the pager, so its NSScrollView is left with a stale
    // (pre-flip) offset that a later scrollTo can't override while the gesture stays "open". On the FIRST
    // gesture after a flip, snap the SV back to the new focus before forwarding — else it lunges back
    // toward the old month (Jan → burst toward November).
    private var monthFlipPendingResync = false
    // Week view has TWO scroll axes (horizontal = week window, vertical = hour timeline). Lock to
    // the dominant axis at gesture start so a diagonal drag doesn't do both at once.
    private enum ScrollAxis { case undecided, horizontal, vertical }
    private var weekAxis: ScrollAxis = .undecided
    private var dayAxis: ScrollAxis = .undecided
    // A day-pager gesture is "live" from the first fingers-down delta until `.ended`. Tracked
    // explicitly because a webview-forwarded scroll may skip `.began` (the web view holds it while its
    // axis is undecided), so we can't rely on `.began` alone to mark the gesture live.
    private var dayGestureActive = false
    private var tlPrepared = false // timeline driver sized+synced for the current gesture
    // While a scroll is in flight we suppress mouse-hover recomputation: a moving mouse during a
    // scroll otherwise fires onHover (hit-test + re-render) on every frame on top of the scroll's
    // own work. A short idle timer (reset by each scroll event) spans fingers-down + momentum.
    private var scrolling = false
    private var scrollIdle: DispatchWorkItem?
    private func noteScroll() {
        // Clear the stale highlight, but NOT the pointer/scale-bar proximity — the cursor hasn't
        // moved; a full onHoverExit here made the scale bar vanish the moment you scrolled.
        if !scrolling {
            scrolling = true; engine?.clearHoverHighlight()
        }
        scrollIdle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scrolling = false }
        scrollIdle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    /// Return false so a click on an INACTIVE window only activates the app — it isn't also
    /// delivered as a mouseDown (which would zoom into a month / select an event). Once the
    /// window is key, subsequent clicks act normally.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always be the event target; the scroll-view driver is a physics-only subview
        // that we feed manually (never a hit target for mouse/clicks).
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        // …except over the window toolbar (which floats above the content): fall through so the
        // click drags the window / hits a toolbar button, instead of us starting a band-create.
        if let win = window {
            let wp = superview?.convert(point, to: nil) ?? point // window coords (y grows upward)
            if wp.y > win.contentLayoutRect.maxY {
                return nil
            }
        }
        return self
    }

    /// ── Year-view scroll driver (native elastic bounce via NSScrollView) ─────────────
    func installYearScrollDriver() {
        yearScroll.drawsBackground = false
        yearScroll.hasVerticalScroller = false
        yearScroll.hasHorizontalScroller = false
        yearScroll.verticalScrollElasticity = .allowed
        yearScroll.horizontalScrollElasticity = .none
        yearScroll.autohidesScrollers = true
        // Critical: without this, a toolbar window gives the scroll view a top content
        // inset (toolbar height) — which pushes the content down AND makes the scroll
        // range asymmetric (top hair-trigger, bottom unreachable). We manage insets.
        yearScroll.automaticallyAdjustsContentInsets = false
        yearScroll.contentInsets = NSEdgeInsetsZero
        docView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        yearScroll.documentView = docView
        yearScroll.contentView.postsBoundsChangedNotifications = true
        addSubview(yearScroll, positioned: .below, relativeTo: nil) // behind; never hit-tested

        yearScroll.onBegan = { [weak engine] in engine?.beginYearScrollGesture() }
        yearScroll.onEnded = { [weak engine] in engine?.endYearScrollGesture() }
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: yearScroll.contentView)
        engine?.onSetYearScroll = { [weak self] y in self?.setDriverOffset(y) }
    }

    private func setDriverOffset(_ y: CGFloat) {
        let prev = syncing; syncing = true
        let cv = yearScroll.contentView
        cv.scroll(to: NSPoint(x: 0, y: y))
        yearScroll.reflectScrolledClipView(cv)
        syncing = prev
    }

    @objc private func clipBoundsChanged() {
        guard let engine, engine.isYearLevel, !engine.isFlipping, !syncing else { return }
        engine.setYearScroll(yearScroll.contentView.bounds.origin.y)
    }

    /// ── Hour-timeline scroll driver (native elastic bounce, week/day view) ─────────────
    func installTimelineScrollDriver() {
        tlDriver.drawsBackground = false
        tlDriver.hasVerticalScroller = false
        tlDriver.hasHorizontalScroller = false
        tlDriver.verticalScrollElasticity = .allowed
        tlDriver.horizontalScrollElasticity = .none
        tlDriver.autohidesScrollers = true
        tlDriver.automaticallyAdjustsContentInsets = false
        tlDriver.contentInsets = NSEdgeInsetsZero
        tlDoc.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        tlDriver.documentView = tlDoc
        tlDriver.contentView.postsBoundsChangedNotifications = true
        addSubview(tlDriver, positioned: .below, relativeTo: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tlClipChanged),
                                               name: NSView.boundsDidChangeNotification, object: tlDriver.contentView)
        engine?.onSetTlScroll = { [weak self] y in self?.setTlDriverOffset(y) }
        engine?.onSetWeekScroll = { [weak self] x in self?.weekBridge?.scrollTo(x) }
        engine?.onSetMonthPage = { [weak self] m in self?.monthBridge?.scrollToFocus(m) }
    }

    /// Size the driver's scrollable range to the current timeline maxScroll and sync it to the
    /// engine's tlScroll — do this at each vertical gesture's start (maxScroll depends on zoom).
    private func prepareTimelineDriver() {
        guard let engine else { return }
        syncingTL = true
        tlDriver.frame = bounds
        tlDoc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + engine.timelineMaxScroll)
        syncingTL = false
        setTlDriverOffset(engine.tlScroll)
    }

    private func setTlDriverOffset(_ y: CGFloat) {
        let prev = syncingTL; syncingTL = true
        let cv = tlDriver.contentView
        cv.scroll(to: NSPoint(x: 0, y: y))
        tlDriver.reflectScrolledClipView(cv)
        syncingTL = prev
    }

    @objc private func tlClipChanged() {
        guard let engine, !syncingTL, engine.isWeekLevel || engine.isDayLevel else { return }
        engine.setTlScroll(tlDriver.contentView.bounds.origin.y)
    }

    deinit {
        NotificationCenter.default
            .removeObserver(self); if let m = keyMonitor {
            NSEvent.removeMonitor(m)
        }
        if let m = panelScrollMonitor {
            NSEvent.removeMonitor(m)
        }
        repeatTimer?.invalidate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Create ONCE. `.inVisibleRect` keeps the area synced to the view automatically, so there's no need to
        // remove+re-add on every layout pass — doing that during the continuous TimelineView redraw churned
        // spurious exit/enter events, and mouseExited resets the cursor to the arrow → the hover cursor
        // flickered (arrow ↔ I-beam) over a selected event. `.cursorUpdate` makes the cursor event-driven.
        if let t = trackingAreaRef, trackingAreas.contains(t) {
            return
        } // already attached → don't churn it
        let t = NSTrackingArea(rect: .zero,
                               options: [
                                   .activeInKeyWindow,
                                   .mouseMoved,
                                   .mouseEnteredAndExited,
                                   .cursorUpdate,
                                   .inVisibleRect,
                               ],
                               owner: self)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func layout() {
        super.layout()
        syncing = true // suppress the mirror while resizing the clip/document view
        engine?.setViewport(bounds.size) // idempotent: a no-op size is ignored inside (no wake / re-render)
        // Size the driver so its scrollable range == the engine's yearMaxScroll:
        // docHeight − clipHeight = maxScroll  ⇒  docHeight = clipHeight + maxScroll.
        yearScroll.frame = bounds
        let vp = Viewport(w: bounds.width, h: bounds.height)
        let maxY = yearMaxScroll(vp)
        docView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + maxY)
        syncing = false
        setDriverOffset(engine?.scrollY ?? 0) // apply AFTER the doc is sized (engine.scrollY = centered)
    }

    func point(_ e: NSEvent) -> CGPoint { // internal: read by CatcherView+ScrollWheel.swift
        // Undo the render's padLeft translation (and the drawer left-shift) so hits land in
        // geometry space.
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x - Layout.padLeft + (engine?.drawerShift ?? 0) + (engine?.gutterShift ?? 0), y: p.y)
    }

    override func scrollWheel(with e: NSEvent) {
        if modalActive {
            return
        } // blocking modal up → no canvas scrolling
        // Year view: hand the event to the NSScrollView driver so AppKit does the elastic
        // physics; its offset is mirrored back via clipBoundsChanged. Deeper levels use
        // the manual timeline/week/day handling.
        guard let engine else { return }
        // Drop leftover momentum from a fling that just flipped the month boundary (a new
        // finger-down gesture cancels the swallow and scrolls normally again).
        if swallowMonthMomentum {
            if e.phase.contains(.began) {
                swallowMonthMomentum = false
            } // a fresh gesture resumes scrolling
            else {
                if e.momentumPhase.contains(.ended) {
                    swallowMonthMomentum = false
                }
                return // eat this trailing momentum event
            }
        }
        if swallowWeekMomentum {
            if e.phase.contains(.began) {
                swallowWeekMomentum = false
            } else {
                if e.momentumPhase.contains(.ended) {
                    swallowWeekMomentum = false
                }
                return
            }
        }
        if swallowDayMomentum {
            if e.phase.contains(.began) {
                swallowDayMomentum = false
            } else {
                if e.momentumPhase.contains(.ended) {
                    swallowDayMomentum = false
                }
                return
            }
        }
        if engine.isFlipping || engine.isMonthFlipping || engine.isWeekFlipping
            || engine.isDayFlipping || engine.trackEditing || engine.bandEditing
            || engine.timedEditing {
            return
        } // don't fight flip / inline edit
        noteScroll() // suppress hover while this scroll (and its momentum) is live
        if CCTrace.on {
            if e.phase.contains(.began) {
                CCTrace.event("scrollBegan L\(engine.chrome.level)")
            }
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
                CCTrace.event("scrollEnded")
            }
            if e.momentumPhase.contains(.began) {
                CCTrace.event("momentumBegan")
            }
        }
        if e.phase
            .contains(.began) {
            tlPrepared = false
        } // new gesture → re-prep the timeline driver on first vertical event
        if engine.isYearLevel {
            yearScroll.scrollWheel(with: e) // DriverScrollView does the physics + begin/end
        } else if engine.isMonthLevel, let sv = monthBridge?.scrollView {
            // Recover from a prior boundary flip: the SV kept the old month's offset. Snap it to the new
            // focus on the first touch of the next gesture — BEFORE any event reaches the SV — so the
            // gesture starts from the right month instead of lunging back toward the old one.
            if monthFlipPendingResync, e.phase.contains(.began) || e.phase.contains(.mayBegin) {
                monthFlipPendingResync = false
                monthBridge?.scrollToFocus(engine.focus)
            }
            if e.phase.contains(.began) {
                engine.beginMonthGesture()
            }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // Always forward — INCLUDING `.ended` on a boundary flip. Withholding it (the old approach)
            // left the SV's gesture stuck OPEN at the overscrolled edge page, so the flip's scrollTo() to
            // the new focus was a no-op and `setMonthProgress` then walked focus from that stale offset —
            // the "gentle scroll bursts through to November" bug. Forwarding `.ended` lets the SV settle
            // (its target is clamped to [0,11], so it can't overshoot the year) and closes the gesture, so
            // the re-sync sticks. `setMonthProgress` is guarded during the flip; the tail is swallowed.
            sv.scrollWheel(with: e) // invisible SwiftUI ScrollView does native .paging
            if ended {
                engine.endMonthGesture()
                if engine
                    .isMonthFlipping {
                    swallowMonthMomentum = true; monthFlipPendingResync =
                        true
                } // eat the fling's tail + reset the SV next gesture
            }
        } else if engine.isWeekLevel, let sv = weekBridge?.scrollView {
            // The finger touching (.mayBegin) must reach the ScrollView so AppKit lets it CAPTURE an
            // in-flight snap animation (grab the decelerating scroll) instead of it running on and
            // then being yanked to a target — that's what made a mid-flight catch feel abrupt.
            if e.phase.contains(.mayBegin) {
                sv.scrollWheel(with: e); return
            }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // A boundary flip is about to commit → do NOT hand `.ended` to the SV. Otherwise its own
            // ScrollTargetBehavior kicks off a decelerate/snap whose target is computed in the OLD
            // month's content coords; the flip re-anchors focus (new cell count), so when that stale
            // animation later resumes it lands a week or two off. Skipping `.ended` means the snap
            // never starts; the flip drives (and pins) the pager instead, and momentum is swallowed.
            let willFlip = ended && engine.weekFlipArmed
            // Axis-lock: horizontal → the week pager; vertical → the hour-timeline scroll.
            if e.phase.contains(.began) {
                weekAxis = .undecided; engine.beginWeekGesture()
            }
            if weekAxis == .undecided {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                if dx > 1 || dy > 1 {
                    weekAxis = dx > dy ? .horizontal : .vertical
                }
            }
            if weekAxis == .vertical {
                if !tlPrepared {
                    prepareTimelineDriver(); tlPrepared = true
                } // size range + sync, once per gesture
                tlDriver.scrollWheel(with: e) // native elastic bounce → mirrored into tlScroll
                if ended && !willFlip {
                    sv.scrollWheel(with: e)
                } // still let the SV settle the horizontal position
            } else if !willFlip {
                sv.scrollWheel(with: e) // horizontal or still-ambiguous (a pure catch) → the SV
            }
            if ended {
                weekAxis = .undecided
                if engine.endWeekGesture() {
                    swallowWeekMomentum = true
                } // armed pull → flip; eat the fling tail
            }
        } else if engine.isDayLevel, let sv = dayBridge?.scrollView {
            // Day view: horizontal → the invisible day pager (native day-to-day paging); vertical →
            // the hour-timeline scroll. Same axis-lock + catch-capture as the week pager.
            if e.phase.contains(.mayBegin) {
                sv.scrollWheel(with: e); return
            }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // A boundary flip is about to commit → withhold `.ended` from the SV so its own snap
            // (computed in the old month's coords) can't fight the flip (same as the week pager).
            let willFlip = ended && engine.dayFlipArmed
            // Start the gesture on the FIRST fingers-down delta (phase not ended, no momentum), not on
            // `.began` — a forwarded scroll from the dashboard web view may never deliver `.began` here.
            // This keeps `scroll.liveDayScrolling` true for the whole finger-down phase (incl. pauses), so the
            // settle safety-net can't fire and snap while the user is still scrolling.
            let fingersDown = !ended && e.momentumPhase.isEmpty
            if fingersDown,
               !dayGestureActive {
                dayGestureActive = true; dayAxis = .undecided; engine.beginDayGesture()
            }
            if dayAxis == .undecided {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                if dx > 1 || dy > 1 {
                    dayAxis = dx > dy ? .horizontal : .vertical
                }
            }
            if dayAxis == .vertical {
                if !tlPrepared {
                    prepareTimelineDriver(); tlPrepared = true
                }
                tlDriver.scrollWheel(with: e) // native elastic bounce → mirrored into tlScroll
                if ended && !willFlip {
                    sv.scrollWheel(with: e)
                } // let the SV settle the horizontal position
            } else if !willFlip {
                sv.scrollWheel(with: e) // horizontal or still-ambiguous (a pure catch)
            }
            if ended {
                dayAxis = .undecided
                dayGestureActive = false
                let flipped = engine.endDayGesture()
                if flipped {
                    swallowDayMomentum = true
                } // armed pull → flip; eat the fling tail
            }
        } else {
            engine.onWheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY)
        }
    }

    override func magnify(with e: NSEvent) {
        if modalActive {
            return
        }
        let began = e.phase.contains(.began)
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
        if CCTrace.on {
            if began {
                CCTrace.event("pinchBegan L\(engine?.chrome.level ?? -1)")
            }
            if ended {
                CCTrace.event("pinchEnded")
            }
        }
        engine?.onMagnify(delta: e.magnification, at: point(e), began: began, ended: ended)
    }

    /// ── Right-click (or ctrl-click) on an event → the context callout ──
    override func rightMouseDown(with e: NSEvent) {
        if !openEventMenu(with: e), !openSpaceMenu(with: e) {
            super.rightMouseDown(with: e)
        }
    }

    /// Right-click on EMPTY space: a create/paste callout anchored at the pointer — a timeline
    /// slot offers New Event / New Deadline, a band lane offers New Event (band); paste follows.
    @discardableResult private func openSpaceMenu(with e: NSEvent) -> Bool {
        guard !modalActive, let engine, let onSpaceMenu else { return false }
        let p = point(e)
        guard !engine.inDayDashboard(p), engine.itemId(at: p) == nil,
              let spot = engine.emptySpot(at: p) else { return false }
        let view = convert(e.locationInWindow, from: nil)
        onSpaceMenu(spot, CGRect(x: view.x + 4, y: view.y - 1, width: 1, height: 2))
        return true
    }

    /// Hit-test the click, select the item, and hand its VIEW-space box rect to the SwiftUI layer
    /// (which presents the popover). Returns whether an event was actually under the pointer.
    @discardableResult private func openEventMenu(with e: NSEvent) -> Bool {
        guard !modalActive, let engine, let onEventMenu else { return false }
        let p = point(e)
        guard !engine.inDayDashboard(p), let id = engine.itemId(at: p) else { return false }
        engine.select(id)
        // Anchor: a sliver just off the CENTER of the box's right edge — clamped to the VISIBLE
        // content region (a 10-day band right-clicked in day view anchors at the timeline's edge,
        // not 9 days off-screen). Content right edge = dashboardLeftAnimated (vp.w outside day
        // view). Scene → view = +padLeft − drawerShift. Fall back to a pointer spot rect.
        let view = convert(e.locationInWindow, from: nil)
        let dx = Layout.padLeft - engine.drawerShift - engine.gutterShift
        let g = engine.snapshotInput()
        let anchor = engine.selectedBoxRect()
            .map { (r: CGRect) -> CGRect in
                let visMaxX = min(r.maxX, dashboardLeftAnimated(g))
                return CGRect(x: visMaxX + dx + 5, y: r.midY - 1, width: 1, height: 2)
            }
            ?? CGRect(x: view.x - 2, y: view.y - 2, width: 4, height: 4)
        onEventMenu(id, anchor)
        return true
    }

    override func mouseDown(with e: NSEvent) {
        if modalActive {
            return
        } // blocking modal up → canvas is inert
        if e.modifierFlags.contains(.control),
           openEventMenu(with: e) || openSpaceMenu(with: e) {
            return
        } // ctrl-click = right-click
        engine?.enterMouseMode() // mouse activity hides the keyboard cursor visual
        let p = point(e)
        // Day view: the daily-dashboard panel (and the band strip hidden behind it) owns its own clicks —
        // never start a calendar action (band-create, select, drill) under the panel.
        if engine?.inDayDashboard(p) == true {
            return
        }
        // Track-name edit: a click just commits/dismisses it (swallowed — no zoom).
        if engine?.trackEditing == true {
            window?.makeFirstResponder(self)
            return
        }
        // Band/timed-title edit: commit/dismiss it (blur), then let THIS click act normally —
        // selecting another event, or deselecting on blank (fall through below).
        if engine?.bandEditing == true || engine?.timedEditing == true {
            window?.makeFirstResponder(self)
        }
        // Year view: clicking a track-name gutter slot opens the inline editor.
        if e.clickCount == 1, let hit = engine?.trackNameHit(at: p) {
            onEditTrack?(TrackEdit(month: hit.month, track: hit.track, rect: hit.rect))
            return
        }
        window?.makeFirstResponder(self)
        let shift = e.modifierFlags.contains(.shift)
        let command = e.modifierFlags.contains(.command)
        if e.clickCount == 2, !shift { // double-click any item → open its drawer (Shift = a multi-select gesture)
            // Open the SOURCE event (a ghost/promoted box maps back to its real item); the clicked
            // box stays selected → it gets the focused thick border while the series stays active.
            if let id = engine?.itemId(at: p) {
                onOpenEvent?(sourceId(of: id))
            }
            return
        }
        engine?.onPointerDown(at: p, shift: shift, command: command)
    }

    override func mouseDragged(with e: NSEvent) {
        if modalActive {
            return
        }
        engine?.onPointerDrag(at: point(e)); setCursor(.closedHand)
    }

    override func mouseUp(with e: NSEvent) {
        if modalActive {
            return
        }
        engine?.onPointerUp(at: point(e))
    }

    /// The content extends under the (floating) window toolbar, and our tracking area reaches up
    /// there too — so ignore pointer events whose location is above the content area's top edge.
    private func overToolbar(_ e: NSEvent) -> Bool {
        guard let win = window else { return false }
        return e.locationInWindow.y > win.contentLayoutRect.maxY // window coords: y grows upward
    }

    override func mouseMoved(with e: NSEvent) {
        if modalActive {
            return
        }
        engine?.enterMouseMode() // mouse activity hides the keyboard cursor visual
        if overToolbar(e) {
            engine?.onHoverExit(); setCursor(.arrow); return
        } // don't hover through the toolbar
        if engine?.drawerOpen == true {
            return
        } // drawer open → SwiftUI owns the cursor (title I-beam, handle resize)
        if scrolling {
            return
        } // a scroll is in flight — skip hover recompute (perf)
        let p = point(e)
        // The dashboard web view owns its region AND its cursor (CSS drives pointer/hand over clickable
        // rows). Don't set a cursor here — our tracking area fires even under the overlaying web view, so
        // forcing .arrow would fight the web view's pointer cursor every move → visible flicker.
        if engine?.inDayDashboard(p) == true {
            engine?.onHoverExit(); return
        }

        // The NATIVE pinned panel (week/month) owns its own pointer: its rows set the hand via
        // .pointerStyle, which per-move applyCursor here would stomp. Settle to the arrow ONCE
        // on entry (so a grab hand can't linger in), then leave the cursor alone.
        if let engine,
           engine.chrome.level == 3 || (engine.dashPinned && (1 ... 2).contains(engine.chrome.level)),
           engine.inDayDashboard(p) {
            if appliedCursor != .arrow {
                setCursor(.arrow)
            }
            toolTip = nil
            return
        }
        engine?.onHover(at: p)
        toolTip = engine?.bandWarningTooltip(at: p) // "Fully overlapping events" over the warn sign
        applyCursor(engine?.cursorHint(at: p))
    }

    /// cursorUpdate RE-ASSERTS the last cursor mouseMoved computed — it never recomputes.
    /// Synthesized cursorUpdate events (tracking-area churn during the per-frame renders) can carry
    /// stale/bogus locations; recomputing the hint from those flipped grab→arrow over a hovered
    /// band on alternate events — a visible flicker. mouseMoved (continuous, real coordinates) is
    /// the single source of truth; this handler just keeps AppKit from stomping its choice.
    override func cursorUpdate(with e: NSEvent) {
        if modalActive || engine?.drawerOpen == true {
            NSCursor.arrow.set(); return
        }
        if overToolbar(e) {
            NSCursor.arrow.set(); return
        }
        // Region checks use the LIVE pointer, not the event location: synthesized cursorUpdate
        // events (tracking-area churn, and notably SCROLL-END) carry stale/bogus locations — a
        // pointer genuinely over the panel failed the check and got the arrow stomped over the
        // rows' pointing hand the moment a scroll settled.
        if let w = window {
            let live = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            let gp = CGPoint(x: live.x - Layout.padLeft + (engine?.drawerShift ?? 0)
                + (engine?.gutterShift ?? 0), y: live.y)
            if engine?.inDayDashboard(gp) == true {
                return
            } // the dashboard (web view or native panel) owns its own cursor
        }
        appliedCursor.set()
    }

    /// The last cursor WE chose (mouseMoved / drag / exit) — cursorUpdate re-asserts exactly this.
    private var appliedCursor: NSCursor = .arrow

    private func setCursor(_ c: NSCursor) {
        appliedCursor = c
        c.set()
    }

    private func applyCursor(_ hint: CalendarEngine.CursorHint?) {
        switch hint {
        case .grab: setCursor(.openHand)
        case .resizeLR: setCursor(.resizeLeftRight)
        case .resizeV: setCursor(.resizeUpDown) // timed-event top/bottom edge
        case .text: setCursor(.iBeam)
        default: setCursor(.arrow)
        }
    }

    override func mouseExited(with e: NSEvent) {
        engine?.onHoverExit(); setCursor(.arrow)
    }

    // Keyboard is handled by a LOCAL EVENT MONITOR (installed below), NOT keyDown on this view. That's
    // deliberate: when the drawer (a SwiftUI overlay) opens it can pull first-responder off the canvas,
    // which would make view-based keyDown silently stop firing. The monitor sees every key for our
    // window regardless of first responder, so the shortcuts keep working; it only steps aside (returns
    // the event) when a real text input is focused, so typing/native undo still go to the field.
    var keyMonitor: Any? // internal: read by CatcherView+Keyboard.swift

    enum PanelAxis { case undecided, horizontal, vertical } // internal: read by CatcherView+ScrollWheel.swift
    var panelScrollMonitor: Any? // internal: read by CatcherView+ScrollWheel.swift
    var panelAxis: PanelAxis = .vertical // internal: read by CatcherView+ScrollWheel.swift
    var panelGestureCaptured = false // internal: read by CatcherView+ScrollWheel.swift
    /// The catcher OWNS the in-flight gesture: it began over the calendar (hit-test = this
    /// view), so EVERY event of the gesture — the .ended and momentum tail included — is
    /// forwarded here even if the pointer drifts over the dashboard panel mid-gesture. macOS
    /// hit-tests each scroll event under the CURRENT pointer, so without this latch a drifting
    /// gesture's tail landed in the panel's scroller: the catcher never saw .ended,
    /// liveDayScrolling stayed true, the settle safety-net was blocked forever — the
    /// "day swipe stuck midway" bug (confirmed by [dash-diag]: OPEN without CLOSE +
    /// settleDay BLOCKED: live=true). The webview's PassThroughWebView enforced exactly this
    /// whole-gesture-single-target rule from the other side.
    var catcherOwnsGesture = false // internal: read by CatcherView+ScrollWheel.swift

    var heldOrder: [UInt16] =
        [] // keyCodes, ordered by press (last = most recent); internal: read by CatcherView+Keyboard.swift
    var heldToken: [UInt16: KeyToken] = [:] // internal: read by CatcherView+Keyboard.swift
    var repeatTimer: Timer? // internal: read by CatcherView+Keyboard.swift
    let repeatDelay: TimeInterval = 0.30 // internal: read by CatcherView+Keyboard.swift
    let repeatInterval: TimeInterval = 0.045 // internal: read by CatcherView+Keyboard.swift

    /// The canvas swallows raw keyDown (no beep) when it's first responder; the monitor above does the work.
    override func keyDown(with e: NSEvent) {}

    /// selectAll stays here (it overrides NSResponder.selectAll; overrides can't move to a
    /// separate-file extension) — the rest of the clipboard surface is in CatcherView+Clipboard.swift.
    @objc override func selectAll(_ sender: Any?) {
        engine?.selectAllInViewport()
    }
}
