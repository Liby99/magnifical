// Toolbar event search (⌘F or the magnifyingglass button). The trailing button expands into a text
// field in place; as you type, a right-aligned, drawer-styled dropdown of matching events appears below
// it. ↑/↓ move the highlight, Enter flies the calendar to the selected event and selects it (a click,
// essentially), Esc closes. There's no web ground-truth for this — it's built on the engine's
// `searchEvents` / `revealAndSelect` navigate-and-highlight API.

import AppKit
import CalendarEngine
import SwiftUI

/// Shared search state — the toolbar field writes it; the dropdown overlay (a sibling in the content
/// stack, since a toolbar item can't host its own anchored menu cleanly) reads it.
@MainActor
@Observable
final class SearchState {
    var open = false // the bar is mounted (in the toolbar)
    var expanded = false // the bar is at full width (animates the expand/collapse)
    var query = ""
    var results: [CalendarEngine.SearchHit] = [] // the shown rows (≤ display cap)
    var total = 0 // total matches (may exceed results.count)
    var sel = 0
    var fieldFrame: CGRect = .zero // the bar's frame in the global space, so the dropdown can align to it
    func reset() {
        open = false; expanded = false; query = ""; results = []; total = 0; sel = 0
    }
}

/// The centered toolbar text field. Owns focus + recompute; the parent supplies commit/close so it can
/// drive the engine and hand first-responder back to the canvas.
struct SearchBar: View {
    let engine: CalendarEngine
    @Bindable var search: SearchState
    var onCommit: () -> Void
    var onClose: () -> Void
    @State private var contentIn = false // fades the field/close in once the bar has opened
    @State private var debounce: Task<Void, Never>? // coalesces fast typing before recompute

    private let collapsedWidth: CGFloat = 22 // just the magnifyingglass (button-sized)
    private let expandedWidth: CGFloat = 232 // field + close button

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if search.expanded {
                // An NSTextField (not SwiftUI TextField): a toolbar-hosted SwiftUI field won't reliably
                // become first responder via @FocusState, so ⌘F wouldn't land the caret and Esc/Enter
                // wouldn't reach it. The representable force-focuses itself and handles Esc/Enter/↑/↓ via
                // the AppKit field-editor delegate (which the global key monitor already yields to).
                // Flexible width so it fills the bar and pushes the clear button to the trailing edge.
                SearchTextField(text: $search.query, autofocus: true,
                                onMove: { move($0) }, onCommit: onCommit, onClose: onClose)
                    .frame(height: 18)
                    .frame(maxWidth: .infinity)
                    .opacity(contentIn ? 1 : 0) // fade the placeholder/caret in AFTER the bar has opened
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close search")
                .opacity(contentIn ? 1 : 0)
            }
        }
        .frame(width: search.expanded ? expandedWidth : collapsedWidth, alignment: .leading)
        // Leading inset for the magnifyingglass; the trailing inset is set to match the clear button's
        // top gap (vertical pad + its vertical centering) so its right & top margins to the edge are equal.
        .padding(.leading, 10)
        .padding(.trailing, 7.5)
        .padding(.vertical, 5)
        // Completely transparent — no pill/material behind the field; it reads as bare controls sitting
        // directly on the toolbar. The capsule clip only bounds the content while it expands.
        .clipShape(Capsule())
        // Report our frame in the window's content-view space so the dropdown (a sibling in the content
        // stack, a different view hierarchy) can pin its top-left to our bottom-left. SwiftUI's `.global`
        // isn't shared across the toolbar↔content boundary, so we bridge through AppKit window coords.
        .background(WindowRectReader { search.fieldFrame = $0 })
        .onAppear {
            // Expand from the button on mount. Collapse is driven by the parent (closeSearch) so the bar
            // stays mounted while it shrinks back, then unmounts — see CalendarView.
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { search.expanded = true }
            // Reveal the field/close only after the bar has mostly opened, so the placeholder never
            // renders (and overshoots the capsule clip) while the width is still animating.
            withAnimation(.easeOut(duration: 0.16).delay(0.18)) { contentIn = true }
            engine.primeSearch() // warm the corpus in the background so the first keystroke is fast
        }
        .onChange(of: search.expanded) { _, exp in
            if !exp {
                withAnimation(.easeOut(duration: 0.1)) { contentIn = false }
            } // collapsing → hide content first
        }
        // Debounce fast typing, then run the MATCH off the main thread (engine.search is async) so the field
        // never stutters. A newer keystroke cancels this task; a stale result (query moved on) is dropped.
        .onChange(of: search.query) { _, q in
            debounce?.cancel()
            let query = q
            debounce = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                if query.isEmpty {
                    search.results = []; search.total = 0; search.sel = 0; return
                }
                let r = await engine.search(query)
                guard !Task.isCancelled, query == search.query else { return } // drop stale results
                search.results = r.hits
                search.total = r.total
                search.sel = 0
            }
        }
        .onDisappear { debounce?.cancel() }
    }

    private func move(_ d: Int) {
        guard !search.results.isEmpty else { return }
        search.sel = min(search.results.count - 1, max(0, search.sel + d))
    }
}

/// The results dropdown, positioned top-center in the content just under the toolbar field.
struct SearchDropdown: View {
    @Bindable var search: SearchState
    let theme: Theme
    var onPick: (Int) -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            if search.results.isEmpty {
                HStack {
                    Text("No events found")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textMuted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
            } else {
                // Count header: "N matches" (with "· showing M" when capped above the display limit).
                HStack {
                    Text(search.total == 1 ? "1 match"
                        :
                        "\(search.total) matches\(search.total > search.results.count ? " · showing \(search.results.count)" : "")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textMuted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 4)
                ForEach(Array(search.results.enumerated()), id: \.element.id) { i, hit in
                    row(i, hit)
                    if i < search.results.count - 1 {
                        Rectangle().fill(theme.text.opacity(0.08)).frame(height: 1).padding(.horizontal, 8)
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 340, alignment: .leading)
        // Same card treatment as the EventDrawer: material (dark) / white (light) over the content bg.
        .background(shape.fill(theme.dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.white)))
        .background(shape.fill(theme.bg))
        .overlay(shape.strokeBorder(theme.text.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder private func row(_ i: Int, _ hit: CalendarEngine.SearchHit) -> some View {
        let active = i == search.sel
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(theme.eventBorder(hit.color))
                .frame(width: 3) // a vertical color bar spanning the row height (not a dot)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title.isEmpty ? "Untitled" : hit.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(Self.subtitle(hit))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                // Why it matched, when it's a tag or a hit inside the notes (title/date hits are self-evident).
                if !hit.context.isEmpty {
                    Text(hit.context)
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(theme.textMuted.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(active ? theme.eventBorder(hit.color).opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onPick(i) }
        .onHover {
            if $0 {
                search.sel = i
            }
        }
    }

    /// "Wed, Jul 22, 2026" plus " · 3:30 PM" for a timed event / deadline.
    static func subtitle(_ h: CalendarEngine.SearchHit) -> String {
        let cal = Calendar.current
        let date = cal.date(from: DateComponents(year: h.year, month: h.month + 1, day: h.day)) ?? Date()
        let df = DateFormatter(); df.dateFormat = "EEE, MMM d, yyyy"
        var s = df.string(from: date)
        if let hr = h.hour {
            let hh = Int(hr), mm = Int((hr - CGFloat(hh)) * 60).clamped(0, 59)
            if let t = cal.date(from: DateComponents(hour: hh, minute: mm)) {
                let tf = DateFormatter(); tf.dateFormat = "h:mm a"
                s += " · " + tf.string(from: t)
            }
        }
        return s
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int {
        Swift.min(hi, Swift.max(lo, self))
    }
}

/// Reports this view's frame in the window's content-view coordinate space (top-left origin). Unlike
/// SwiftUI's `.global`, this is consistent for any view in the same NSWindow — including toolbar items —
/// so the toolbar search bar and the content dropdown can be aligned to each other.
struct WindowRectReader: NSViewRepresentable {
    var onChange: (CGRect) -> Void
    func makeNSView(context: Context) -> Tracker {
        let v = Tracker(); v.onChange = onChange; return v
    }

    func updateNSView(_ v: Tracker, context: Context) {
        v.onChange = onChange; v.report()
    }

    final class Tracker: NSView {
        var onChange: ((CGRect) -> Void)?
        private var last: CGRect = .null
        override func viewDidMoveToWindow() {
            report()
        }

        override func layout() {
            super.layout(); report()
        }

        func report() {
            guard let content = window?.contentView else { return }
            let r = convert(bounds, to: content) // any view → content view (works across the window)
            // Normalize to top-left origin regardless of the content view's flip.
            let topLeft = content.isFlipped ? r
                : CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
            guard topLeft != last else { return } // no change → nothing to publish (avoids churn)
            last = topLeft
            // report() runs inside AppKit layout(), which fires during SwiftUI's view-update pass; mutating
            // observable state there triggers "Modifying state during view update". Defer to the next tick.
            DispatchQueue.main.async { [onChange] in onChange?(topLeft) }
        }
    }
}

/// A transparent, single-line NSTextField wrapper. Unlike a toolbar-hosted SwiftUI `TextField`, this
/// reliably grabs first responder on appear (so ⌘F starts typing immediately), and routes Esc / Enter /
/// ↑ / ↓ through the field-editor delegate to the closures. The global key monitor already yields all
/// keys once an `NSText` field editor is first responder, so these fire without interference.
struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var autofocus: Bool
    var onMove: (Int) -> Void // -1 up, +1 down
    var onCommit: () -> Void // Enter
    var onClose: () -> Void // Esc

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.backgroundColor = .clear
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 13)
        tf.placeholderString = "Search events"
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.stringValue != text {
            tf.stringValue = text
        }
        if autofocus, !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            context.coordinator.focus(tf, attempts: 12)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField
        var didFocus = false
        init(_ p: SearchTextField) {
            parent = p
        }

        /// Retry until the field is in a window and its field editor is active (a toolbar item view may
        /// not be in the responder chain the moment SwiftUI first lays it out).
        func focus(_ tf: NSTextField, attempts: Int) {
            guard attempts > 0 else { return }
            if let w = tf.window {
                w.makeFirstResponder(tf)
                if tf.currentEditor() != nil {
                    return
                } // caret is in → done
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak tf] in
                guard let tf else { return }
                self.focus(tf, attempts: attempts - 1)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.cancelOperation(_:)): parent.onClose(); return true // Esc
            case #selector(NSResponder.insertNewline(_:)): parent.onCommit(); return true // Enter
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true // ↑
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true // ↓
            default: return false
            }
        }
    }
}
