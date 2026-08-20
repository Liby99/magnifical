// The native dashboard CHROME: the tab rows, note edit/preview toggle, todo cog, the
// per-frame carousel state for those overlays (DashCarouselAnim), the CarouselDriver that
// feeds it every frame, and the CatcherHandle. Split out of the retired dashboard
// webview stack (phase 4a, 2026-08-02) — the WKWebView fallback now lives in legacy/.

import AppKit
import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

/// Shared handle to the calendar's input catcher (the CatcherView NSView, set when the
/// InputCatcher creates it). Menu commands and toolbar actions reach the catcher's clipboard
/// operations (copy/cut/paste/read) through this. Named GestureForwarder pre-4a, when the
/// dashboard webview also used it to hand gestures back to the calendar.
@MainActor final class CatcherHandle { weak var catcher: NSView? }

/// Per-frame carousel state for the NATIVE SwiftUI tabs, so they slide + fade in lockstep with the
/// Canvas title and the WebView content when paging days. Written by the driver (inside TimelineView),
/// read by DashTabs. Guarded sets → no re-render while idle (p=0, reveal=1, slide=0 constant).
@MainActor @Observable final class DashCarouselAnim {
    var dir = 0
    var p = 0.0
    var reveal = 1.0
    var gutterShift = 0.0 // engine.gutterShift mirrored per frame (gutter hide slide)
    var headerTopY = Double(Layout.topPad) // the focused band's ANIMATED top (accordion / page-turn)
    var headerTopY2 = Double(Layout.topPad) // the INCOMING month band's top during a page-turn
    var panelLeft = 0.0 // dashboardLeftAnimated — the panel's live left edge (pinned width morphs)
    var monthP = 0.0 // month page-turn progress
    var monthDir = 0
    var scopeT = 1.0 // zoom-scope carousel fraction (0 = lower scope at rest … 1 = upper at rest)
    var weekP = 0.0 // week-turn progress (weekly dashboard; rests at BOTH 0 and 1)
    // Per-panel scope geometry (GEOMETRY-space px, same numbers the Canvas header draws with) —
    // the tab rows anchor to each panel's RIGHT edge and fade with its opacity.
    var aName = ""
    var aX = 0.0
    var aW = 0.0
    var aOp = 0.0
    var bName = ""
    var bX = 0.0
    var bW = 0.0
    var bOp = 0.0
    func set(dir: Int, p: Double, reveal: Double,
             headerTopY: Double, headerTopY2: Double, panelLeft: Double,
             monthP: Double, monthDir: Int, scopeT: Double, weekP: Double,
             aName: String, aX: Double, aW: Double, aOp: Double,
             bName: String, bX: Double, bW: Double, bOp: Double,
             gutterShift: Double = 0) {
        if self.gutterShift != gutterShift {
            self.gutterShift = gutterShift
        }
        if self.dir != dir {
            self.dir = dir
        }
        if self.p != p {
            self.p = p
        }
        if self.reveal != reveal {
            self.reveal = reveal
        }
        if self.headerTopY != headerTopY {
            self.headerTopY = headerTopY
        }
        if self.panelLeft != panelLeft {
            self.panelLeft = panelLeft
        }
        if self.monthP != monthP {
            self.monthP = monthP
        }
        if self.headerTopY2 != headerTopY2 {
            self.headerTopY2 = headerTopY2
        }
        if self.monthDir != monthDir {
            self.monthDir = monthDir
        }
        if self.scopeT != scopeT {
            self.scopeT = scopeT
        }
        if self.weekP != weekP {
            self.weekP = weekP
        }
        if self.aName != aName {
            self.aName = aName
        }
        if self.aX != aX {
            self.aX = aX
        }
        if self.aW != aW {
            self.aW = aW
        }
        if self.aOp != aOp {
            self.aOp = aOp
        }
        if self.bName != bName {
            self.bName = bName
        }
        if self.bX != bX {
            self.bX = bX
        }
        if self.bW != bW {
            self.bW = bW
        }
        if self.bOp != bOp {
            self.bOp = bOp
        }
    }
}

/// Invisible per-frame driver — lives INSIDE the TimelineView so `updateNSView` runs every frame
/// with fresh carousel values, forwarding them to the anim state the native tab/chrome overlays
/// read. (Until phase 4a this also ticked the dashboard WKWebView's CSS conduit — see legacy/.)
struct CarouselDriver: NSViewRepresentable {
    let anim: DashCarouselAnim
    let dir: Int, p: Double, reveal: Double
    var scopeT: Double = 1 // eased fraction between the lower and upper zoom scopes
    var headerTopY: Double = .init(Layout.topPad) // focused band's animated top (canvas-anchored)
    var headerTopY2: Double = .init(Layout.topPad) // incoming month band's top (page-turns)
    var panelLeft: Double = 0 // dashboardLeftAnimated (for the native tab overlay)
    var mDir: Int = 0
    var mP: Double = 0 // month page-turn progress
    var wP: Double = 0 // week-turn progress (0 = base week at rest … 1 = next week at rest)
    // Per-panel scope geometry from dashScopePanels, frame-local px (frame left = labelW):
    var aName: String = "", aX: Double = 0, aW: Double = 0, aOp: Double = 0 // current/outgoing panel
    var bName: String = "", bX: Double = 0, bW: Double = 0, bOp: Double = 0 // incoming (transitions)
    var gutterShiftX: Double = 0 // gutter hide (engine.gutterShift): body-level frame/offset rides it
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ v: NSView, context: Context) {
        anim.set(dir: dir, p: p, reveal: reveal,
                 headerTopY: headerTopY, headerTopY2: headerTopY2, panelLeft: panelLeft,
                 monthP: mP, monthDir: mDir, scopeT: scopeT, weekP: wP,
                 aName: aName, aX: aX, aW: aW, aOp: aOp,
                 bName: bName, bX: bX, bW: bW, bOp: bOp,
                 gutterShift: gutterShiftX)
    }
}

/// The TODO/NOTE tabs — a SEPARATE overlay (above the WebView, so the hosted WKWebView NSView can't
/// hit-test over them). Text-only, right-aligned in the title zone (mirrors the web's `.cc-dd-tabs`).
/// Placement is per-PANEL: each scope panel from dashScopePanels (via `anim`) gets its own row,
/// right-aligned to that panel's right edge and fading with the panel's opacity — so the tabs are
/// glued to their sliding sheet through every scope transition, exactly like the Canvas headers.
struct DashTabsOverlay: View {
    let engine: CalendarEngine
    let anim: DashCarouselAnim
    @Binding var tab: DashTab
    let frac: CGFloat
    let vp: Viewport
    let containerWidth: CGFloat
    let theme: Theme

    var body: some View {
        if engine.chrome.level >= 2 || (engine.chrome.dashPresented && engine.chrome.level >= 1) {
            // Each scope panel carries ITS OWN tabs row, right-aligned to THAT panel's right edge
            // (`x + w` from dashScopePanels — the same numbers the Canvas header and webview place
            // with), fading with the panel's cross-fade. So during a scope transition the rows
            // travel glued to their sliding sheets instead of jumping between mask formulas.
            panelTabs(name: anim.aName, x: anim.aX, w: anim.aW, op: anim.aOp)
            if anim.bOp > 0.001 {
                panelTabs(name: anim.bName, x: anim.bX, w: anim.bW, op: anim.bOp)
            }
        }
    }

    /// One panel's tabs row. `x`/`w` are the panel's own geometry (frame-local px, frame left =
    /// labelW). The month panel rides its band's animated top — a month page-turn shows TWO copies,
    /// each on its own band (identical rows: the pair reads as the tabs traveling with the sheets).
    /// Rows are additionally clipped at the live mask edge so an entering panel's tabs never draw
    /// over the calendar grid to the mask's left.
    @ViewBuilder private func panelTabs(name: String, x: Double, w: Double, op: Double) -> some View {
        let left = Layout.padLeft + Layout.labelW + CGFloat(x)
        let width = max(1, CGFloat(w))
        let opac = anim.reveal * op
        let clipLeft = max(0, CGFloat(anim.panelLeft) - (Layout.labelW + CGFloat(x)))
        if opac > 0.001 {
            let y0 = name == "month" ? CGFloat(anim.headerTopY) : CGFloat(Layout.topPad)
            // Inner horizontal paging within the panel: the day panel rides day page-turns, the
            // week panel rides the week-to-week turn (rests at BOTH ends of its progress).
            let (pageDir, pageP): (Int, Double) = name == "day"
                ? (anim.dir, anim.p)
                : (name == "week" ? (1, anim.weekP) : (0, 0))
            DashTabs(tab: $tab, theme: theme, anim: anim, w: width, op: opac,
                     clipLeft: clipLeft, pageDir: pageDir, pageP: pageP)
                .position(x: left + width / 2, y: y0 + Layout.monthH - 14)
            if name == "month", anim.monthP > 0.001 {
                DashTabs(tab: $tab, theme: theme, anim: anim, w: width, op: opac,
                         clipLeft: clipLeft, pageDir: 0, pageP: 0)
                    .position(x: left + width / 2, y: CGFloat(anim.headerTopY2) + Layout.monthH - 14)
            }
        }
    }
}

/// The note edit/preview toggle — a native segmented control (pencil/eye), same as the drawer's foot,
/// pinned bottom-right of the dashboard panel. Shown at rest on the NOTE tab (day level). Drives the
/// `noteMode` binding (→ CK.setNoteMode); the WebView also updates it (content-based / ⌘S / ⌘-click).
struct NoteModeToggleOverlay: View {
    let engine: CalendarEngine
    let anim: DashCarouselAnim
    let tab: DashTab
    @Binding var noteMode: NotesMode
    let containerWidth: CGFloat
    let height: CGFloat
    let theme: Theme

    var body: some View {
        // Day view, or the pinned weekly/monthly dashboard — every scope has a live note editor.
        if tab == .note,
           engine.chrome.level == 3 || (engine.chrome.dashPresented && engine.chrome.level >= 1) {
            let right = containerWidth - Layout.padRight
            let bottom = height - Layout.bottomPad
            // Visible only at FULL rest: revealed, no day-page, no scope-zoom, no month/week turn
            // (the week turn rests at 1 as well as 0).
            let atRest = anim.reveal > 0.5 && anim.p < 0.01
                && (anim.scopeT < 0.01 || anim.scopeT > 0.99) && anim.monthP < 0.01
                && (anim.weekP < 0.01 || anim.weekP > 0.99)
            Picker("", selection: $noteMode) {
                Image(systemName: "pencil").tag(NotesMode.edit)
                Image(systemName: "eye").tag(NotesMode.preview)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .tint(Theme.accent)
            .opacity(atRest ? 1 : 0) // hide during swipe / while zooming
            .position(x: right - 46, y: bottom - 2)
            .animation(.easeOut(duration: 0.12), value: atRest)
        }
    }
}

/// The TODO layering cog — bottom-right of the dashboard panel on the TODO tab (the NOTE tab's
/// edit/preview toggle sibling, same placement + rest gating). Left-click pops the native callout
/// menu (Display Deadlines / Show Collections ▸ / Collect from… ▸); right-clicking inside the
/// TODO panel pops the SAME menu (PassThroughWebView.todoContextMenu). The menu targets whichever
/// dashboard scope is currently visible (day / pinned week / pinned month).
struct TodoCogOverlay: View {
    let engine: CalendarEngine
    let anim: DashCarouselAnim
    let tab: DashTab
    let controller: DashTodoMenuController
    let containerWidth: CGFloat
    let height: CGFloat
    let theme: Theme

    var body: some View {
        if tab == .todo,
           engine.chrome.level == 3 || (engine.chrome.dashPresented && engine.chrome.level >= 1) {
            let right = containerWidth - Layout.padRight
            let bottom = height - Layout.bottomPad
            // Visible only at FULL rest — same gating as the note edit/preview toggle.
            let atRest = anim.reveal > 0.5 && anim.p < 0.01
                && (anim.scopeT < 0.01 || anim.scopeT > 0.99) && anim.monthP < 0.01
                && (anim.weekP < 0.01 || anim.weekP > 0.99)
            CogMenuButton(controller: controller, color: NSColor(theme.textMuted))
                .frame(width: 24, height: 24)
                .opacity(atRest ? 1 : 0)
                .allowsHitTesting(atRest)
                // Equal breathing room to the window's right and bottom edges: the center sits
                // bottomPad+2 (=30px) above the bottom, so match it horizontally (padRight is 0).
                .position(x: right - 30, y: bottom - 2)
                .animation(.easeOut(duration: 0.12), value: atRest)
        }
    }
}

/// AppKit gear button: NSViewRepresentable because popping the shared NSMenu needs a real NSView
/// anchor (NSMenu.popUp), and the menu itself is AppKit so the right-click path can share it.
private struct CogMenuButton: NSViewRepresentable {
    let controller: DashTodoMenuController
    let color: NSColor

    func makeNSView(context: Context) -> NSButton {
        let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "TODO list options")!
        let b = NSButton(image: img, target: context.coordinator, action: #selector(Coord.pop(_:)))
        b.isBordered = false
        b.contentTintColor = color
        context.coordinator.controller = controller
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) {
        b.contentTintColor = color
        context.coordinator.controller = controller
    }

    func makeCoordinator() -> Coord {
        Coord()
    }

    @MainActor final class Coord: NSObject {
        var controller: DashTodoMenuController?
        @objc func pop(_ sender: NSButton) {
            guard let m = controller?.menu() else { return }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
    }
}

private struct DashTabs: View {
    @Binding var tab: DashTab
    let theme: Theme
    let anim: DashCarouselAnim
    let w: CGFloat // the OWNING panel's width — the row right-aligns inside it
    let op: Double // owning panel's opacity (cross-fade × reveal); the row inherits it
    let clipLeft: CGFloat // local x below which the row is masked (the live mask edge)
    let pageDir: Int // inner page-turn direction (day paging / week turn); 0 = none
    let pageP: Double // inner page-turn progress; the WEEK turn rests at both 0 AND 1
    var body: some View {
        ZStack {
            if pageDir != 0, pageP > 0.001, pageP < 0.999 {
                // Mid page-turn: two identical copies slide within the panel, one per sheet.
                row.offset(x: -CGFloat(pageDir) * pageP * w).opacity(op * (1 - pageP))
                row.offset(x: CGFloat(pageDir) * (1 - pageP) * w).opacity(op * pageP)
            } else {
                row.opacity(op)
            }
        }
        .frame(width: w, height: 24)
        .clipped() // clip a sliding copy at the panel edge
        .mask(alignment: .leading) { Rectangle().padding(.leading, clipLeft) }
        // Interactive only at rest: panel fully opaque (no scope transition), no inner page-turn
        // mid-flight (the week turn rests at 1 too), no month-turn in flight. The mid-flight term
        // mirrors the two-copy render condition above EXACTLY — if a single resting row is drawn,
        // it is clickable (a mismatched epsilon here once left a visible row that ignored clicks).
        .allowsHitTesting(op > 0.999 && !(pageDir != 0 && pageP > 0.001 && pageP < 0.999) && anim.monthP < 0.01)
    }

    private var row: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            TabLabel(title: "TODO", selected: tab == .todo, theme: theme) { tab = .todo }
            TabLabel(title: "PROJ", selected: tab == .proj, theme: theme) { tab = .proj }
            TabLabel(title: "NOTE", selected: tab == .note, theme: theme) { tab = .note }
        }
        .padding(.trailing, 18)
        .frame(width: w, alignment: .trailing)
    }
}

private struct TabLabel: View {
    let title: String
    let selected: Bool
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .bold : .regular))
                .tracking(0.9) // ~0.08em on 11px
                .foregroundStyle(theme.text)
                .opacity(selected ? 1 : (hovering ? 0.75 : 0.4))
                .padding(.horizontal, 5).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
