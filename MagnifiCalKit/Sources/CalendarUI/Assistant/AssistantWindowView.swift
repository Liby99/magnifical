// The standalone "Calendar AI" chat window — a minimal chat client (like Claude/ChatGPT/iMessage):
// a toggleable conversations sidebar on the left, the messaging conversation on the right.
// The sidebar lists the REAL saved conversations (AssistantState persists them to disk);
// selecting one loads its transcript, and every new chat appears here as soon as it starts.

import SwiftUI

public struct AssistantWindowView: View {
    @Bindable var state: AssistantState
    /// The quick-ask callout's session (if any) — its conversation gets a marker in the sidebar.
    private let callout: AssistantState?
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AssistantModels.defaultsKey) private var model = AssistantModels.fallback
    // Sidebar closed by default — the window opens as a slim, chat-only client.
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    // Keyboard navigation of the conversation list (⌘B opens the sidebar focused; ↑/↓ move this
    // cursor; Enter opens the cursor row and returns focus to the composer).
    @State private var cursor: Int?
    @FocusState private var sidebarFocused: Bool

    private let accent = Theme.accent

    /// Margin from the sidebar's left/right edges to the conversation row pill (the accent
    /// highlight of the open conversation). Tune this to taste.
    private let sidebarRowMargin: CGFloat = -6

    /// ⌘B focus handoff waits for the sidebar reveal animation to start before focusing the list.
    private static let sidebarFocusDelay: TimeInterval = 0.08

    public init(state: AssistantState, callout: AssistantState? = nil) {
        self.state = state
        self.callout = callout
    }

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        NavigationSplitView(columnVisibility: $columns) {
            sidebar(theme)
                .navigationSplitViewColumnWidth(240) // fixed width → no size interpolation on toggle
        } detail: {
            ConversationView(state: state, theme: theme)
                .navigationTitle("MagnifiCal AI")
                .toolbar { toolbar }
        }
        .frame(minWidth: 360, minHeight: 480)
        // ⌘B → toggle the sidebar; on open, focus lands on the conversation list for ↑/↓ + Enter.
        .background {
            Button("") { toggleSidebar() }
                .keyboardShortcut("b", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func toggleSidebar() {
        let opening = columns != .all
        withAnimation { columns = opening ? .all : .detailOnly }
        if opening {
            cursor = state.conversations.firstIndex { $0.id == state.currentId }
                ?? (state.conversations.isEmpty ? nil : 0)
            // Focus once the column has begun revealing (focusing an off-screen list is a no-op;
            // there is no "column did appear" callback, so this rides the reveal animation's start).
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarFocusDelay) { sidebarFocused = true }
        } else {
            sidebarFocused = false
            state.requestInputFocus() // closing hands the keyboard back to the composer
        }
    }

    /// ── Sidebar: saved conversations (New Chat lives in the toolbar) ─────────────────
    /// Selection is rendered manually (accent pill, not the system highlight); rows select on
    /// click, delete via right-click menu or a trailing swipe.
    private func sidebar(_ theme: Theme) -> some View {
        ScrollViewReader { proxy in
            List {
                if state.conversations.isEmpty {
                    Text("No conversations yet")
                        .font(.system(size: 12)).foregroundStyle(theme.textMuted)
                } else {
                    Section("Conversations") {
                        ForEach(Array(state.conversations.enumerated()), id: \.element.id) { index, convo in
                            conversationRow(convo, theme,
                                            selected: convo.id == state.currentId,
                                            cursorOn: sidebarFocused && cursor == index)
                                .id(convo.id)
                                .contentShape(Rectangle())
                                // The pill is drawn by the row content itself, so the right-click
                                // highlight (which wraps the content view) covers it exactly; disable
                                // any focus-ring effect on top of that.
                                .focusEffectDisabled()
                                .onTapGesture { cursor = index; state.selectConversation(convo.id) }
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 1, leading: sidebarRowMargin,
                                                          bottom: 1, trailing: sidebarRowMargin))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    // The OPEN conversation can't be swipe-deleted (too easy to lose
                                    // the active chat by accident); use the right-click menu instead.
                                    if convo.id != state.currentId {
                                        Button(role: .destructive) {
                                            state.deleteConversation(convo.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        state.deleteConversation(convo.id)
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Keyboard navigation: the list itself takes focus (⌘B), ↑/↓ move the cursor row,
            // Enter opens it and hands the keyboard back to the composer.
            .focusable()
            .focusEffectDisabled()
            .focused($sidebarFocused)
            .onKeyPress { press in handleSidebarKey(press, proxy) }
        }
    }

    private func handleSidebarKey(_ press: KeyPress, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let convos = state.conversations
        guard !convos.isEmpty else { return .ignored }
        switch press.key {
        case .upArrow:
            let c = max(0, (cursor ?? 0) - 1)
            cursor = c
            proxy.scrollTo(convos[c].id)
            return .handled
        case .downArrow:
            let c = min(convos.count - 1, (cursor ?? -1) + 1)
            cursor = c
            proxy.scrollTo(convos[c].id)
            return .handled
        case .return:
            guard let c = cursor, convos.indices.contains(c) else { return .ignored }
            state.selectConversation(convos[c].id)
            sidebarFocused = false
            state.requestInputFocus()
            return .handled
        default:
            return .ignored
        }
    }

    private func conversationRow(_ convo: StoredConversation, _ theme: Theme, selected: Bool,
                                 cursorOn: Bool = false) -> some View {
        // Preview: the last real text in the conversation (user or assistant).
        let preview = convo.turns.last(where: {
            ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty
        })?.text ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                // Marker: this thread is currently held by the quick-ask callout in the calendar.
                if convo.id == callout?.currentId {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? .white.opacity(0.9) : accent)
                        .help("Open in the quick panel")
                }
                Text(convo.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? .white : theme.text)
                    .lineLimit(1)
                Spacer()
                Text(Self.relative(convo.updatedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .white.opacity(0.75) : theme.textMuted)
            }
            Text(preview).font(.system(size: 11))
                .foregroundStyle(selected ? .white.opacity(0.8) : theme.textMuted)
                .lineLimit(1)
        }
        .padding(.vertical, 7) // roomier rows
        .padding(.horizontal, 8)
        // The pill lives on the row content itself (not listRowBackground) so the context-menu
        // highlight and the selection share the exact same bounds. The keyboard cursor draws a
        // subtle wash on non-selected rows (the accent pill already marks the open one).
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? accent : cursorOn ? theme.textMuted.opacity(0.14) : .clear))
    }

    private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private static var activeModelLabel: String {
        guard let id = ProviderStore.active else { return "No AI provider" }
        let m = ProviderStore.settings(id).model
        return "\(id.label.components(separatedBy: " ").first ?? id.rawValue) · \(AssistantModels.label(for: m))"
    }

    /// ── Toolbar: provider/model indicator + new chat ─────────────────────────────────
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // The model now comes from the provider config (Settings ▸ API Keys ▸ Supported LLMs);
            // this shows the active provider · model and jumps to Settings to change it.
            Menu {
                Button("Change in Settings… (⌘,)") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            } label: {
                Label(Self.activeModelLabel, systemImage: "cpu")
            }
            .help("Active AI provider · model — configure in Settings ▸ API Keys")
        }
        ToolbarItem(placement: .primaryAction) {
            // Same as the calendar toolbar's AI button — a clean glass circle, just a different icon.
            Button { state.newChat() } label: { Image(systemName: "square.and.pencil") }
                .glassButtonStyleCompat().buttonBorderShape(.circle)
                // Window-scoped ⌘N: fires only while the chat window is key, so the calendar's
                // own ⌘N (new event at the block cursor) is untouched.
                .keyboardShortcut("n", modifiers: .command)
                .help("New chat (⌘N)")
        }
    }
}
