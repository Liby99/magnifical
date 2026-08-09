// NativeNoteEditor's line-number ruler: gutter numbers in the editor face + the active-line
// wash band continuing into the gutter.
// Split from NativeNoteEditor.swift (audit round, 2026-08-02).

import AppKit

extension NativeNoteEditor {
    /// Line numbers in the left ruler — same Menlo face and per-fragment BASELINE alignment
    /// as the content (identical font ⇒ identical line pitch); the current line's number is
    /// bold + brighter, matching the text view's active-line wash; trailing empty lines get
    /// numbers via the layout manager's extra line fragment; the separator hairline spans only
    /// the numbered region, not the whole panel.
    final class LineNumberRuler: NSRulerView {
        weak var tv: NSTextView?
        /// Gutter separator line opacity — trial-hidden at 0 (was 0.12); see draw(_:).
        var sepAlpha: CGFloat = 0

        init(textView: NSTextView, scroll: NSScrollView) {
            tv = textView
            super.init(scrollView: scroll, orientation: .verticalRuler)
            clientView = textView
            ruleThickness = 34
            // NSView.clipsToBounds defaults to FALSE since macOS 14: when the fragment walk
            // overshoots the visible range mid-scroll, a number drawn just past the ruler's
            // top/bottom edge lands OUTSIDE the view — in a region no view ever repaints — and
            // the stale digits float there forever (the "ghost line numbers above/below the
            // gutter" bug: a 62-line note showing an inert 14 above and 51 below).
            clipsToBounds = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidate),
                name: NSText.didChangeNotification, object: textView
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidate),
                name: NSTextView.didChangeSelectionNotification, object: textView
            )
        }

        @available(*, unavailable) required init(coder: NSCoder) {
            fatalError()
        }

        @objc private func invalidate() {
            needsDisplay = true
        }

        /// No super.draw: NSRulerView's default chrome paints a full-height background +
        /// separator; we own the drawing entirely.
        override func draw(_ dirtyRect: NSRect) {
            drawHashMarksAndLabels(in: dirtyRect)
        }

        override var isFlipped: Bool {
            true
        }

        override func drawHashMarksAndLabels(in rect: NSRect) {
            guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let ns = tv.string as NSString
            let font = NativeNoteEditor.monoFont()
            let boldFont = NativeNoteEditor.monoFont(bold: true)
            let base = (tv as? EditorTextView)?.themeText ?? .labelColor
            let dimC = base.withAlphaComponent(0.28)
            let hiC = base.withAlphaComponent(0.8)

            // Highlight EVERY line the selection touches (multi-line selections included).
            let sel = tv.selectedRange()
            let selStart = min(sel.location, ns.length)
            let selEnd = min(NSMaxRange(sel), ns.length)
            var firstLine = 1
            if ns.length > 0 {
                for unicodeScalar in ns.substring(to: selStart).unicodeScalars {
                    if unicodeScalar == "\n" {
                        firstLine += 1
                    }
                }
            }
            var lastLine = firstLine
            if selEnd > selStart {
                ns.substring(with: NSRange(location: selStart, length: selEnd - selStart))
                    .unicodeScalars.forEach {
                        if $0 == "\n" {
                            lastLine += 1
                        }
                    }
                if selEnd > 0, ns.character(at: selEnd - 1) == 0x0A {
                    lastLine -= 1
                }
            }

            // A fragment's y in RULER coordinates, via convert() — NO assumptions about how
            // the ruler's space relates to the scrolled text view (hand-derived offsets put
            // stray numbers above the top / below the bottom on long notes).
            let inset = tv.textContainerInset.height
            func rulerY(_ fragRect: NSRect) -> CGFloat {
                convert(NSPoint(x: 0, y: fragRect.minY + inset), from: tv).y
            }

            /// The caret line's wash continues INTO the gutter (one band across ruler + text).
            func washIfCurrent(_ n: Int, top: CGFloat, height: CGFloat) {
                guard n == firstLine, sel.length == 0 else { return } // matches the text view's wash
                base.withAlphaComponent(0.05).setFill()
                // Rounded LEFT corners; the square right edge continues into the text's band.
                NativeNoteEditor.washPath(NSRect(x: 0, y: top, width: ruleThickness, height: height),
                                          radius: 6, roundLeft: true, roundRight: false).fill()
            }

            func draw(_ n: Int, fragTop: CGFloat, fragHeight: CGFloat) {
                let y0 = fragTop
                guard y0 > -fragHeight, y0 < bounds.height + fragHeight else { return }
                let cur = n >= firstLine && n <= lastLine
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: cur ? boldFont : font,
                    .foregroundColor: cur ? hiC : dimC,
                ]
                let label = "\(n)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8,
                                       y: y0 + (fragHeight - size.height) / 2),
                           withAttributes: attrs)
            }

            // Walk ONLY the visible lines: visible rect → glyph range → line starts. This is
            // both correct on long notes (no stale fragments for un-laid tail glyphs, which
            // duplicated the last number) and cheap (no full-document layout per draw).
            var visText = tv.visibleRect
            visText.origin.y -= inset
            let glyphs = lm.glyphRange(forBoundingRect: visText, in: tc)
            if ns.length > 0, glyphs.length > 0 {
                let charRange = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                var charIdx = ns.lineRange(
                    for: NSRange(location: min(charRange.location, ns.length - 1), length: 0)
                ).location
                var lineNo = 1
                for unicodeScalar in ns.substring(to: charIdx).unicodeScalars {
                    if unicodeScalar == "\n" {
                        lineNo += 1
                    }
                }
                let stop = min(ns.length, NSMaxRange(charRange))
                while charIdx < stop {
                    let lineRange = ns.lineRange(for: NSRange(location: charIdx, length: 0))
                    let gr = lm.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0),
                                           actualCharacterRange: nil)
                    let gi = min(gr.location, max(0, lm.numberOfGlyphs - 1))
                    let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
                    if lineNo == firstLine {
                        // Wash the WHOLE logical line's fragments (wrapped lines included),
                        // matching the text view's band height exactly.
                        var lr = lineRange
                        if lr.length > 0, ns.character(at: NSMaxRange(lr) - 1) == 0x0A {
                            lr.length -= 1
                        }
                        var union = frag
                        if lr.length > 0 {
                            let g = lm.glyphRange(forCharacterRange: lr, actualCharacterRange: nil)
                            var u = NSRect.null
                            lm.enumerateLineFragments(forGlyphRange: g) { f, _, _, _, _ in
                                u = u.union(f)
                            }
                            if !u.isNull {
                                union = u
                            }
                        }
                        washIfCurrent(lineNo, top: rulerY(union), height: union.height)
                    }
                    draw(lineNo, fragTop: rulerY(frag), fragHeight: frag.height)
                    charIdx = NSMaxRange(lineRange)
                    lineNo += 1
                }
                // The trailing empty line (doc ends with \n): numbered at the extra fragment,
                // only when that fragment is actually the next line after the visible walk.
                if ns.hasSuffix("\n"), stop >= ns.length {
                    let extra = lm.extraLineFragmentRect
                    if extra.height > 0 {
                        washIfCurrent(lineNo, top: rulerY(extra), height: extra.height)
                        draw(lineNo, fragTop: rulerY(extra), fragHeight: extra.height)
                    }
                }
            } else if ns.length == 0 {
                let extra = lm.extraLineFragmentRect
                if extra.height > 0 {
                    washIfCurrent(1, top: rulerY(extra), height: extra.height)
                    draw(1, fragTop: rulerY(extra), fragHeight: extra.height)
                }
            }

            // Separator TRIAL-HIDDEN (sepAlpha 0 — user prefers the bare gutter); geometry via
            // the same converted coords if ever restored. (A stored property, not a local `let`,
            // so the compiler doesn't constant-fold the branch away and warn.)
            if sepAlpha > 0 {
                let extra = lm.extraLineFragmentRect
                let usedMax = max(lm.usedRect(for: tc).maxY, extra.height > 0 ? extra.maxY : 0)
                let top = max(0, convert(NSPoint(x: 0, y: inset), from: tv).y)
                let bottom = min(bounds.height, convert(NSPoint(x: 0, y: usedMax + inset), from: tv).y)
                base.withAlphaComponent(sepAlpha).setFill()
                NSRect(x: ruleThickness - 1, y: top, width: 1,
                       height: max(0, bottom - top)).fill()
            }
        }
    }
}
