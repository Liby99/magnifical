// The row right-click callout SHARED by the PROJ gantt and the TODO panel — the event
// callout's exact chrome (same popover card width/padding, MenuRow rows, MENU_COLORS circle
// row) acting on the todo's SOURCE LINE via TodoIndex token rewrites. Each panel supplies its
// own pin tag ("proj-pinned" on PROJ, "pinned" on the TODO panel) and its own write closures;
// everything visual lives here once.

import CalendarEngine
import CalendarGeometry
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Every WRITE the row callout can trigger — assignment-style construction only, the
/// EventMenuActions pattern (a many-argument call here is a type-checker cliff). All closures
/// act on the ParsedTodo source line, so both panels share one shape: Check/Uncheck routes
/// through the panel's own toggle path (`toggle`), Go to Definition through its open path
/// (`openTodo`), and Delete through the window-level confirm chain.
struct TodoRowMenuActions {
    var toggle: (ParsedTodo) -> Void = { _ in }
    var openTodo: (ParsedTodo) -> Void = { _ in }
    var setColor: (ParsedTodo, String) -> Void = { _, _ in }
    var pin: (ParsedTodo) -> Void = { _ in }
    var unpin: (ParsedTodo) -> Void = { _ in }
    var setPriority: (ParsedTodo, Int) -> Void = { _, _ in }
    var clearPriority: (ParsedTodo) -> Void = { _ in }
    var hide: (ParsedTodo) -> Void = { _ in }
    var delete: (ParsedTodo) -> Void = { _ in }
}

struct TodoRowCallout: View {
    let todo: ParsedTodo
    let done: Bool
    let pinTag: String // "proj-pinned" (PROJ) | "pinned" (TODO panel)
    let theme: Theme
    let actions: TodoRowMenuActions
    var onColorPreview: (String?) -> Void = { _ in }
    var onClose: () -> Void

    @State private var priorityOpen = false // the Priority row's inline 1–5 expansion

    private var pinned: Bool {
        todo.tags.contains { $0.lowercased() == pinTag }
    }

    /// Ring only an EXPLICIT line `color:` token — an event-inherited color isn't the line's.
    private var lineColor: String? {
        todo.colorSource == "line" ? todo.color : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            colorRow.padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 6)
            Divider().padding(.bottom, 3)
            row("Check", icon: "checkmark.square", disabled: done) { actions.toggle(todo) }
            row("Uncheck", icon: "square", disabled: !done) { actions.toggle(todo) }
            row("Copy", icon: "doc.on.doc") {
                #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(todo.text, forType: .string)
                #else
                    UIPasteboard.general.string = todo.text
                #endif
            }
            if pinned {
                row("Unpin", icon: "pin.slash") { actions.unpin(todo) }
            } else {
                row("Pin", icon: "pin") { actions.pin(todo) }
            }
            priorityRow
            row("Hide from Project Panel", icon: "eye.slash") { actions.hide(todo) }
            Divider().padding(.vertical, 3)
            row("Go to Definition", icon: "arrow.uturn.backward.circle") { actions.openTodo(todo) }
            Divider().padding(.vertical, 3)
            row("Delete", icon: "trash", destructive: true) { actions.delete(todo) }
        }
        .padding(6)
        .frame(width: 208)
    }

    /// The event callout's quick-color row, wired to the line's `color:` token. Hovering a
    /// dot live-previews (render-only — PROJ tints the row's bars); the click commits.
    private var colorRow: some View {
        HStack(spacing: 7) {
            ForEach(MENU_COLORS, id: \.self) { key in
                CalloutColorDot(key: key, current: lineColor == key, theme: theme,
                                onHoverDot: { onColorPreview($0 ? key : nil) }) {
                    onColorPreview(nil)
                    actions.setColor(todo, key)
                    onClose()
                }
            }
            Spacer(minLength: 0)
        }
        .onHover { over in
            if over {
                priorityOpen = false
            }
        }
    }

    /// "Priority": a true SECONDARY menu — hovering the row pops a side panel (arrowEdge
    /// .trailing) listing "!"…"!!!!!" vertically, the current level checkmarked on the right.
    /// Hovering any other row closes it (see row(_:)/colorRow's onHover).
    private var priorityRow: some View {
        MenuRow(label: "Priority", icon: "exclamationmark.circle", key: "▸",
                destructive: false, theme: theme) {
            priorityOpen = true // click opens too
        }
        .onHover { over in
            if over {
                priorityOpen = true
            }
        }
        .popover(isPresented: $priorityOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 1) {
                // "None" (checked when the line carries no p: token) clears the priority.
                CalloutPriorityOption(bangs: "None", current: todo.priority == nil,
                                      theme: theme) {
                    actions.clearPriority(todo)
                    priorityOpen = false
                    onClose()
                }
                Divider().padding(.vertical, 2)
                ForEach(1 ... TodoIndex.maxPriority, id: \.self) { n in
                    CalloutPriorityOption(bangs: String(repeating: "!", count: n),
                                          current: todo.priority == n, theme: theme) {
                        actions.setPriority(todo, n)
                        priorityOpen = false
                        onClose()
                    }
                }
            }
            .padding(6)
            .frame(width: 104)
        }
    }

    private func row(_ label: String, icon: String, destructive: Bool = false,
                     disabled: Bool = false, action: @escaping () -> Void) -> some View {
        MenuRow(label: label, icon: icon, key: nil, destructive: destructive, disabled: disabled,
                theme: theme) {
            action()
            onClose()
        }
        .onHover { over in // leaving for another row closes the priority side menu
            if over {
                priorityOpen = false
            }
        }
    }
}

/// One MENU_COLORS circle (the event callout's 18pt dot): current-color ring, hover ring, .help.
/// No engine color-preview here — the write is a line-token rewrite, not an event color.
private struct CalloutColorDot: View {
    let key: String
    let current: Bool
    let theme: Theme
    var onHoverDot: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(theme.eventBorder(key))
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(theme.text, lineWidth: current ? 2 : hovering ? 1 : 0))
            .contentShape(Circle())
            .onHover { over in
                hovering = over
                onHoverDot(over)
            }
            .onTapGesture { action() }
            .help(key)
    }
}

/// One row of the Priority SIDE menu ("!" … "!!!!!"), current level checkmarked on the right.
private struct CalloutPriorityOption: View {
    let bangs: String
    let current: Bool
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(bangs)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.text.opacity(0.8))
                    .opacity(current ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(theme.text.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
