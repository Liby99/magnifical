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
        /// Called exactly once: the edited rest (trimmed) to commit, or nil to cancel.
        let onFinish: (String?) -> Void

        var body: some View {
            let parts = TodoIndex.taskLineParts(todo.raw)
            TodoLineEditor(head: parts?.head ?? "- [ ] ", initial: parts?.rest ?? todo.raw,
                           theme: theme, onFinish: onFinish)
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
        let onFinish: (String?) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let tv = FieldView()
            tv.isRichText = false
            tv.allowsUndo = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 4, height: 3)
            tv.font = MarkdownHighlight.monoFont()
            tv.delegate = context.coordinator
            // Single visual line: never wrap — the container is unbounded and the text view
            // grows horizontally; the enclosing scroll view pans to keep the caret visible.
            tv.isHorizontallyResizable = true
            tv.isVerticallyResizable = false
            tv.maxSize = NSSize(width: .greatestFiniteMagnitude, height: MarkdownHighlight.lineHeight + 6)
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: MarkdownHighlight.lineHeight)
            tv.onCommit = { [weak coordinator = context.coordinator] in coordinator?.finish(cancel: false) }
            tv.onCancel = { [weak coordinator = context.coordinator] in coordinator?.finish(cancel: true) }
            tv.string = initial
            context.coordinator.textView = tv
            context.coordinator.restyle()

            let sv = NSScrollView()
            sv.documentView = tv
            sv.drawsBackground = false
            sv.borderType = .noBorder
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.verticalScrollElasticity = .none

            // Grab the keyboard once mounted; caret at the end (an edit usually appends).
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
            return sv
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
