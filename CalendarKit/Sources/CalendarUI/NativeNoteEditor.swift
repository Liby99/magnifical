// The NATIVE markdown note editor (webview retirement phase 3) — an NSTextView with lightweight
// in-place markdown highlighting, replacing CodeMirror for the dashboard notepads. Notes here are
// small (the store's largest is under 1KB), so the highlighter re-attributes the WHOLE document
// per change — attribute-only edits, so the selection and undo stack are untouched. The key
// monitor already yields to NSText first responders, so typing lands here like any field editor.
//
// V1 gaps (documented): no entity autocomplete (@person/#tag/project: completions) yet — that
// rides NSTextView's completion API in a follow-up.
// created:-stamps ARE wired (session-end semantics, matching the CodeMirror editor): top-level
// task lines missing created: get " created:YYYY-MM-DDTHH:mm" appended when the editing
// SESSION ends — focus loss, panel re-key, or teardown — and only if the user actually edited
// this note since it loaded (sessionDirty), so opening/previewing never back-stamps old items.

import AppKit
import CalendarEngine
import CalendarRender
import SwiftUI

/// A tiny handle the HOST keeps so it can end the editing session from outside the
/// responder chain — the Editor/Preview toggle lives in a separate overlay (DashChrome)
/// writing the shared noteMode binding, so the panel must be able to say "stamp NOW,
/// before the preview renders" instead of waiting for the unmount hook.
@MainActor final class NoteEditSession {
    var end: (() -> Void)?
}

struct NativeNoteEditor: NSViewRepresentable {
    let storageKey: String // the note's key: "YYYY-MM-DD" / "week:…" / "month:…"
    let text: String // the engine's current note body
    /// False while this editor is a PARKED tab (mounted for warmth, SwiftUI-opacity 0):
    /// maps to NSView.isHidden — alpha-zero alone leaves the NSTextView's I-beam cursor
    /// rects live over whichever tab IS showing.
    var active = true
    let theme: Theme
    var placeholder: String
    var onText: (String) -> Void // every change → engine.setDailyNote (engine coalesces persist)
    /// ⌘S / Esc — the web editor's session-enders: stamp created:, then flip to preview /
    /// hand focus back (parity with noteEditor.ts's Mod-s / Escape keymap).
    var onSave: () -> Void = {}
    var onExit: () -> Void = {}
    var session: NoteEditSession? // host-side session-ender (mode-toggle stamping)
    /// Live entity index for @project:/@person:/bare-@/#tag completions (the web's
    /// completionIndex). nil → entity completion off; DATE completion always works.
    var completionIndex: (() -> (projects: [String], people: [String], tags: [String]))?
    /// Context anchor offered after `due:` — "this day time" in a daily note, "this event
    /// time" in the drawer (the web's dueAnchor).
    var dueAnchor: (() -> (label: String, value: String)?)?
    /// ⌘-click line focus: when set, the editor selects this 1-based line, scrolls it visible
    /// and takes focus (once per value; the host clears it via onFocusLineHandled).
    var focusLine: Int?
    var onFocusLineHandled: () -> Void = {}
    /// Bump → take keyboard focus (the drawer's notes ring / ⌘E entry), caret left in place.
    var focusPulse: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.popup.close()
        coordinator.stampCreatedIfDirty() // teardown (mode flip / drawer close) ends the session
    }

    /// NSTextView subclass owning the editor-local key equivalents. performKeyEquivalent (not
    /// the app key monitor): the monitor deliberately steps aside for text first responders,
    /// and ⌘S must work exactly and only while this editor is focused.
    final class EditorTextView: NSTextView {
        var onSaveKey: (() -> Void)?
        var onEscKey: (() -> Void)?
        var placeholderText = ""
        var themeText: NSColor = .labelColor

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "s" {
                onSaveKey?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func cancelOperation(_ sender: Any?) { // Esc: completion first, then exit
            if completionVisible?() == true {
                completionCancel?()
            } else {
                onEscKey?()
            }
        }

        /// ── Active line: a slight full-width wash behind the caret's line (the ruler bolds
        /// its number to match). Selection changes trigger redraw via the coordinator.
        override func drawBackground(in rect: NSRect) {
            super.drawBackground(in: rect)
            guard let lm = layoutManager, let tc = textContainer else { return }
            guard selectedRange().length == 0 else { return } // caret only — the gutter matches
            let ns = string as NSString
            var frag: NSRect
            let sel = min(selectedRange().location, ns.length)
            if ns.length == 0 || (sel >= ns.length && ns.hasSuffix("\n")) {
                frag = lm.extraLineFragmentRect
                if frag.height <= 0 {
                    return
                }
            } else {
                var line = ns.lineRange(for: NSRange(location: sel, length: 0))
                // Exclude the trailing newline: its glyph maps into the NEXT fragment's
                // bounding box, which washed the line below too (the reported artifact).
                if line.length > 0, ns.character(at: NSMaxRange(line) - 1) == 0x0A {
                    line.length -= 1
                }
                if line.length == 0 { // blank line: no glyph box — use its fragment directly
                    let gr = lm.glyphRange(forCharacterRange: NSRange(location: line.location, length: 1),
                                           actualCharacterRange: nil)
                    frag = lm.lineFragmentRect(forGlyphAt: min(gr.location, max(0, lm.numberOfGlyphs - 1)),
                                               effectiveRange: nil)
                } else {
                    let gr = lm.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
                    frag = lm.boundingRect(forGlyphRange: gr, in: tc)
                }
            }
            var r = frag
            r.origin.x = 0
            r.size.width = bounds.width
            r.origin.y += textContainerInset.height
            themeText.withAlphaComponent(0.05).setFill()
            // Rounded RIGHT corners; the square left edge continues into the gutter's band.
            NativeNoteEditor.washPath(r, radius: 6, roundLeft: false, roundRight: true).fill()
        }

        /// ── Placeholder (CodeMirror's cmPlaceholder): grey hint while the note is empty ──
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholderText.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NativeNoteEditor.monoFont(),
                .foregroundColor: themeText.withAlphaComponent(0.35),
            ]
            let size = (placeholderText as NSString).size(withAttributes: attrs)
            (placeholderText as NSString).draw(
                at: NSPoint(x: textContainerInset.width + 3,
                            y: textContainerInset.height
                                + (NativeNoteEditor.lineHeight - size.height) / 2),
                withAttributes: attrs
            )
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true // placeholder appears/disappears with emptiness
        }

        /// ── ⌥↑ / ⌥↓ line rearrangement (defaultKeymap's moveLineUp/Down) ──
        override func keyDown(with event: NSEvent) {
            // Arrow keys carry hidden .function/.numericPad flags — intersect with just the
            // four real modifiers or "⌥ alone" never matches (⌥↑/⌥↓ silently did nothing).
            let mods = event.modifierFlags.intersection([.option, .command, .shift, .control])
            if mods == .option, event.keyCode == 126 {
                moveLines(up: true); return
            }
            if mods == .option, event.keyCode == 125 {
                moveLines(up: false); return
            }
            super.keyDown(with: event)
        }

        /// Swap the line block containing the selection with its neighbor, keeping the
        /// selection glued to the moved text — CodeMirror's moveLineUp/Down semantics.
        private func moveLines(up: Bool) {
            let ns = string as NSString
            let sel = selectedRange()
            let block = ns.lineRange(for: sel) // full line(s) incl. trailing \n
            if up {
                guard block.location > 0 else { NSSound.beep(); return }
                let prev = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
                let blockText = ns.substring(with: block)
                let prevText = ns.substring(with: prev)
                // Both keep their own trailing newlines EXCEPT when the moving block is the
                // last line (no \n) — normalize so the join stays well-formed.
                var newBlock = blockText, newPrev = prevText
                if !newBlock.hasSuffix("\n") {
                    newBlock += "\n"
                    newPrev = String(newPrev.dropLast(newPrev.hasSuffix("\n") ? 1 : 0))
                }
                let whole = NSRange(location: prev.location, length: prev.length + block.length)
                replace(whole, with: newBlock + newPrev,
                        selectDelta: prev.location - block.location, sel: sel)
            } else {
                let end = block.location + block.length
                guard end < ns.length else { NSSound.beep(); return }
                let next = ns.lineRange(for: NSRange(location: end, length: 0))
                var blockText = ns.substring(with: block)
                var nextText = ns.substring(with: next)
                if !nextText.hasSuffix("\n") { // moving past the (newline-less) last line
                    nextText += "\n"
                    blockText = String(blockText.dropLast())
                }
                let whole = NSRange(location: block.location, length: block.length + next.length)
                replace(whole, with: nextText + blockText,
                        selectDelta: next.length, sel: sel)
            }
        }

        private func replace(_ range: NSRange, with str: String, selectDelta: Int, sel: NSRange) {
            guard shouldChangeText(in: range, replacementString: str) else { return }
            textStorage?.replaceCharacters(in: range, with: str)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + selectDelta, length: sel.length))
            scrollRangeToVisible(selectedRange())
        }

        // ── Autocomplete popup hooks (the custom panel replaces NSTextView's machinery) ──
        var completionVisible: (() -> Bool)?
        var completionCancel: (() -> Void)?

        /// ── ⌘-click a markdown/bare link opens it (the web's openLinks handler) ──
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command) {
                let pt = convert(event.locationInWindow, from: nil)
                let idx = characterIndexForInsertion(at: pt)
                if let url = NativeNoteEditor.linkAt(string, index: idx) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
            super.mouseDown(with: event)
        }
    }

    /// A rect rounded on selected SIDES only — the active-line band rounds its outer corners
    /// (left in the gutter, right in the text) while the shared seam stays square.
    static func washPath(_ r: NSRect, radius: CGFloat, roundLeft: Bool, roundRight: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        let rad = min(radius, r.height / 2)
        if roundLeft {
            p.move(to: NSPoint(x: r.minX + rad, y: r.minY))
        } else {
            p.move(to: NSPoint(x: r.minX, y: r.minY))
        }
        if roundRight {
            p.line(to: NSPoint(x: r.maxX - rad, y: r.minY))
            p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.minY + rad), radius: rad,
                        startAngle: -90, endAngle: 0)
            p.line(to: NSPoint(x: r.maxX, y: r.maxY - rad))
            p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad,
                        startAngle: 0, endAngle: 90)
        } else {
            p.line(to: NSPoint(x: r.maxX, y: r.minY))
            p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        }
        if roundLeft {
            p.line(to: NSPoint(x: r.minX + rad, y: r.maxY))
            p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad,
                        startAngle: 90, endAngle: 180)
            p.line(to: NSPoint(x: r.minX, y: r.minY + rad))
            p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.minY + rad), radius: rad,
                        startAngle: 180, endAngle: 270)
        } else {
            p.line(to: NSPoint(x: r.minX, y: r.maxY))
        }
        p.close()
        return p
    }

    /// The house editor face: Menlo (user preference), CodeMirror's 13px.
    static func monoFont(bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Menlo-Bold" : "Menlo", size: 12.5)
            ?? .monospacedSystemFont(ofSize: 12.5, weight: bold ? .bold : .regular)
    }

    /// ONE line grid for everything (content, typing attributes, ruler): a FIXED fragment
    /// height with the glyphs re-centered via baselineOffset. TextKit parks glyphs at the
    /// BOTTOM of an enlarged fragment (that was the "text hugs the bottom of its highlight" +
    /// "numbers misaligned" + "last line a different height" cluster — the extra/typing
    /// fragments never even got the paragraph style). Fixed + centered kills the whole class.
    static let lineHeight: CGFloat = 19
    static let baselineShift: CGFloat = {
        let lm = NSLayoutManager()
        return ((lineHeight - lm.defaultLineHeight(for: monoFont())) / 2).rounded()
    }()

    static func editorParagraphStyle() -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        return para
    }

    static func baseAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: monoFont(), .foregroundColor: color,
         .paragraphStyle: editorParagraphStyle(), .baselineOffset: baselineShift]
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = EditorTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 10, height: 6) // gap after the ruler hairline
        tv.placeholderText = placeholder
        tv.themeText = NSColor(theme.text)
        // Selection in the ACCENT (the web's 24% highlight), caret in the text color — not
        // the system blue.
        tv.selectedTextAttributes = [
            .backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.24),
        ]
        tv.insertionPointColor = NSColor(theme.text)
        tv.typingAttributes = NativeNoteEditor.baseAttributes(NSColor(theme.text))
        tv.defaultParagraphStyle = NativeNoteEditor.editorParagraphStyle()
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.onSaveKey = { [weak co = context.coordinator] in
            co?.stampCreatedIfDirty()
            co?.parent.onSave()
        }
        tv.onEscKey = { [weak co = context.coordinator] in
            co?.stampCreatedIfDirty()
            co?.parent.onExit()
        }
        tv.completionVisible = { [weak co = context.coordinator] in co?.popup.active ?? false }
        tv.completionCancel = { [weak co = context.coordinator] in co?.popup.close() }
        session?.end = { [weak co = context.coordinator] in co?.stampCreatedIfDirty() }
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.key = storageKey
        context.coordinator.highlight()

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = LineNumberRuler(textView: tv, scroll: scroll)
        scroll.rulersVisible = true
        // Scrolling moves the caret's screen anchor — retarget (or close) the popup.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
            queue: .main
        ) { [weak co = context.coordinator] _ in
            MainActor.assumeIsolated {
                if co?.popup.active == true {
                    co?.refreshCompletions()
                }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.isHidden = !active // parked tab: dormant cursor rects (see `active`)
        let co = context.coordinator
        session?.end = { [weak co] in co?.stampCreatedIfDirty() } // keep the handle fresh
        // Re-key = the previous note's editing session ENDS: stamp it through the OLD parent's
        // onText (still bound to the old storage key) BEFORE adopting the new identity.
        if co.key != storageKey {
            co.stampCreatedIfDirty()
        }
        co.parent = self
        guard let tv = co.textView else { return }
        (tv as? EditorTextView)?.placeholderText = placeholder
        // Adopt external text when the note IDENTITY changed (panel re-keyed), or the engine's
        // copy diverged while the editor isn't the one typing (a checkbox toggle elsewhere
        // rewrote this note). Never clobber the user's in-flight keystrokes: our own edits round
        // back as `text` == lastSent.
        if co.key != storageKey {
            co.key = storageKey
            co.lastSent = nil
            co.sessionDirty = false // a host-driven swap starts a fresh session
            tv.string = text
            co.highlight()
            tv.scroll(.zero)
        } else if text != tv.string, text != co.lastSent {
            tv.string = text
            co.highlight()
        }
        if focusPulse != co.lastFocusPulse {
            co.lastFocusPulse = focusPulse
            DispatchQueue.main.async { [weak tv] in
                if let tv {
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }
        // ⌘-click "edit here": select the requested line, reveal it, take focus. Off the
        // update pass (window/first-responder work), deduped per request.
        if let line = focusLine, co.handledFocusLine != line {
            co.handledFocusLine = line
            let handled = onFocusLineHandled
            DispatchQueue.main.async { [weak tv, weak co] in
                guard let tv else { return }
                let ns = tv.string as NSString
                var loc = 0, n = 1
                var range = NSRange(location: 0, length: 0)
                while true {
                    let lineEnd = ns.range(of: "\n", range: NSRange(location: loc, length: ns.length - loc))
                    let end = lineEnd.location == NSNotFound ? ns.length : lineEnd.location
                    if n == line {
                        range = NSRange(location: loc, length: end - loc); break
                    }
                    if lineEnd.location == NSNotFound {
                        range = NSRange(location: end, length: 0); break
                    }
                    loc = lineEnd.location + 1
                    n += 1
                }
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
                co?.handledFocusLine = nil
                handled()
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeNoteEditor
        weak var textView: NSTextView?
        var key = ""
        var lastSent: String? // the last body we pushed up — its echo must not re-set the view
        var sessionDirty = false // the user edited THIS note since load / last stamp
        var handledFocusLine: Int? // last ⌘-click focus request already applied (dedup)
        var lastFocusPulse = 0

        init(_ parent: NativeNoteEditor) {
            self.parent = parent
        }

        /// CodeMirror's insertNewlineContinueMarkup + indentMore/indentLess, natively:
        /// Enter inside a todo/bullet/ordered/quote line continues the marker ("- [ ] " fresh
        /// and unchecked, numbers incremented); Enter on an EMPTY marker clears it (ends the
        /// list); Tab/⇧Tab indent/outdent the selected line(s) by two spaces.
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if popup.active {
                switch sel {
                case #selector(NSResponder.moveDown(_:)):
                    popup.move(1); return true
                case #selector(NSResponder.moveUp(_:)):
                    popup.move(-1); return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    acceptCompletion(popup.selected); return true
                case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
                    popup.close() // caret leaves the trigger — let the arrow through
                default:
                    break
                }
            }
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                return continueMarkup(tv)
            case #selector(NSResponder.insertTab(_:)):
                return indent(tv, out: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return indent(tv, out: true)
            default:
                return false
            }
        }

        private static let markerRe = try! NSRegularExpression(
            pattern: #"^(\s*)(?:([-*+])\s+\[[ xX]\]\s*|([-*+])\s+|(\d+)([.)])\s+|(>)\s*)(.*)$"#
        )

        private func continueMarkup(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            var lineText = ns.substring(with: line)
            if lineText.hasSuffix("\n") {
                lineText.removeLast()
            }
            let lineNS = lineText as NSString
            guard let m = Self.markerRe.firstMatch(
                in: lineText, range: NSRange(location: 0, length: lineNS.length)
            )
            else { return false } // plain line → default newline
            let rest = lineNS.substring(with: m.range(at: 7))
            let indent = lineNS.substring(with: m.range(at: 1))
            // Empty item + Enter = end the list: clear the marker, leave a blank line.
            if rest.trimmingCharacters(in: .whitespaces).isEmpty, sel.length == 0,
               sel.location >= line.location + lineNS.length {
                let content = NSRange(location: line.location,
                                      length: min(lineNS.length, line.length))
                guard tv.shouldChangeText(in: content, replacementString: indent) else { return true }
                tv.textStorage?.replaceCharacters(in: content, with: indent)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: line.location + (indent as NSString).length,
                                            length: 0))
                return true
            }
            var prefix: String
            if m.range(at: 2).location != NSNotFound { // todo → fresh unchecked box
                prefix = indent + lineNS.substring(with: m.range(at: 2)) + " [ ] "
            } else if m.range(at: 3).location != NSNotFound { // bullet
                prefix = indent + lineNS.substring(with: m.range(at: 3)) + " "
            } else if m.range(at: 4).location != NSNotFound { // ordered → n+1
                let n = (Int(lineNS.substring(with: m.range(at: 4))) ?? 0) + 1
                prefix = indent + String(n) + lineNS.substring(with: m.range(at: 5)) + " "
            } else { // quote
                prefix = indent + "> "
            }
            let insert = "\n" + prefix
            guard tv.shouldChangeText(in: sel, replacementString: insert) else { return true }
            tv.textStorage?.replaceCharacters(in: sel, with: insert)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: sel.location + (insert as NSString).length,
                                        length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
            return true
        }

        private func indent(_ tv: NSTextView, out: Bool) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let block = ns.lineRange(for: sel)
            let text = ns.substring(with: block)
            var lines = text.components(separatedBy: "\n")
            let trailing = lines.last == "" // block ends with \n → empty tail element
            if trailing {
                lines.removeLast()
            }
            var firstDelta = 0
            var total = 0
            for i in lines.indices {
                if out {
                    let drop = min(2, lines[i].prefix(2).prefix(while: { $0 == " " }).count)
                    lines[i] = String(lines[i].dropFirst(drop))
                    if i == 0 {
                        firstDelta = -drop
                    }
                    total -= drop
                } else {
                    lines[i] = "  " + lines[i]
                    if i == 0 {
                        firstDelta = 2
                    }
                    total += 2
                }
            }
            let next = lines.joined(separator: "\n") + (trailing ? "\n" : "")
            guard next != text else { return true }
            guard tv.shouldChangeText(in: block, replacementString: next) else { return true }
            tv.textStorage?.replaceCharacters(in: block, with: next)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: max(block.location, sel.location + firstDelta),
                                        length: max(0, sel.length + total - firstDelta)))
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let s = tv.string
            lastSent = s
            sessionDirty = true
            parent.onText(s)
            highlight()
            if suppressCompletionOnce {
                suppressCompletionOnce = false
                popup.close()
            } else {
                refreshCompletions()
            }
        }

        // ── The custom completion session (the web-styled CompletionPopup) ──
        let popup = CompletionPopup()
        var suppressCompletionOnce = false // an accepted entity must not instantly re-list

        /// Recompute trigger + options at the caret; show/refresh or close the popup.
        func refreshCompletions() {
            guard let tv = textView, let win = tv.window, win.firstResponder === tv,
                  let t = NativeNoteEditor.completionTrigger(in: tv)
            else { popup.close(); return }
            let options = NativeNoteEditor.completionOptions(
                for: t, index: parent.completionIndex?(), dueAnchor: parent.dueAnchor?() ?? nil
            )
            guard !options.isEmpty else { popup.close(); return }
            let anchor = tv.firstRect(
                forCharacterRange: NSRange(location: t.partialRange.location, length: 0),
                actualRange: nil
            )
            popup.onPick = { [weak self] row in self?.acceptCompletion(row) }
            popup.update(items: options, accent: NSColor(Theme.accent), anchor: anchor, host: win)
        }

        func acceptCompletion(_ row: Int) {
            guard let tv = textView, row < popup.items.count,
                  let t = NativeNoteEditor.completionTrigger(in: tv) else { popup.close(); return }
            let item = popup.items[row]
            let value = item.range(of: " → ").map { String(item[$0.upperBound...]) } ?? item
            popup.close()
            // Reopeners ("project:"/"person:") re-list their keys via the normal refresh;
            // anything else suppresses the immediate re-list of the just-accepted text.
            suppressCompletionOnce = !value.hasSuffix(":")
            guard tv.shouldChangeText(in: t.partialRange, replacementString: value) else { return }
            tv.textStorage?.replaceCharacters(in: t.partialRange, with: value)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: t.partialRange.location + (value as NSString).length,
                                        length: 0))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.needsDisplay = true // active-line wash follows the caret
            if popup.active {
                refreshCompletions()
            } // caret out of the trigger → closes
        }

        func textDidEndEditing(_ notification: Notification) {
            popup.close()
            stampCreatedIfDirty() // focus left the editor → the session is over
        }

        /// The CodeMirror editor's stampCreated(), ported: append " created:YYYY-MM-DDTHH:mm"
        /// to top-level task lines that lack one — only when the session actually edited the
        /// note. Runs the rewrite through the same onText path as typing, so persistence,
        /// gen bumps, and the native panels all see it like any other edit.
        func stampCreatedIfDirty() {
            guard sessionDirty, let tv = textView else { return }
            sessionDirty = false // clear FIRST: the rewrite below re-fires textDidChange
            let body = tv.string
            let lines = TodoIndex.linesNeedingCreated(body)
            guard !lines.isEmpty else { return }
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                    from: Date())
            let stamp = String(format: " created:%04d-%02d-%02dT%02d:%02d",
                               c.year ?? 2000, c.month ?? 1, c.day ?? 1,
                               c.hour ?? 0, c.minute ?? 0)
            var rows = body.components(separatedBy: "\n")
            for n in lines where n >= 1 && n <= rows.count { // 1-based line numbers
                var line = rows[n - 1]
                while line.hasSuffix(" ") || line.hasSuffix("\t") {
                    line.removeLast()
                }
                rows[n - 1] = line + stamp
            }
            let next = rows.joined(separator: "\n")
            guard next != body else { return }
            let sel = tv.selectedRange()
            tv.string = next
            tv.setSelectedRange(NSRange(location: min(sel.location, (next as NSString).length),
                                        length: 0))
            lastSent = next
            parent.onText(next)
            highlight()
            sessionDirty = false // the programmatic rewrite must not re-arm the session
        }

        // ── Highlighting: full-document, attribute-only (selection + undo untouched) ─────────
        // Inline spans (the web's mdHighlight tags): **strong**, *em*/_em_, ~~strike~~,
        // `code`, and "> " quote lines in grey italic — markers stay visible (source view),
        // styled dim like CodeMirror's processingInstruction tag.
        private static let headRe = Re2(#"^#{1,6} .*$"#)
        private static let taskRe = Re2(#"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]"#)
        private static let doneLineRe = Re2(#"^\s*(?:[-*+]|\d+[.)])\s+\[[xX]\].*$"#)
        private static let tokenRe = Re2(
            #"(^|\s)(due:\S+|start:\S+|tz:\S+|color:\S+|done:\S+|created:\S+|followup:\S+|p:!{1,5}|#[A-Za-z0-9_][\w-]*|@[A-Za-z0-9_][\w:-]*|project:[A-Za-z0-9_-]+)(?=\s|$)"#
        )
        private static let linkRe = Re2(#"\[[^\]]*\]\([^)\s]+\)"#)
        private static let boldRe = Re2(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#)
        private static let emRe = Re2(#"(?<![*_\w])(\*|_)(?![*_\s])[^*_\n]+\1(?![*_\w])"#)
        private static let strikeSpanRe = Re2(#"~~[^~\n]+~~"#)
        private static let codeSpanRe = Re2(#"`[^`\n]+`"#)
        private static let quoteLineRe = Re2(#"^\s*> .*$"#)

        func highlight() {
            NativeDash.diagTime("editorHighlight") { highlightBody() }
        }

        private func highlightBody() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let s = tv.string as NSString
            let all = NSRange(location: 0, length: s.length)
            let base = NSColor(parent.theme.text)
            let dim = base.withAlphaComponent(0.45)
            let accent = NSColor(Theme.accent)
            storage.beginEditing()
            storage.setAttributes(NativeNoteEditor.baseAttributes(base), range: all)
            s.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                let line = s.substring(with: lineRange)
                if Coordinator.headRe.matches(line) {
                    storage.addAttribute(.font, value: NativeNoteEditor.monoFont(bold: true),
                                         range: lineRange)
                }
                if Coordinator.doneLineRe.matches(line) {
                    storage.addAttributes([
                        .foregroundColor: dim,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ], range: lineRange)
                }
                for r in Coordinator.taskRe.ranges(line) {
                    storage.addAttribute(.foregroundColor, value: accent,
                                         range: NSRange(location: lineRange.location + r.location,
                                                        length: r.length))
                }
                for r in Coordinator.tokenRe.ranges(line) {
                    storage.addAttribute(.foregroundColor, value: dim,
                                         range: NSRange(location: lineRange.location + r.location,
                                                        length: r.length))
                }
                for r in Coordinator.linkRe.ranges(line) {
                    storage.addAttribute(.foregroundColor, value: accent,
                                         range: NSRange(location: lineRange.location + r.location,
                                                        length: r.length))
                }
                let at = { (r: NSRange) in
                    NSRange(location: lineRange.location + r.location, length: r.length)
                }
                if Coordinator.quoteLineRe.matches(line) {
                    storage.addAttributes([
                        .foregroundColor: base.withAlphaComponent(0.6),
                        .obliqueness: 0.18, // Menlo has no true italic face — synthesized slant
                    ], range: lineRange)
                }
                for r in Coordinator.boldRe.ranges(line) {
                    storage.addAttribute(.font, value: NativeNoteEditor.monoFont(bold: true),
                                         range: at(r))
                }
                for r in Coordinator.emRe.ranges(line) {
                    storage.addAttribute(.obliqueness, value: 0.18, range: at(r))
                }
                for r in Coordinator.strikeSpanRe.ranges(line) {
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: at(r))
                }
                for r in Coordinator.codeSpanRe.ranges(line) {
                    storage.addAttributes([
                        .foregroundColor: base.withAlphaComponent(0.85),
                        .backgroundColor: base.withAlphaComponent(0.07),
                    ], range: at(r))
                }
            }
            storage.endEditing()
        }
    }
}

/// Tiny NSRegularExpression wrapper for the highlighter (anchors evaluated per line).
private struct Re2 {
    let rx: NSRegularExpression
    init(_ pattern: String) {
        // Compile-time literals, exercised by every highlight pass.
        // swiftlint:disable:next force_try
        rx = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    func matches(_ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    func ranges(_ s: String) -> [NSRange] {
        rx.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            .map(\.range)
    }
}
