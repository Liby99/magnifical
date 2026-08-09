// The note editor's completion dropdown (the web's .cm-tooltip-autocomplete, natively):
// CompletionPopup's glass panel + its hand-drawn ListView rows.
// Split from NativeNoteEditor.swift (audit round, 2026-08-02).

import AppKit

/// The completion dropdown — the web's .cm-tooltip-autocomplete, natively: rounded 8px panel
/// with a hairline border + shadow, compact Menlo rows ("label → value" details dimmed),
/// accent-filled selection with white text, ≤10 rows visible (scrolled by the selection).
@MainActor final class CompletionPopup {
    private var panel: NSPanel?
    private let list = ListView()
    private weak var host: NSWindow?
    var onPick: ((Int) -> Void)? {
        get { list.onPick }
        set { list.onPick = newValue }
    }

    var active: Bool {
        panel != nil
    }

    var items: [String] = []
    var selected: Int {
        list.selected
    }

    func update(items newItems: [String], accent: NSColor, anchor: NSRect, host hostWin: NSWindow) {
        let changed = newItems != items
        items = newItems
        list.rows = newItems.map { item in
            item.range(of: " → ").map {
                (String(item[..<$0.lowerBound]), String(item[$0.upperBound...]))
            } ?? (item, nil)
        }
        if changed {
            list.selected = 0; list.offset = 0
        }
        list.accent = accent
        let size = list.idealSize()
        let p = panel ?? Self.makePanel(content: list)
        panel = p
        if p.parent == nil {
            hostWin.addChildWindow(p, ordered: .above)
            host = hostWin
        }
        // Below the trigger start; flip above when there's no room underneath.
        var origin = NSPoint(x: anchor.minX - 9, y: anchor.minY - 3 - size.height)
        if let screen = hostWin.screen, origin.y < screen.visibleFrame.minY {
            origin.y = anchor.maxY + 3
        }
        // ORDER MATTERS: window first, then the glass wrapper, then the list — framing the
        // list before its ancestors have size let autoresizing mangle it on the CREATION
        // pass (the "first popup is an empty box" bug; the next update re-framed it).
        p.setFrame(NSRect(origin: origin, size: size), display: false)
        p.contentView?.frame = NSRect(origin: .zero, size: size)
        list.frame = NSRect(origin: .zero, size: size)
        p.displayIfNeeded()
        p.orderFront(nil)
        list.needsDisplay = true
    }

    func close() {
        guard let p = panel else { return }
        host?.removeChildWindow(p)
        p.orderOut(nil)
        panel = nil
        items = []
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        list.selected = max(0, min(items.count - 1, list.selected + delta))
        if list.selected < list.offset {
            list.offset = list.selected
        }
        if list.selected >= list.offset + ListView.maxVisible {
            list.offset = list.selected - ListView.maxVisible + 1
        }
        list.needsDisplay = true
    }

    private static func makePanel(content: NSView) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        // Frosted glass (user request): the menu material behind the rows, borderless,
        // rounded — the list draws transparently on top.
        let glass = NSVisualEffectView()
        glass.material = .menu
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 8
        glass.layer?.masksToBounds = true
        glass.autoresizesSubviews = true
        content.autoresizingMask = [.width, .height]
        glass.addSubview(content)
        p.contentView = glass
        return p
    }

    /// The rows, drawn by hand: full styling control at ~zero view overhead.
    final class ListView: NSView {
        static let rowH: CGFloat = 21
        static let maxVisible = 10
        var rows: [(label: String, detail: String?)] = []
        var selected = 0
        var offset = 0 // first visible row (the selection scrolls the window)
        var accent: NSColor = .systemRed
        var onPick: ((Int) -> Void)?

        override var isFlipped: Bool {
            true
        }

        private static let labelFont = NativeNoteEditor.monoFont() // Menlo, the editor face
        private static let detailFont = NSFont(name: "Menlo", size: 10.5)
            ?? .monospacedSystemFont(ofSize: 10.5, weight: .regular)

        func idealSize() -> NSSize {
            var w: CGFloat = 160
            for r in rows {
                let lw = (r.label as NSString).size(withAttributes: [.font: Self.labelFont]).width
                let dw = r.detail.map {
                    ($0 as NSString).size(withAttributes: [.font: Self.detailFont]).width + 14
                } ?? 0
                w = max(w, lw + dw + 22)
            }
            return NSSize(width: min(w, 380),
                          height: CGFloat(min(rows.count, Self.maxVisible)) * Self.rowH)
        }

        override func draw(_ dirtyRect: NSRect) {
            // Transparent: the glass panel behind provides the surface.
            for i in offset ..< min(rows.count, offset + Self.maxVisible) {
                let y = CGFloat(i - offset) * Self.rowH
                let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowH)
                let sel = i == selected
                if sel {
                    accent.setFill()
                    rowRect.fill()
                }
                let labelColor: NSColor = sel ? .white : .labelColor
                let r = rows[i]
                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: Self.labelFont, .foregroundColor: labelColor,
                ]
                let ls = (r.label as NSString).size(withAttributes: labelAttrs)
                (r.label as NSString).draw(
                    at: NSPoint(x: 10, y: y + (Self.rowH - ls.height) / 2),
                    withAttributes: labelAttrs
                )
                if let d = r.detail {
                    let detailAttrs: [NSAttributedString.Key: Any] = [
                        .font: Self.detailFont,
                        .foregroundColor: labelColor.withAlphaComponent(sel ? 0.85 : 0.62),
                    ]
                    let ds = ("→ " + d as NSString).size(withAttributes: detailAttrs)
                    ("→ " + d as NSString).draw(
                        at: NSPoint(x: 10 + ls.width + 10, y: y + (Self.rowH - ds.height) / 2),
                        withAttributes: detailAttrs
                    )
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            let row = offset + Int(pt.y / Self.rowH)
            if row >= 0, row < rows.count {
                onPick?(row)
            }
        }
    }
}
