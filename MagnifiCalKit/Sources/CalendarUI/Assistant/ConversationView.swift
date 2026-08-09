// One conversation — the transcript (iMessage-style bubbles) + composer. Fills its container;
// the window (AssistantWindowView) provides the chrome. Extracted from the old in-window panel.

import CalendarGeometry // MONTH_NAMES
import SwiftUI

private let accent = Theme.accent
private let bodySize: CGFloat = 14.5
private let smallSize: CGFloat = 12
private let sendDiameter: CGFloat = 28 // send circle; sits inside the pill with a ~6px inset

struct ConversationView: View {
    @Bindable var state: AssistantState
    let theme: Theme
    /// Callout mode: clear background so the popover's glass material shows through.
    var translucent: Bool = false

    /// Received-bubble gray — iMessage-like, adapts to the light/dark surface.
    private var receivedFill: Color {
        theme.dark ? Color(hex: 0x3B3B3D) : Color(hex: 0xE9E9EB)
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .background(translucent ? AnyShapeStyle(.clear)
            : theme.dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(theme.bg))
        .tint(accent)
    }

    /// ── Transcript ────────────────────────────────────────────────────────────────
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if state.messages.isEmpty {
                        emptyState
                    }
                    ForEach(state.messages) { turn in row(turn) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: state.messages.count) { _, _ in scrollDown(proxy) }
            .onChange(of: state.messages.last?.text) { _, _ in scrollDown(proxy) }
            // Opening the popover/window always lands on the LATEST message. Deferred a tick so the
            // list has laid out (an onAppear scroll on unmeasured content is a no-op), and unanimated —
            // it should simply open at the bottom, not visibly scroll there.
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func row(_ turn: ChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack { Spacer(minLength: 56); sentBubble(turn.text) }
        case .assistant:
            HStack { receivedBubble(MarkdownText(text: turn.text, theme: theme)); Spacer(minLength: 56) }
        case .typing:
            HStack { receivedBubble(TypingDots(color: theme.textMuted)); Spacer(minLength: 56) }
        case .action:
            actionChip(turn)
        case .confirm:
            if let req = turn.confirm {
                confirmCard(turn.id, req)
            }
        case .resume:
            resumeCard(turn)
        case .blocked:
            if let req = turn.blockedReq {
                blockedCard(turn.id, req)
            }
        }
    }

    /// A tool-activity bubble. Collapsed: a small centered pill. Tapping it expands the bubble
    /// ITSELF into a card of structured rows (Title / When / Color / results / …) — ported from the
    /// web app's ActionCard + ActionDetail, not a raw JSON dump.
    @ViewBuilder private func actionChip(_ turn: ChatTurn) -> some View {
        if turn.expanded, let d = turn.detail {
            expandedActionCard(turn, d)
        } else {
            collapsedActionPill(turn)
        }
    }

    private func collapsedActionPill(_ turn: ChatTurn) -> some View {
        HStack(spacing: 5) {
            if let icon = turn.icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
            Text(turn.text).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
            if turn.detail != nil {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(theme.textMuted)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(theme.textMuted.opacity(0.12), in: Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            guard turn.detail != nil else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { state.toggleExpanded(turn.id) }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func expandedActionCard(_ turn: ChatTurn, _ d: ActionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Head — same content as the pill; tapping collapses back.
            HStack(spacing: 6) {
                if let icon = turn.icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textMuted)
                }
                Text(turn.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(2)
                Spacer(minLength: 8)
                Text(String(format: "%.1fs", d.seconds)).font(.system(size: 10)).foregroundStyle(theme.textMuted)
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.textMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { state.toggleExpanded(turn.id) }
            }
            Divider()
            ActionDetailView(paramsJSON: d.params, resultJSON: d.result, theme: theme)
        }
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(receivedFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your calendar")
                .font(.system(size: bodySize, weight: .semibold)).foregroundStyle(theme.text)
            Text("e.g. “What's on my calendar this month?” or “When am I free next week?”")
                .font(.system(size: smallSize)).foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// "Continue" card shown when a turn hit the step ceiling — resumes the stashed run.
    private func resumeCard(_ turn: ChatTurn) -> some View {
        HStack(spacing: 6) {
            if turn.resumeConsumed {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                Text("Continuing…").font(.system(size: 11.5, weight: .medium))
            } else {
                Image(systemName: "arrow.forward.circle.fill").font(.system(size: 11, weight: .semibold))
                Text("Continue").font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(turn.resumeConsumed ? theme.textMuted : accent)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background((turn.resumeConsumed ? theme.textMuted : accent).opacity(0.12), in: Capsule(style: .continuous))
        .contentShape(Capsule())
        .onTapGesture {
            if !turn.resumeConsumed {
                state.continueChat(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Interactive delete-confirmation card: title + kind/date + Delete/Cancel, or a resolved state.
    private func confirmCard(_ turnId: UUID, _ req: ConfirmRequest) -> some View {
        let danger = Color(hex: 0xE0483B)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "trash").font(.system(size: 12, weight: .semibold)).foregroundStyle(danger)
                Text(req.occurrenceDate == nil ? "Delete “\(req.title)”?" : "Skip “\(req.title)”?")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            }
            if let od = req.occurrenceDate {
                Text("Only the \(od) occurrence — the series stays.")
                    .font(.system(size: 11)).foregroundStyle(theme.textMuted)
            } else if !req.kind.isEmpty || !req.date.isEmpty {
                Text([req.kind.capitalized, req.date].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(theme.textMuted)
            }
            switch req.status {
            case .pending:
                HStack(spacing: 8) {
                    Button("Delete") { state.resolveDelete(turnId, confirmed: true) }
                        .buttonStyle(.bouncy)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(danger, in: Capsule())
                    Button("Cancel") { state.resolveDelete(turnId, confirmed: false) }
                        .buttonStyle(.bouncy)
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(theme.textMuted.opacity(0.15), in: Capsule())
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)
            case .confirmed:
                Label("Deleted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textMuted)
            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(receivedFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Safety-check card: the auditor denied a mutating call. "Allow" is the user's explicit
    /// override — it re-runs the call unaudited and resumes; "Tell it what to do" hands control
    /// back to the composer.
    private func blockedCard(_ turnId: UUID, _ req: BlockedRequest) -> some View {
        let danger = Color(hex: 0xE0483B)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(danger)
                Text("Safety check blocked \(req.toolName)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            }
            if !req.reason.isEmpty {
                Text(req.reason).font(.system(size: 11)).foregroundStyle(theme.textMuted)
            }
            switch req.status {
            case .pending:
                HStack(spacing: 8) {
                    Button("Allow") { state.allowBlocked(turnId) }
                        .buttonStyle(.bouncy)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(danger, in: Capsule())
                    Button("Tell it what to do") {
                        state.dismissBlocked(turnId)
                        state.requestInputFocus()
                    }
                    .buttonStyle(.bouncy)
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(theme.textMuted.opacity(0.15), in: Capsule())
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textMuted)
            case .dismissed:
                Label("Waiting for your guidance", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(receivedFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// iMessage-style bubble shape: rounded, with a tight "tail" corner on the sender's side.
    private func bubbleShape(isUser: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: isUser ? 18 : 5,
            bottomTrailingRadius: isUser ? 5 : 18,
            topTrailingRadius: 18,
            style: .continuous
        )
    }

    private func sentBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: bodySize))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(accent, in: bubbleShape(isUser: true))
    }

    private func receivedBubble(_ content: some View) -> some View {
        content
            .font(.system(size: bodySize))
            .foregroundStyle(theme.text)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(receivedFill, in: bubbleShape(isUser: false))
    }

    // ── Composer: a full-width glass-white pill with the send circle inset on the right ──
    // The input is an AppKit-backed editor (ComposerTextView): it rewraps at its real live width
    // (no stale sidebar-open wrap width), grows with the text up to `maxEditorHeight`, and scrolls
    // internally beyond that. Enter sends; Shift+Enter inserts a newline.
    @State private var editorHeight: CGFloat = 20
    private var maxEditorHeight: CGFloat {
        3.5 * 18
    } // ~3.5 lines before the inner scroll takes over
    /// Half the RESTING (single-line) pill height: editor 20 + 9pt vertical padding × 2 = 38. The corner
    /// radius stays at this constant as the box grows — a Capsule would re-round to half the LIVE height.
    private let pillRadius: CGFloat = 19

    private var composer: some View {
        HStack(alignment: .center, spacing: 6) { // center → send stays inside the pill's rounded cap
            ZStack(alignment: .topLeading) {
                if state.draft.isEmpty {
                    Text("Message the assistant…")
                        .font(.system(size: 14)).foregroundStyle(theme.textMuted)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $state.draft,
                                 textColor: NSColor(theme.text),
                                 focusToken: state.focusInput,
                                 onSend: { state.send() },
                                 onHeightChange: { h in
                                     if abs(h - editorHeight) > 0.5 {
                                         editorHeight = h
                                     }
                                 })
                                 .frame(height: min(editorHeight, maxEditorHeight))
            }
            .padding(.leading, 16)
            .padding(.vertical, 9)
            sendButton
        }
        .padding(.trailing, 6) // inset so the send circle sits comfortably inside the pill's edge
        .animation(.easeOut(duration: 0.12), value: editorHeight)
        // Sending clears the draft → snap the editor back to its single-line resting height (the height
        // report from the emptied text view isn't reliable enough on its own).
        .onChange(of: state.draft) {
            _, v in if v.isEmpty {
                editorHeight = 20
            }
        }
        // Frosted glass with a FIXED radius (half the resting height): the box keeps its resting curvature
        // as it grows into multiple lines instead of re-rounding like a capsule would.
        .background {
            RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 1.5)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var sendButton: some View {
        let empty = state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let disabled = !state.busy && empty
        return Button {
            if state.busy {
                state.stop()
            } else if !empty {
                state.send()
            }
        } label: {
            Image(systemName: state.busy ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: sendDiameter, height: sendDiameter)
                .background(accent, in: Circle())
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.bouncy)
        .disabled(disabled)
        .help(state.busy ? "Stop" : "Send")
        .animation(.easeInOut(duration: 0.12), value: state.busy)
    }
}
