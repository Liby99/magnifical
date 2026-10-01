// ONE drag-and-drop destination for the whole window, routing per-move to the right target.
//
// WHY (field-established 2026-09-30, three probe stages): AppKit picks a drop destination
// ONCE when a drag enters the window — by an undocumented frame walk whose ordering SwiftUI
// reshuffles as hosted views mount per calendar level — and that view then keeps the session
// for as long as the cursor stays inside its frame. The window-spanning SwiftUI .onDrop host
// (the .ics import target) kept winning that pick, and since its frame IS the window, the
// note editors below never heard the drag no matter where the cursor moved. Symptom: file
// drops into notes working or silently dying depending on view level and window-entry point.
//
// HOW A FILE DRAG FLOWS NOW
//   1. The router is the ONLY view registered for file/promise drags (participants register
//      here, never with AppKit), so every file-drag session lands on it — always.
//   2. On every mouse move it re-picks the target: the best-tier interactive participant
//      whose frame contains the cursor and that accepts (see DropTarget.dropTier).
//   3. Target changes are forwarded as real draggingExited/Entered, so each target's own
//      overlays and acceptance logic (caret insertion, margin append, promise intake) run
//      completely unchanged.
//   4. The release goes to the active target; with none under the cursor, the .ics fallback
//      imports calendar files (the old window-wide behavior, now scoped to "nowhere better").
// Every routing switch logs at notice — `log show … category == "attach"` narrates a drag.

import AppKit
import CalendarEngine
import UniformTypeIdentifiers

/// A drop participant. `dropTier` is the EXPLICIT precedence (lower wins):
///   0 editor text in the event drawer      3 editor text in a dated-notes panel
///   1 editor margin in the event drawer    4 editor margin in a dated-notes panel
///   2 preview pane in the event drawer     5 preview pane in a dated-notes panel
/// Drawer tiers outrank every panel tier, so a drop on the open drawer can never land in
/// the blurred weekly note behind it. Within a context, editor-vs-margin is spatial anyway
/// (the text's frame vs the blank area below it), and editor/preview never show together.
@MainActor protocol DropTarget: NSView {
    var dropTier: Int { get }
}

/// The participant registry: every attachment drop view announces itself when it lands in
/// a window. Candidacy = attached to THIS window, genuinely visible, not modally covered,
/// frame contains the cursor.
@MainActor enum DropTargets {
    private struct Entry {
        weak var view: (NSView & DropTarget)?
    }

    private static var entries: [Entry] = []

    static func register(_ v: NSView & DropTarget) {
        entries.removeAll { $0.view == nil }
        guard !entries.contains(where: { $0.view === v }) else { return }
        entries.append(Entry(view: v))
    }

    /// Interactive participants in `window` whose window-frame contains `p`, best tier first.
    static func candidates(in window: NSWindow, at p: NSPoint) -> [NSView & DropTarget] {
        entries.compactMap(\.view)
            .filter { v in
                v.window === window && v.attachDropVisible && !isModallyCovered(v)
                    && v.convert(v.bounds, to: nil).contains(p)
            }
            .sorted { $0.dropTier < $1.dropTier }
    }

    /// The drawer-over-dashboard gating, honored for drags exactly as for clicks: a panel
    /// the open drawer covers is inert/suspended — and therefore no drop candidate.
    private static func isModallyCovered(_ v: NSView) -> Bool {
        if let s = v as? InertableScrollView, s.inert {
            return true
        }
        if let t = v as? NativeNoteEditor.EditorTextView, t.suspended {
            return true
        }
        if let pv = v as? PreviewTextView, pv.suspended {
            return true
        }
        return false
    }
}

/// The single window-wide destination. Installed once per window by the first participant
/// (idempotent by content-view presence — offscreen windows all share windowNumber -1, and
/// a swapped content view needs a fresh install anyway).
@MainActor final class AttachmentDropRouter: NSView {
    /// The .ics fallback, wired by CalendarView (it owns the engine and the overlay state).
    static var icsImport: (([URL]) -> Void)?
    static var icsOverlay: ((Bool) -> Void)?

    static func install(in window: NSWindow) {
        guard let root = window.contentView,
              !root.subviews.contains(where: { $0 is AttachmentDropRouter }) else { return }
        let router = AttachmentDropRouter(frame: root.bounds)
        router.autoresizingMask = [.width, .height]
        router.registerForDraggedTypes(AttachmentDropIntake.draggedTypes)
        root.addSubview(router, positioned: .above, relativeTo: nil)
        attachLog.notice("drop router installed in window #\(window.windowNumber)")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil // ordinary mouse never sees the router; only drag sessions land here
    }

    // ── Session state ─────────────────────────────────────────────────────────────────
    /// The participant currently owning the session's visuals and the eventual drop.
    private weak var activeTarget: (NSView & DropTarget)?
    private var icsOverlayShown = false
    /// Pasteboard facts, decoded once per drag session (updates arrive per mouse move).
    private var icsCache: (sessionID: Int, carriesICS: Bool)?

    private func dragCarriesICS(_ sender: NSDraggingInfo) -> Bool {
        if let c = icsCache, c.sessionID == sender.draggingSequenceNumber {
            return c.carriesICS
        }
        let urls = AttachmentDropIntake.fileURLs(sender.draggingPasteboard) ?? []
        let ics = urls.contains { $0.pathExtension.lowercased() == "ics" }
        icsCache = (sender.draggingSequenceNumber, ics)
        return ics
    }

    // ── The dispatch, step by step ────────────────────────────────────────────────────

    /// Per-move routing: pick → transition → operation. Called from entered AND updated,
    /// so the target tracks the cursor even though AppKit's session never re-resolves.
    private func route(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let window else { return [] }
        let (target, operation) = pickTarget(in: window, sender: sender)
        transition(to: target, sender: sender)
        if target != nil {
            setICSOverlay(false)
            return operation
        }
        // Nobody wants it → the .ics fallback (the mask lights up only for .ics drags).
        let ics = dragCarriesICS(sender)
        setICSOverlay(ics)
        return ics ? .copy : []
    }

    /// The best candidate that ACCEPTS wins: the current target is continued via
    /// draggingUpdated; a new one is asked via draggingEntered; a refusal (no store wired,
    /// hidden twin) falls through to the next candidate instead of ending the search.
    private func pickTarget(in window: NSWindow, sender: NSDraggingInfo)
        -> (target: (NSView & DropTarget)?, operation: NSDragOperation) {
        for candidate in DropTargets.candidates(in: window, at: sender.draggingLocation) {
            if candidate === activeTarget {
                return (candidate, candidate.draggingUpdated(sender))
            }
            let operation = candidate.draggingEntered(sender)
            if operation != [] {
                return (candidate, operation)
            }
        }
        return (nil, [])
    }

    /// Hand the session over: the outgoing target gets draggingExited (its overlay comes
    /// down — the entered side already ran inside pickTarget), and the switch is logged.
    private func transition(to target: (NSView & DropTarget)?, sender: NSDraggingInfo) {
        guard target !== activeTarget else { return }
        activeTarget?.draggingExited(sender)
        let p = sender.draggingLocation
        attachLog.notice("""
        drop route: \(target.map { "\(String(describing: type(of: $0))) tier \($0.dropTier)" } ?? "none") \
        at \(Int(p.x)),\(Int(p.y))\(self.activeTarget.map { " (was \(String(describing: type(of: $0))))" } ?? "")
        """)
        activeTarget = target
    }

    private func setICSOverlay(_ on: Bool) {
        guard on != icsOverlayShown else { return }
        icsOverlayShown = on
        Self.icsOverlay?(on)
    }

    // ── NSDraggingDestination (no super: plain NSView implements none of these) ──────
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = sender.draggingLocation
        attachLog.notice("drop router: session entered at \(Int(p.x)),\(Int(p.y))")
        return route(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        route(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender {
            activeTarget?.draggingExited(sender)
        }
        activeTarget = nil
        setICSOverlay(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        activeTarget?.draggingEnded(sender)
        activeTarget = nil
        setICSOverlay(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let activeTarget {
            return activeTarget.prepareForDragOperation(sender)
        }
        return dragCarriesICS(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setICSOverlay(false)
        if let activeTarget {
            attachLog.notice("drop router: perform → \(String(describing: type(of: activeTarget)))")
            let handled = activeTarget.performDragOperation(sender)
            self.activeTarget = nil
            return handled
        }
        guard dragCarriesICS(sender),
              let urls = AttachmentDropIntake.fileURLs(sender.draggingPasteboard) else {
            return false
        }
        attachLog.notice("drop router: perform → ics import (\(urls.count) file(s))")
        Self.icsImport?(urls)
        return true
    }
}
