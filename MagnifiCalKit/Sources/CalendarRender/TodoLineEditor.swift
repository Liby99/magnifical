// The TODO row's inline EDIT box (right-click ▸ Edit): a single-line NSTextView that replaces
// the row's content, seeded with everything after the task line's "- [ ] " head and styled
// exactly like the markdown note editor — same Menlo face, same MarkdownHighlight rules. The
// highlight runs against the VIRTUAL full line (head + text, the row's real source form) and
// lands shifted into the visible part, so tokens/links/strikes color precisely as they would
// in the note editor; the head itself (indent/marker/checkbox) stays out of the box.
// Return commits, Esc cancels, focus loss commits. macOS-only (the iPhone client is read-only).

#if os(macOS)
    import AppKit
    import CalendarEngine
    import SwiftUI

    /// The full editing row swapped in for a TodoRow: the input box on the row's full width.
    struct TodoRowEditor: View {
        let todo: ParsedTodo
        let theme: Theme
        var preselect: String? = nil // select this PREFIX on open (placeholder flows) instead of caret-at-end
        /// Called exactly once: the edited rest (trimmed) to commit, or nil to cancel.
        let onFinish: (String?) -> Void

        var body: some View {
            let parts = TodoIndex.taskLineParts(todo.raw)
            TodoLineEditor(head: parts?.head ?? "- [ ] ", initial: parts?.rest ?? todo.raw,
                           theme: theme, preselect: preselect, onFinish: onFinish)
                .frame(height: 25)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                .padding(.vertical, 4) // sit in the row's slot (TodoRow pads 5)
        }
    }

    struct TodoLineEditor: NSViewRepresentable {
        let head: String // the immutable "- [ ] " prefix, for virtual-line highlighting only
        let initial: String // the editable rest, seeded into the field
        let theme: Theme
        var preselect: String? = nil // select this prefix of `initial` on focus (else caret at end)
        let onFinish: (String?) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let h = MarkdownHighlight.lineHeight + 6
            let tv = FieldView()
            tv.isRichText = false
            tv.allowsUndo = true
            tv.drawsBackground = false
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.textContainerInset = NSSize(width: 4, height: 3)
            tv.font = MarkdownHighlight.monoFont()
            tv.typingAttributes = MarkdownHighlight.baseAttributes(NSColor(theme.text))
            tv.insertionPointColor = NSColor(theme.text) // caret in the text color, not system blue
            tv.selectedTextAttributes = [ // selection in the ACCENT, like the note editor
                .backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.24),
            ]
            tv.delegate = context.coordinator
            // Single visual line: never wrap — the container is unbounded, the text view SIZES
            // to its text (never smaller than the clip; see LineClipScrollView), and the scroll
            // view pans to keep the caret visible. The explicit frame matters: NSTextView()
            // starts at .zero and nothing ever draws in a zero-width view.
            tv.frame = NSRect(x: 0, y: 0, width: 120, height: h)
            tv.minSize = NSSize(width: 0, height: h)
            tv.maxSize = NSSize(width: .greatestFiniteMagnitude, height: h)
            tv.isHorizontallyResizable = true
            tv.isVerticallyResizable = false
            tv.autoresizingMask = []
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.heightTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: h)
            tv.onCommit = { [weak coordinator = context.coordinator] in coordinator?.finish(cancel: false) }
            tv.onCancel = { [weak coordinator = context.coordinator] in coordinator?.finish(cancel: true) }
            tv.string = initial
            tv.sizeToFit()
            context.coordinator.textView = tv
            context.coordinator.restyle()

            let sv = LineClipScrollView()
            sv.documentView = tv
            sv.drawsBackground = false
            sv.borderType = .noBorder
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.verticalScrollElasticity = .none

            // Grab the keyboard once mounted. A placeholder flow (⇧Enter sub-item) SELECTS the
            // placeholder so typing replaces it; a plain edit puts the caret at the end.
            let pre = preselect
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                if let pre, tv.string.hasPrefix(pre) {
                    tv.setSelectedRange(NSRange(location: 0, length: (pre as NSString).length))
                } else {
                    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                }
            }
            return sv
        }

        /// Keeps the text view at least as wide as the visible clip (short text would otherwise
        /// leave a sliver-width document with the caret hugging its right edge).
        final class LineClipScrollView: NSScrollView {
            override func tile() {
                super.tile()
                guard let tv = documentView as? NSTextView else { return }
                tv.minSize = NSSize(width: contentSize.width, height: contentSize.height)
                if tv.frame.width < contentSize.width {
                    tv.setFrameSize(NSSize(width: contentSize.width, height: contentSize.height))
                }
            }
        }

        func updateNSView(_: NSScrollView, context: Context) {
            context.coordinator.parent = self
        }

        /// Return/Esc surfaced as closures; everything else is stock NSTextView editing.
        final class FieldView: NSTextView {
            var onCommit: (() -> Void)?
            var onCancel: (() -> Void)?

            override func insertNewline(_: Any?) {
                onCommit?()
            }

            override func cancelOperation(_: Any?) {
                onCancel?()
            }
        }

        @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: TodoLineEditor
            weak var textView: FieldView?
            private var finished = false // onFinish fires exactly once (Esc also blurs)

            init(_ parent: TodoLineEditor) {
                self.parent = parent
            }

            func textDidChange(_: Notification) {
                restyle()
            }

            func textDidEndEditing(_: Notification) {
                finish(cancel: false) // click-away/Tab = commit, like the drawer inline editors
            }

            func finish(cancel: Bool) {
                guard !finished else { return }
                finished = true
                let text = (textView?.string ?? "")
                    .replacingOccurrences(of: "\n", with: " ") // a pasted newline can't split the row
                    .trimmingCharacters(in: .whitespaces)
                parent.onFinish(cancel || text.isEmpty ? nil : text)
            }

            /// The note editor's exact per-line pass, run on the VIRTUAL line (head + text) and
            /// shifted so only the spans inside the visible rest land on the field's storage.
            func restyle() {
                guard let tv = textView, let storage = tv.textStorage else { return }
                let base = NSColor(parent.theme.text)
                let accent = NSColor(Theme.accent)
                let text = tv.string
                let len = (text as NSString).length
                let shift = (parent.head as NSString).length
                storage.beginEditing()
                storage.setAttributes(MarkdownHighlight.baseAttributes(base),
                                      range: NSRange(location: 0, length: len))
                for (r, attrs) in MarkdownHighlight.lineSpans(parent.head + text, base: base, accent: accent) {
                    let lo = max(0, r.location - shift)
                    let hi = min(len, r.location + r.length - shift)
                    if hi > lo {
                        storage.addAttributes(attrs, range: NSRange(location: lo, length: hi - lo))
                    }
                }
                storage.endEditing()
                tv.typingAttributes = MarkdownHighlight.baseAttributes(base)
            }
        }
    }
#endif
