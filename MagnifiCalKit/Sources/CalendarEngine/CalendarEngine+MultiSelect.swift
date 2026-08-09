// Multi-selection: a set of selected boxes on top of the single `selectedId` primary. Shift-click toggles,
// a marquee unions/subtracts (see Stage 2), and batch ops act over the whole set (see +Batch). The set is
// transient (never persisted); `selectedId` stays the primary/anchor so all single-item code keeps working.

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// Replace the whole selection, owning BOTH `selectedId` (primary) and `selectedIds` in one guarded
    /// write so the single-select didSet mirror doesn't clobber the set.
    func setSelection(_ ids: Set<String>, primary: String?) {
        inMultiSelect = true
        selectedId = primary
        selectedIds = ids
        inMultiSelect = false
    }

    /// Shift-click: add/remove one box, keeping the rest. The toggled box becomes the primary when added;
    /// otherwise the primary falls back to a remaining member.
    public func toggleInSelection(_ boxId: String) {
        wake()
        var s = selectedIds
        if s.contains(boxId) {
            s.remove(boxId)
            setSelection(s, primary: selectedId == boxId ? s.first : selectedId)
        } else {
            s.insert(boxId)
            setSelection(s, primary: boxId)
        }
        cursor.bandCursorActive = false
    }

    /// Clear the whole selection (⌘D / empty-space click / Esc while multi-selected).
    public func deselectAll() {
        wake()
        setSelection([], primary: nil)
        cursor.bandCursorActive = false
    }

    /// Every visible item whose drawn box intersects `rect` (geometry space) — the marquee + select-all
    /// query. Mirrors the point hit-tests with `.intersects`, using the same per-day packing the overlay draws.
    public func itemsIntersecting(_ rect: CGRect, _ g: SceneInput) -> Set<String> {
        var ids: Set<String> = []
        // Bands (every zoom level).
        for b in viewBands() {
            if let r = bandEventRect(b, g, anim: g.monthAnim),
               rect.intersects(CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) {
                ids.insert(b.id)
            }
        }
        // Timed + deadlines only exist where the hourly timeline is shown (week/day).
        guard g.z >= 1.5 else { return ids }
        let tl = timelineInfo(g)
        if tl.hourH > 0, tl.colW > 0 {
            let c0 = Int(floor((rect.minX - tl.x0) / tl.colW)) + 1
            let c1 = Int(floor((rect.maxX - tl.x0) / tl.colW)) + 1
            for col in c0 ... max(c0, c1) {
                guard let rd = resolveDate(year, focus, col) else { continue }
                let segs = eventsOn(rd.year, rd.month, rd.day) // per-day packed segments (matches the render)
                let layout = layoutDay(segs)
                for e in segs {
                    guard let r = eventRect(e, year, focus, tl, g.vp, layout[e.id]) else { continue }
                    let screen = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                    if rect.intersects(screen) {
                        ids.insert(e.id)
                    }
                }
            }
        }
        for d in viewDeadlines() {
            if let pos = deadlinePos(d, g) {
                let screen = CGRect(x: pos.x - 4, y: pos.y - 8, width: pos.w + 8, height: 16) // moment line + pill row
                if rect.intersects(screen) {
                    ids.insert(d.id)
                }
            }
        }
        return ids
    }

    /// ⌘A: select every item currently visible in the viewport.
    public func selectAllInViewport() {
        wake() // render loop may be idle — the new selection must paint NOW, not on the next input
        let g = snapshot()
        setSelection(itemsIntersecting(CGRect(x: 0, y: 0, width: g.vp.w, height: g.vp.h), g), primary: nil)
    }
}
