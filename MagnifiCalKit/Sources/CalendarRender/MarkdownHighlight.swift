// The markdown SOURCE-VIEW styling shared by the note editor (NativeNoteEditor) and the TODO
// row's inline line editor (TodoLineEditor): the house mono face, the fixed line grid, and the
// per-line highlight rules — one source so the row editor IS the note editor's look. Extracted
// from NativeNoteEditor.Coordinator (CalendarUI), which now applies these spans line by line.
// macOS-only: CalendarRender also compiles for the read-only iPhone client, which edits nothing.

#if os(macOS)
    import AppKit

    public enum MarkdownHighlight {
        /// The house editor face: Menlo (user preference), CodeMirror's 13px.
        public static func monoFont(bold: Bool = false) -> NSFont {
            NSFont(name: bold ? "Menlo-Bold" : "Menlo", size: 12.5)
                ?? .monospacedSystemFont(ofSize: 12.5, weight: bold ? .bold : .regular)
        }

        /// ONE line grid for everything (content, typing attributes, ruler): a FIXED fragment
        /// height with the glyphs re-centered via baselineOffset. TextKit parks glyphs at the
        /// BOTTOM of an enlarged fragment (that was the "text hugs the bottom of its highlight" +
        /// "numbers misaligned" + "last line a different height" cluster — the extra/typing
        /// fragments never even got the paragraph style). Fixed + centered kills the whole class.
        public static let lineHeight: CGFloat = 19
        public static let baselineShift: CGFloat = {
            let lm = NSLayoutManager()
            return ((lineHeight - lm.defaultLineHeight(for: monoFont())) / 2).rounded()
        }()

        public static func editorParagraphStyle() -> NSMutableParagraphStyle {
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = lineHeight
            para.maximumLineHeight = lineHeight
            return para
        }

        public static func baseAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
            [.font: monoFont(), .foregroundColor: color,
             .paragraphStyle: editorParagraphStyle(), .baselineOffset: baselineShift]
        }

        // ── Highlight rules: attribute-only, markers stay visible (source view) ──────────────
        // Inline spans (the web's mdHighlight tags): **strong**, *em*/_em_, ~~strike~~,
        // `code`, and "> " quote lines in grey italic — styled dim like CodeMirror's
        // processingInstruction tag.
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

        /// The highlight spans for ONE line of the document — LINE-relative UTF-16 ranges with
        /// the attributes to ADD over the base, in application order (later spans win where they
        /// overlap, exactly the note editor's original pass).
        public static func lineSpans(_ line: String, base: NSColor, accent: NSColor)
            -> [(NSRange, [NSAttributedString.Key: Any])] {
            var out: [(NSRange, [NSAttributedString.Key: Any])] = []
            let whole = NSRange(location: 0, length: (line as NSString).length)
            let dim = base.withAlphaComponent(0.45)
            if headRe.matches(line) {
                out.append((whole, [.font: monoFont(bold: true)]))
            }
            if doneLineRe.matches(line) {
                out.append((whole, [
                    .foregroundColor: dim,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ]))
            }
            for r in taskRe.ranges(line) {
                out.append((r, [.foregroundColor: accent]))
            }
            for r in tokenRe.ranges(line) {
                out.append((r, [.foregroundColor: dim]))
            }
            for r in linkRe.ranges(line) {
                out.append((r, [.foregroundColor: accent]))
            }
            if quoteLineRe.matches(line) {
                out.append((whole, [
                    .foregroundColor: base.withAlphaComponent(0.6),
                    .obliqueness: 0.18, // Menlo has no true italic face — synthesized slant
                ]))
            }
            for r in boldRe.ranges(line) {
                out.append((r, [.font: monoFont(bold: true)]))
            }
            for r in emRe.ranges(line) {
                out.append((r, [.obliqueness: 0.18]))
            }
            for r in strikeSpanRe.ranges(line) {
                out.append((r, [.strikethroughStyle: NSUnderlineStyle.single.rawValue]))
            }
            for r in codeSpanRe.ranges(line) {
                out.append((r, [
                    .foregroundColor: base.withAlphaComponent(0.85),
                    .backgroundColor: base.withAlphaComponent(0.07),
                ]))
            }
            return out
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
#endif
