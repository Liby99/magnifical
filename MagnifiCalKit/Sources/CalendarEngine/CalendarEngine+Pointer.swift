// CalendarEngine+Pointer — mouse/trackpad interaction: the pointer down/drag/up pipeline
// (dispatching to create/move/resize per item kind), click-to-navigate, hover highlights,
// and the cursor-hint (arrow/grab/plus) resolution.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// Day view: is `p` inside the daily-dashboard panel (the right region)? Pointer actions there
    /// belong to the dashboard web view, not the calendar canvas — otherwise a click/drag over the
    /// panel (or the band strip hidden behind it) would create bands / select events you can't see.
    /// Self-gating: `dashboardLeftAnimated` is `vp.w` outside day view, so this is false there.
    public func inDayDashboard(_ p: CGPoint) -> Bool {
        p.x >= dashboardLeftAnimated(snapshot())
    }

    /// ── Pointer: unified down / drag / up ────────────────────────────────────────
    /// A plain click (down+up, no movement) navigates (drills in). A drag creates,
    /// moves, or resizes an event depending on what's under the cursor at down.
    public func onPointerDown(at p: CGPoint, shift: Bool = false, command: Bool = false) {
        wake()
        commitTxn() // flush any pending (e.g. drawer typing) before a new gesture
        cancelTween()
        let g = snapshot()
        let prior = selectedId // decide deselect-vs-navigate on a plain click (see onPointerUp)
        // 0. Shift → a marquee (⌘⇧ = a negative/deselect marquee). If it turns out to be a CLICK (no drag),
        //    the box under the cursor is toggled instead (shift-click multi-select). Selection changes are
        //    driven on drag / up so a shift-drag from empty space doesn't create.
        if shift {
            drag = Drag(kind: command ? .negMarquee : .marquee, startPoint: p, priorSelection: prior,
                        marqueeBase: selectedIds, marqueeHitId: itemId(at: p))
            return
        }
        // 1. all-day bands (on the lanes) — selectable at every zoom incl. year view. A PROMOTED ghost
        // (its box id carries ~p) has no band of its own — its date mirrors the source event, so the only
        // draggable axis is the LANE: force the lane-only kind (edges don't resize a 1-day mirror either).
        if let hit = bandAt(p, g) {
            selectedId = hit.id
            let kind: PointerKind = hit.id.hasSuffix(PROMOTED_SUFFIX) ? .promotedMove : hit.zone
            drag = Drag(kind: kind, startPoint: p, eventId: hit.id,
                        origBand: items.bands.first { $0.id == hit.id }, priorSelection: prior)
            return
        }
        // 2. timed events (on the timeline)
        if z >= 1.5, let hit = eventAt(p, g) {
            selectedId = hit.id
            drag = Drag(kind: hit.zone, startPoint: p, eventId: hit.id, orig: items.events.first { $0.id == hit.id },
                        priorSelection: prior, titleHit: hit.overTitle)
            return
        }
        // 3. deadlines (on the timeline)
        if z >= ViewConst.detailZ, let id = deadlineAt(p, g) {
            selectedId = id
            drag = Drag(kind: .ddlMove, startPoint: p, eventId: id, origDdl: items.deadlines.first { $0.id == id })
            return
        }
        // 3b. deadline quick-add "+" (near a day's left edge, on an hour line) → create a deadline and
        //     open the drawer with its default title selected. Checked before the empty-timeline drag so
        //     a click on the "+" creates a deadline rather than starting a timed-event drag.
        if z >= 1.5, let spot = deadlineAddSpot(g), hypot(p.x - spot.x, p.y - spot.y) < 12 {
            let id = createDeadline(year: spot.year, month: spot.month, day: spot.day,
                                    hour: CGFloat(spot.hour), title: "New Deadline", color: "default")
            onRequestOpenDrawer?(id, true)
            drag = nil
            return
        }
        // 4. empty timeline → a DRAG creates; a plain click deselects (if something was
        //    selected) or navigates. Selection is cleared on up (not now) so the drag
        //    can still create.
        if z >= 1.5, let spot = createSpot(at: p, g) {
            drag = Drag(
                kind: .create,
                startPoint: p,
                anchorHour: spot.anchor,
                createYear: spot.year,
                createMonth: spot.month,
                createDay: spot.day,
                priorSelection: prior
            )
            return
        }
        // 5. empty lane → band create (drag) / deselect / navigate
        if let slot = bandSlotAtPoint(p.x, p.y, g) { // empty lane, any zoom incl. year view
            drag = Drag(
                kind: .bandCreate,
                startPoint: p,
                bandMonth: slot.month,
                bandTrack: slot.track,
                bandAnchorDay: slot.day,
                priorSelection: prior
            )
            return
        }
        drag = Drag(kind: .navigate, startPoint: p, priorSelection: prior)
    }

    public func onPointerDrag(at p: CGPoint) {
        wake()
        guard var d = drag else { return }
        if !d.activated {
            if hypot(p.x - d.startPoint.x, p.y - d.startPoint.y) < 3 {
                return
            }
            d.activated = true
            drag = d
        }
        let g = snapshot()
        let tl = timelineInfo(g)
        switch d.kind {
        case .navigate: break
        case .move: applyMove(d, p, tl)
        case .resizeTop: applyResize(d, p, tl, top: true)
        case .resizeBottom: applyResize(d, p, tl, top: false)
        case .create: applyCreate(p, tl)
        case .bandMove: applyBandMove(d, p, g)
        case .promotedMove: applyPromotedLaneMove(d, p, g)
        case .bandResizeL: applyBandResize(d, p, g, left: true)
        case .bandResizeR: applyBandResize(d, p, g, left: false)
        case .bandCreate: applyBandCreate(p, g)
        case .ddlMove: applyDdlMove(d, p, g)
        case .marquee: updateMarquee(d, p, g, negative: false)
        case .negMarquee: updateMarquee(d, p, g, negative: true)
        }
    }

    /// Recompute the selection while a marquee drag is active: base ± every item whose box intersects the
    /// rect from the drag anchor to `p`. Positive unions; negative subtracts. Sets `marqueeRect` for the overlay.
    private func updateMarquee(_ d: Drag, _ p: CGPoint, _ g: SceneInput, negative: Bool) {
        let rect = CGRect(x: min(d.startPoint.x, p.x), y: min(d.startPoint.y, p.y),
                          width: abs(p.x - d.startPoint.x), height: abs(p.y - d.startPoint.y))
        marqueeRect = rect; marqueeNegative = negative
        let hit = itemsIntersecting(rect, g)
        let base = d.marqueeBase ?? []
        let result = negative ? base.subtracting(hit) : base.union(hit)
        setSelection(result, primary: result.contains(selectedId ?? "\u{0}") ? selectedId : result.first)
    }

    public func onPointerUp(at p: CGPoint) {
        wake()
        defer { commitTxn(); drag = nil; marqueeRect = nil } // one undo entry per drag; clear the marquee box
        guard let d = drag else { return }
        // Plain click (no drag) in empty space (create/band-create primed, or navigate):
        // deselect if something was selected, otherwise navigate (drill in).
        if !d.activated {
            switch d.kind {
            case .marquee, .negMarquee:
                // A shift-CLICK (no drag): toggle the box under the cursor; on truly-empty space, do nothing
                // (keep the selection — shift-click-empty shouldn't clear it).
                if let id = d.marqueeHitId {
                    toggleInSelection(id)
                }
            case .create, .bandCreate, .navigate:
                // Empty-space click: clear ANY selection — single OR multi (a ⌘A / marquee set has no
                // single primary, so check the set too). Nothing selected → navigate (drill in).
                if selectedId != nil || !selectedIds.isEmpty {
                    deselectAll()
                } else {
                    navigate(at: p)
                }
            case .bandMove:
                // click the body of an ALREADY-selected band → edit its title inline
                if d.priorSelection == d.eventId, let id = d.eventId {
                    editBand(id)
                }
            case .move:
                // click the TITLE of an ALREADY-selected timed event → edit its title inline (the I-beam
                // affordance). A click elsewhere on the body (grab) leaves it selected without editing.
                // Pass the click so the editor opens over the SEGMENT you clicked (a cross-midnight event
                // draws on several days), not always the first one.
                if d.priorSelection == d.eventId, d.titleHit, let id = d.eventId {
                    editTimed(id, at: p)
                }
            default:
                break
            }
            return
        }
        // discard a too-small created timed event
        if d.kind == .create, let id = d.eventId, let e = items.events.first(where: { $0.id == id }),
           e.endHour - e.startHour < 0.25 {
            items.events.removeAll { $0.id == id }
            if selectedId == id {
                selectedId = nil
            }
        }
        // a freshly drag-created band → open its title editor so the name is focused for typing
        if d.kind == .bandCreate, let id = d.eventId, items.bands.contains(where: { $0.id == id }) {
            editBand(id)
        }
    }

    /// Drill one zoom level into whatever sits at point `p` (year→month→week→day) — the Mac's
    /// empty-space click. The iPhone calls this only from its YEAR-view empty-space double
    /// tap; its deeper levels zoom exclusively through the pinch → `onMagnify` path.
    public func navigate(at p: CGPoint) {
        let g = snapshot()
        switch level(z) {
        case 0:
            if let m = monthAtPoint(p.x, p.y, g) ?? monthNameAtPoint(p.x, p.y, g) {
                focus = m
                // Carry the quarter's horizontal scroll into the month view (phone overflow;
                // both stay 0 on desktop) so the visible columns don't jump during the zoom.
                monthQX = clamp(yearQX.indices.contains(m / 3) ? yearQX[m / 3] : 0,
                                0, yearQuarterMaxX(viewport))
                tweenZ(to: 1)
            }
        case 1:
            if Layout.weekDaysVisible < 7 {
                // Partial window (phone): center the window on the TAPPED day column (not its
                // whole week), clamped to the month-bounded travel range (see weekBounds).
                let dayW = monthDayW(viewport, pin: dashPin, frac: dashMonthFrac)
                let slot = ((p.x - Layout.labelW + monthQX) / dayW).rounded(.down)
                    + CGFloat(firstDOW(year, focus))
                let b = weekBounds
                week = clamp((slot + 0.5 - Layout.weekDaysVisible / 2).rounded() / 7, b.min, b.max)
                captureZoomAnchor(pointerY: p.y)
                tweenZ(to: 2)
            } else if let w = weekAtPointInMonth(p.x, g) {
                week = CGFloat(w); captureZoomAnchor(pointerY: p.y); tweenZ(to: 2)
            }
        case 2:
            // Only focus-month days drill into day view; spillover days aren't zoomable.
            if let d = dayAtPointInWeek(p.x, g), let rd = relDomOf(year, focus, d.year, d.month, d.day),
               rd >= 1, rd <= daysInMonth(year, focus) {
                // weekFor keeps the week window aligned with the drilled day (whole week on
                // desktop; day-centered + month-bounded on the phone's partial window), so
                // zooming back out lands on a legal window showing it.
                daily.dom = rd; week = weekFor(dom: rd); tweenZ(to: 3)
            }
        default: break
        }
    }

    /// ── Keyboard navigation cursor: input mode, movement, geometry, zoom ───────────
    /// True while any view anim.tween/flip is in flight — the cursor ring should follow the geometry each
    /// frame WITHOUT its own spring (avoids lag during zoom/scroll); it springs only for discrete moves.
    public var isAnimating: Bool {
        anim.tween != nil || anim.scrollTween != nil || anim.tlScrollTween != nil || anim.weekTween != nil || anim
            .dayTween != nil || anim.monthGlide != nil ||
            anim.flipAnim != nil || anim.monthAnim != nil || anim.weekFlip != nil || anim.dayFlip != nil
    }

    public func onHover(at p: CGPoint) {
        if drawerOpen {
            onHoverExit(); return
        } // drawer open → no calendar hover highlights
        pointerPos = p // for the deadline "+" hover glow (pixel-precise)
        // Timeline scale-bar proximity reveal: the bar fades in only when the cursor approaches
        // the timeline's left border (week/day views). Observable + wake, so the overlay reacts
        // even when the render loop is idle.
        let near = level(z) >= 2 && abs(p.x - Layout.labelW) < ViewConst.tlEdgeRevealDist
        if near != nearTlEdge {
            nearTlEdge = near; wake()
        }
        let g = snapshot()
        let prevHover = hover, prevHovered = hoveredEventId // wake the render only if the visual actually changes
        var hv = Hover()
        switch level(z) {
        case 0:
            let m = monthRowAtPoint(p.x, p.y, g)
            hv.month = m
            hv.nameMonth = monthNameAtPoint(p.x, p.y, g)
            if let m {
                hv.dom = domInMonthBand(p.x, m, g)
            }
        case 1:
            // Crosshair: track lane (band cell or track-name gutter) + day column (band or timeline).
            let f = frameFor(focus, g)
            let bandTop = f.bandY, bandBottom = f.bandY + 4 * f.trackH
            let inGutter = p.x < Layout.labelW
            if p.y >= bandTop, p.y < bandBottom,
               !inGutter || (p.x >= Layout.mnameW && p.x <= Layout.labelW - Layout.rightPad) {
                hv.track = min(3, max(0, Int((p.y - bandTop) / f.trackH)))
            }
            if !inGutter {
                hv.dom = domInFocus(p.x, g)
            } // day column when over content (band or timeline)
        default:
            // In daily view the right panel is the dashboard — no background time cursor there.
            // Use the FIXED dashboard boundary (pan-independent) so a mid-scroll cursor near the edge
            // doesn't leak into the dashboard region.
            if z > 2, p.x >= dashboardLeft(g) {
                hover = .none; return
            }
            let c = cellInWeek(p.x, p.y, g)
            hv.dom = c.dom; hv.hour = c.hour; hv.hourFrac = c.hourFrac; hv.nearLeft = c.nearLeft
        }
        // Hover stickiness: if the cursor is still inside the currently-hovered event,
        // keep it — so moving into an overlap doesn't hand the highlight to the event
        // underneath. Only when the cursor leaves it do we re-pick the topmost.
        if let cur = hoveredEventId, bandContains(cur, p, g) {
            // keep hoveredEventId — a band (no timeline cursor change)
        } else if let cur = hoveredEventId, timedContains(cur, p, g) {
            hv.overTimed = true // keep hoveredEventId — a timed event
        } else if let b = bandAt(p, g) {
            hoveredEventId = b.id
        } else if z >= 1.5, let e = eventAt(p, g) {
            hoveredEventId = e.id; hv.overTimed = true
        } else if z >= ViewConst.detailZ, let d = deadlineAt(p, g) {
            hoveredEventId = d; hv.overDeadline = true
        } else {
            hoveredEventId = nil
        }
        hover = hv
        // Wake on any change, plus every move while near a day's left edge so the deadline "+" glow
        // tracks the cursor pixel-precisely (the cell-based `hv` alone wouldn't change within a cell).
        if hv != prevHover || hoveredEventId != prevHovered || hv.nearLeft == true {
            wake()
        }
    }

    private func bandContains(_ id: String, _ p: CGPoint, _ g: SceneInput) -> Bool {
        guard let b = items.bands.first(where: { $0.id == id }),
              let r = bandEventRect(b, g, anim: g.monthAnim) else { return false }
        return CGRect(x: r.x, y: r.y, width: r.w, height: r.h).contains(p)
    }

    private func timedContains(_ id: String, _ p: CGPoint, _ g: SceneInput) -> Bool {
        guard z >= 1.5, let e = items.events.first(where: { $0.id == id }) else { return false }
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return false }
        guard p.y >= tl.tlTop, p.y <= tl.tlBottom else { return false } // clip to the timeline (see eventAt)
        let sameDay = eventsOn(year, e.month, e.day)
        guard let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) else { return false }
        return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height).contains(p)
    }

    public func onHoverExit() {
        if hover != .none || hoveredEventId != nil {
            wake()
        }
        hover = .none; hoveredEventId = nil; pointerPos = nil
        if nearTlEdge {
            nearTlEdge = false; wake()
        }
    }

    /// Clear the hover HIGHLIGHT only — used when scrolling starts (the content moves under a
    /// stationary cursor, so the highlight is stale) — but keep the pointer position and the
    /// scale-bar proximity (`nearTlEdge`): the mouse hasn't gone anywhere.
    public func clearHoverHighlight() {
        if hover != .none || hoveredEventId != nil {
            wake()
        }
        hover = .none; hoveredEventId = nil
    }

    /// Clear the current event selection — the same effect as a plain click on empty calendar space.
    /// Used by the daily-dashboard WebView so clicking its empty content deselects too.
    public func deselect() {
        selectedId = nil; cursor.bandCursorActive = false
    } // Esc from an event → block cursor (home)

    public func cursorHint(at p: CGPoint) -> CursorHint {
        if trackNameHit(at: p) != nil {
            return .text
        } // editable lane label
        let g = snapshot()
        if let hit = bandAt(p, g) {
            // A promoted ghost only drags across LANES (its date mirrors the source) → always a grab hand,
            // never the ↔ resize even at its edges, and no title I-beam (rename the source event instead).
            if hit.id.hasSuffix(PROMOTED_SUFFIX) {
                return .grab
            }
            if hit.zone == .bandResizeL || hit.zone == .bandResizeR {
                return .resizeLR
            }
            return hit.id == selectedId ? .text : .grab // a selected band edits its title on click
        }
        // Timed event: the top/bottom edges resize (↕); the title of a SELECTED event is an I-beam (a second
        // click inline-edits it); the accent bar, the time text, and the empty body are a grab hand.
        if z >= 1.5, let hit = eventAt(p, g) {
            switch hit.zone {
            case .resizeTop, .resizeBottom: return .resizeV
            default: return (hit.id == selectedId && hit.overTitle) ? .text : .grab
            }
        }
        if z >= ViewConst.detailZ, deadlineAt(p, g) != nil {
            return .grab
        }
        return .normal // empty calendar → plain arrow (no create "+" cursor)
    }
}
