// The delete-confirmation modal (keyboard-first dialog + backdrop) and the modal overlay
// plumbing that hosts it. Split from CalendarView.swift (file diet).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// The custom delete-confirmation modal. A dimmed backdrop + a centered card with the question and a
/// horizontal row of buttons. Keyboard focus (the dashed ring) is driven by `pending.focus` via the key
/// monitor; every button is also mouse-clickable. Esc → Cancel is handled by the monitor; clicking the
/// backdrop cancels too.
struct DeleteConfirmDialog: View {
    let pending: PendingDelete
    let theme: Theme
    var onChoose: (DeleteChoice) -> Void

    var body: some View {
        ZStack {
            // Full-window scrim: a light dim that (with the CatcherView's modal guards) swallows all mouse
            // to the canvas. The subtle blur itself is applied to the calendar content, not here. Tap cancels.
            Color.black.opacity(0.1).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onChoose(.cancel) }
            // The glass card — same frosted-glass + border + shadow treatment as the ⌘K shortcut guide.
            VStack(spacing: 14) {
                Text(pending.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true) // full wrapped height (like the note)
                if let note = pending.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textMuted)
                        .multilineTextAlignment(.center)
                        // FIXED width (not maxWidth): under the card's outer `.fixedSize()` a
                        // maxWidth frame can still measure the note as one long line (the batch
                        // dialog hit exactly that — see its width-based fix), which under-measures
                        // the card height and pushes the buttons over its bottom edge. A hard
                        // width makes wrap height deterministic; the card can only grow wider
                        // for the button row / title.
                        .frame(width: 360)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    ForEach(Array(pending.choices.enumerated()), id: \.offset) { idx, choice in
                        DeleteDialogButton(label: choice.label(recurring: pending.recurring),
                                           destructive: choice.isDestructive, // lane-removal/unhide stay plain
                                           focused: pending.focus == idx, // nil focus → no ring shown yet
                                           theme: theme) { onChoose(choice) }
                    }
                }
            }
            // Content-hugging (fixedSize) → the card grows with a longer note or more buttons.
            // Squat proportions: tighter vertically, roomier horizontally.
            .padding(.horizontal, 52).padding(.vertical, 18)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .fixedSize()
        }
    }
}

/// Batch-delete confirm for a multi-selection: title + mixed-content summary note + Cancel / Delete.
struct BatchDeleteDialog: View {
    let summary: CalendarEngine.BatchDeleteSummary
    let theme: Theme
    var onDelete: () -> Void
    var onCancel: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { onCancel() }
            VStack(spacing: 14) {
                Text(summary.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(summary.note).font(.system(size: 12)).foregroundStyle(theme.textMuted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    DeleteDialogButton(label: "Cancel", destructive: false, focused: false, theme: theme) { onCancel() }
                    DeleteDialogButton(label: "Delete", destructive: true, focused: true, theme: theme) { onDelete() }
                }
            }
            // Fixed CONTENT width, intrinsic (grow-to-fit) height: the note wraps at this width and the
            // card grows downward for however many lines the summary needs — no overflow. (A bare
            // `.fixedSize()` here would force the ideal width too, measuring the note as one long line.)
            .frame(width: 340)
            .padding(.horizontal, 40).padding(.vertical, 26)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        }
    }
}

/// Delete confirm for a PROJ-panel todo row: "Delete this to-do?" + the item's own text +
/// Cancel / Delete — BatchDeleteDialog's exact card recipe (scrim, glass card, capsule buttons).
struct TodoDeleteDialog: View {
    let text: String
    let theme: Theme
    var onDelete: () -> Void
    var onCancel: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { onCancel() }
            VStack(spacing: 14) {
                Text("Delete this to-do?").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(text).font(.system(size: 12)).foregroundStyle(theme.textMuted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    DeleteDialogButton(label: "Cancel", destructive: false, focused: false, theme: theme) { onCancel() }
                    DeleteDialogButton(label: "Delete", destructive: true, focused: true, theme: theme) { onDelete() }
                }
            }
            // Fixed CONTENT width, intrinsic height — the todo text wraps at this width and the
            // card grows downward (BatchDeleteDialog's measurement fix, same reasoning).
            .frame(width: 340)
            .padding(.horizontal, 40).padding(.vertical, 26)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        }
    }
}

/// Shared dismissal for the batch-rename panel. CANCEL (Esc — routed from the key monitor so it
/// works with the field unfocused too — or the Cancel button) reverts the live renames to the
/// titles captured when the panel opened; COMMIT (Enter / the Rename button) keeps them.
@MainActor func cancelBatchRename(ui: CalendarUIState, engine: CalendarEngine) {
    if ui.batchRenameTouched {
        engine.batchRestoreTitles(ui.batchRenameOriginal)
    }
    ui.batchRenaming = false
    engine.wake()
}

@MainActor func commitBatchRename(ui: CalendarUIState, engine: CalendarEngine) {
    ui.batchRenaming = false
    engine.wake()
}

/// The floating "rename all" panel for a multi-selection: typing sets every selected title LIVE.
/// Modal — a full-window scrim blocks the calendar behind it (the input catcher's modalActive
/// also drops pointer/keys); no tap-to-close, dismissal is explicit via Cancel/Rename (or
/// Esc/Enter).
struct BatchRenameField: View {
    let ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    @FocusState private var focused: Bool
    var body: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 10) {
                Text("Rename \(engine.selectedIds.count) events")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textMuted)
                TextField("Name", text: Binding(
                    get: { ui.batchRenameText },
                    set: { v in
                        ui.batchRenameText = v
                        ui.batchRenameTouched = true
                        engine.batchSetTitle(v) // live: all selected titles
                    }
                ))
                .textFieldStyle(.plain).font(.custom("Comic Sans MS", size: 14)).foregroundStyle(theme.text)
                .frame(width: 240).focused($focused)
                .onSubmit { commitBatchRename(ui: ui, engine: engine) }
                .onExitCommand { cancelBatchRename(ui: ui, engine: engine) }
                HStack(spacing: 12) {
                    DeleteDialogButton(label: "Cancel", destructive: false, focused: false, theme: theme) {
                        cancelBatchRename(ui: ui, engine: engine)
                    }
                    DeleteDialogButton(label: "Rename", destructive: false, focused: true, theme: theme) {
                        commitBatchRename(ui: ui, engine: engine)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        }
        .onAppear {
            ui.batchRenameOriginal = engine.batchTitlesSnapshot() // Cancel restores these
            focused = true
        }
    }
}

/// New / Rename a calendar: a small name prompt. Enter commits, Esc / tap-outside cancels. Creating
/// switches into the new empty calendar; renaming relabels the open one.
struct CalendarNameDialog: View {
    let ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    @FocusState private var focused: Bool
    private var isRename: Bool {
        ui.calendarPrompt == .rename
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { cancel() }
            VStack(spacing: 14) {
                Text(isRename ? "Rename Calendar" : "New MagnifiCal")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                TextField("Name", text: Binding(get: { ui.calendarPromptText },
                                                set: { ui.calendarPromptText = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 240).focused($focused)
                    .onSubmit { commit() }.onExitCommand { cancel() }
                HStack(spacing: 12) {
                    DeleteDialogButton(label: "Cancel", destructive: false, focused: false, theme: theme) { cancel() }
                    DeleteDialogButton(label: isRename ? "Rename" : "Create",
                                       destructive: false, focused: true, theme: theme) { commit() }
                }
            }
            .frame(width: 300)
            .padding(.horizontal, 32).padding(.vertical, 22)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        }
        .onAppear { focused = true }
    }

    private func commit() {
        let name = ui.calendarPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if isRename {
            engine.renameCurrentCalendar(name)
        } else {
            engine.createCalendar(named: name)
        }
        ui.calendarPrompt = nil; engine.wake()
    }

    private func cancel() {
        ui.calendarPrompt = nil
    }
}

/// Remove the current calendar — destructive confirm (deletes all its data). Switches to the most-recent
/// other calendar. The menu item is disabled when it's the only calendar, so this always has a fallback.
struct CalendarRemoveDialog: View {
    let ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    var body: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { ui.pendingCalendarRemove = false }
            VStack(spacing: 14) {
                Text("Remove “\(engine.activeCalendarName)”?")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(
                    "This permanently deletes this calendar and everything in it — events, deadlines, notes, and its calendar settings. This can’t be undone."
                )
                .font(.system(size: 12)).foregroundStyle(theme.textMuted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    DeleteDialogButton(label: "Cancel", destructive: false, focused: false, theme: theme) {
                        ui.pendingCalendarRemove = false
                    }
                    DeleteDialogButton(label: "Remove", destructive: true, focused: true, theme: theme) {
                        engine.removeCurrentCalendar(); ui.pendingCalendarRemove = false; engine.wake()
                    }
                }
            }
            .frame(width: 340)
            .padding(.horizontal, 32).padding(.vertical, 22)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        }
    }
}

/// One button in the delete dialog: a rounded pill that shows a dashed ring (matching the app's keyboard
/// focus style) when it's the focused choice, red text for destructive actions.
private struct DeleteDialogButton: View {
    let label: String
    let destructive: Bool
    let focused: Bool
    let theme: Theme
    var action: () -> Void
    @State private var hover = false

    private var accent: Color {
        destructive ? theme.eventBorder("red") : theme.text
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 28).padding(.vertical, 9)
                .frame(minWidth: 76)
                // The WHOLE capsule is the hit target. Without this, .plain buttons hit-test only
                // the opaque Text — clicks landing on the padding between text and border fell through.
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Capsule(style: .continuous).fill(theme.text.opacity(hover ? 0.14 : 0.07)))
        // Focus ring: a dashed capsule, offset slightly outward, shown only for the arrow-focused button.
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(focused ? accent : .clear,
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .padding(-3)
        )
        .onHover {
            hover = $0; if $0 {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

/// The blocking-modal overlays: the delete-confirm dialog (with its blur + modal-flag plumbing) and the
/// onboarding tutorial carousel. Bundled into a ViewModifier so CalendarView's `body` chain stays short
/// enough for the Swift type-checker.
struct ModalOverlays: ViewModifier {
    let ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    var onDelete: (DeleteChoice) -> Void
    // Right-click event callout hooks (the callout itself rides on this bundle so CalendarView's
    // body chain gains no new links — see EventMenuOverlay).
    var onRename: (String) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onCut: () -> Void = {}
    var onPaste: () -> Void = {}
    var readClip: () -> CalendarEngine.ClipPayload? = { nil }

    /// The canvas input gate reflects EVERY blocking dialog this modifier hosts.
    private func syncModalGate() {
        engine.inputModalUp = ui.pendingDelete != nil || ui.notice != nil
            || ui.calendarPrompt != nil || ui.pendingCalendarRemove
            || ui.pendingTodoDelete != nil
    }

    func body(content: Content) -> some View {
        content
            // Gentle blur on the calendar while a blocking dialog (delete confirm / notice) is up
            // (before the dialog overlay, so the dialog stays sharp).
            .blur(radius: ui.pendingDelete != nil || ui.notice != nil
                || ui.pendingTodoDelete != nil ? 2.5 : 0)
            .overlay {
                if let pd = ui.pendingDelete {
                    DeleteConfirmDialog(pending: pd, theme: theme, onChoose: onDelete)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.pendingDelete)
            .onChange(of: ui.pendingDelete == nil) { _, _ in syncModalGate() }
            // PROJ row-menu Delete confirm — window-level (full-window blur), same glass card.
            .overlay {
                if let td = ui.pendingTodoDelete {
                    TodoDeleteDialog(text: td.text, theme: theme,
                                     onDelete: {
                                         td.confirm()
                                         ui.pendingTodoDelete = nil
                                         engine.wake()
                                     },
                                     onCancel: { ui.pendingTodoDelete = nil; engine.wake() })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.pendingTodoDelete == nil)
            .onChange(of: ui.pendingTodoDelete == nil) { _, _ in syncModalGate() }
            // One-button informational notice (e.g. "Printing Week view is not supported right now.").
            .overlay {
                if let msg = ui.notice {
                    NoticeDialog(message: msg, theme: theme, onDismiss: { ui.notice = nil; engine.wake() })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.notice)
            .onChange(of: ui.notice == nil) { _, _ in syncModalGate() }
            // Batch-delete confirm (multi-selection).
            .overlay {
                if let s = ui.pendingBatchDelete {
                    BatchDeleteDialog(summary: s, theme: theme,
                                      onDelete: {
                                          engine.performBatchDelete(); ui.pendingBatchDelete = nil; engine.wake()
                                      },
                                      onCancel: { ui.pendingBatchDelete = nil })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.pendingBatchDelete)
            // Floating "rename all" field (multi-selection).
            .overlay {
                if ui.batchRenaming {
                    BatchRenameField(ui: ui, engine: engine, theme: theme).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.batchRenaming)
            // Multiple calendars: New/Rename name prompt + Remove confirm.
            .overlay {
                if ui.calendarPrompt != nil {
                    CalendarNameDialog(ui: ui, engine: engine, theme: theme).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.calendarPrompt)
            .onChange(of: ui.calendarPrompt) { _, _ in syncModalGate() }
            .overlay {
                if ui.pendingCalendarRemove {
                    CalendarRemoveDialog(ui: ui, engine: engine, theme: theme).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.pendingCalendarRemove)
            .onChange(of: ui.pendingCalendarRemove) { _, _ in syncModalGate() }
            .onReceive(NotificationCenter.default.publisher(for: .newCalendar)) { _ in
                ui.calendarPromptText = ""; ui.calendarPrompt = .new
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameCalendar)) { _ in
                ui.calendarPromptText = engine.activeCalendarName; ui.calendarPrompt = .rename
            }
            .onReceive(NotificationCenter.default.publisher(for: .removeCalendar)) { _ in
                if engine.canRemoveCalendar {
                    ui.pendingCalendarRemove = true
                }
            }
            .overlay { // tutorial carousel — topmost
                if ui.showTutorial {
                    TutorialView(theme: theme, ui: ui, onClose: { ui.showTutorial = false })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: ui.showTutorial)
            .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
                ui.tutorialIndex = 0; ui.showTutorial = true; engine.wake()
            }
            // File ▸ Print… (⌘P): YEAR view prints via the system panel; other levels get a notice.
            .onReceive(NotificationCenter.default.publisher(for: .requestPrint)) { _ in
                if engine.chrome.level == 0 {
                    PrintYear.run(engine: engine, window: NSApp.keyWindow ?? NSApp.mainWindow)
                } else {
                    let name = ["Year", "Month", "Week", "Day"][max(0, min(3, engine.chrome.level))]
                    ui.notice = "Printing \(name) view is not supported right now."
                    engine.wake()
                }
            }
            // Right-click event callout (kept in this bundle for the type-checker's budget).
            .modifier(EventMenuOverlay(ui: ui, engine: engine, theme: theme,
                                       onRename: onRename, onCopy: onCopy, onCut: onCut,
                                       onPaste: onPaste, readClip: readClip))
    }
}

/// A one-button informational modal in the delete dialog's visual language (same scrim, glass card, and
/// capsule button). Enter/Esc (routed like the delete dialog's keys) or OK/tap-outside dismiss.
struct NoticeDialog: View {
    let message: String
    let theme: Theme
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 14) {
                Text(message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                DeleteDialogButton(label: "OK", destructive: false, focused: true, theme: theme) { onDismiss() }
            }
            // Content-hugging (fixedSize) → the card grows with a longer note or more buttons.
            // Squat proportions: tighter vertically, roomier horizontally.
            .padding(.horizontal, 52).padding(.vertical, 18)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .fixedSize()
        }
    }
}
