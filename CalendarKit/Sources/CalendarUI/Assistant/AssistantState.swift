// One assistant SESSION: the live transcript, the ReAct tool-calling loop (runAgent →
// executeBatch, auditor-gated mutations, confirm-gated deletes, blocked/resume cards), the
// system prompt, and mirroring into the shared ConversationStore. The standalone window and
// the quick-ask callout each own one of these over the same store.

import CalendarEngine
import CalendarGeometry
import Foundation
import Observation

@MainActor
@Observable
public final class AssistantState {
    var messages: [ChatTurn] = []
    var draft: String = ""
    var busy: Bool = false

    /// The persisted conversation list, SHARED between assistant sessions (the standalone window
    /// and the quick-ask callout each own an AssistantState; both mirror into this one store).
    public let store: ConversationStore
    var conversations: [StoredConversation] {
        store.conversations
    }

    private(set) var currentId: UUID?

    /// Shared calendar engine for tool context. Assigned by the App so both surfaces read the
    /// same live calendar state; `nil` → tools degrade to "calendar unavailable". `weak`, not
    /// `unowned`: a deallocated engine must nil out, never dangle (matches CloudSync's choice).
    public weak var engine: CalendarEngine?

    public init(store: ConversationStore) {
        self.store = store
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The stashed scratchpad from a run that hit the step ceiling, so "Continue" can pick up where
    /// it left off (the native analogue of the web's in-memory resumeStore).
    @ObservationIgnored private var resumeWire: [ChatMessage]?

    /// A safety-check denial mid-batch, stashed so the blocked card's "Allow" can resume the run:
    /// re-run the denied call with the audit bypassed, finish the batch, rejoin the loop.
    private struct BlockedState {
        var wire: [ChatMessage]
        var calls: [ToolCall]
        var index: Int
        var reason: String = ""
    }

    @ObservationIgnored private var blockedState: BlockedState?
    /// Calls the user explicitly approved via a blocked card's "Allow" this conversation — fed to
    /// later audits (trusted: a real click) so near-identical follow-ups aren't re-blocked each.
    @ObservationIgnored private var allowedOverrides: [String] = []

    /// The model configured for the ACTIVE provider (Settings ▸ API Keys ▸ Supported LLMs).
    private var model: String {
        ProviderStore.activeModel
    }

    // ── Actions ─────────────────────────────────────────────────────────────────────

    /// Max tool-calling rounds before we stop (web uses 30; start conservative). Each round is one
    /// LLM call that may request tools; the loop ends when the model returns a plain answer.
    private static let maxSteps = 12

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        // "Tell it what to do" after a block: CONTINUE the blocked run's scratchpad — the model
        // keeps every action/tool result and the denial context, instead of restarting from the
        // text-only history (which silently redacted everything since the last user message).
        // Every not-yet-executed call in the batch gets a synthetic tool result first: the API
        // requires one response per tool_call before the next user message.
        var continuation: [ChatMessage]? = nil
        if let bs = blockedState {
            var wire = bs.wire
            for (j, call) in bs.calls.enumerated() where j >= bs.index {
                let note = j == bs.index
                    ? "BLOCKED by the safety check: \(bs.reason) — NOT executed. The user has seen this and replies next; follow their instruction."
                    : "not executed (an earlier call in this batch was blocked)"
                wire.append(ChatMessage(role: "tool", content: note, toolCallId: call.id))
            }
            continuation = wire
        }
        // A new instruction supersedes any blocked proposal — retire pending blocked cards.
        blockedState = nil
        for i in messages.indices where messages[i].blockedReq?.status == .pending {
            messages[i].blockedReq?.status = .dismissed
        }
        messages.append(ChatTurn(role: .user, text: text))
        messages.append(ChatTurn(role: .typing, text: ""))
        busy = true
        persistCurrent() // the conversation appears in the sidebar as soon as it starts

        // Pre-flight: no configured provider → answer with a fixed, friendly pointer to Settings
        // instead of spinning up the agent loop just to surface a transport error. Configured =
        // key + model (+ gateway URL); Test Connection is optional.
        if !ProviderStore.activeReady {
            let tavilyMissing = (Keychain.get(account: WebSearchTool.keychainAccount) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var msg = "Please pick an **AI provider** and add its key in the Settings window (**Settings ▸ API Keys**, ⌘,) — I can answer once one is configured."
            if tavilyMissing {
                msg += "\n\nAdding a **Tavily** key there also enables web search."
            }
            finish(text: msg)
            return
        }

        continuation?.append(ChatMessage(role: "user", content: text))
        let model = self.model
        let resume = continuation
        task = Task { [weak self] in await self?.runAgent(model: model, resuming: resume) }
    }

    /// The ReAct tool-calling loop, ported from src/lib/assistant/agent.ts `runAgent`. Resends the
    /// full scratchpad each step; executes any requested tools and feeds their JSON output back as
    /// `role:"tool"` messages; stops when the model answers with no tool calls (or hits maxSteps).
    /// When `resuming` is provided (from "Continue"), it picks up that stashed scratchpad instead of
    /// rebuilding from history — so the accumulated tool calls/results aren't lost.
    private func runAgent(model: String, resuming: [ChatMessage]? = nil) async {
        var wire = resuming ?? buildWireMessages() // system + user/assistant history (typing skipped)
        let ctx = ToolContext(engine: engine)

        for _ in 0 ..< Self.maxSteps {
            if Task.isCancelled {
                return
            }
            let resp: ChatResponse
            do {
                resp = try await LLM.chat(messages: wire, model: model, tools: AssistantTools.defs)
            } catch {
                if !Task.isCancelled {
                    finish(error: error)
                }
                return
            }
            if Task.isCancelled {
                return
            }

            // Record the assistant turn (content + any requested tool calls) in the scratchpad.
            wire.append(ChatMessage(role: "assistant", content: resp.content,
                                    toolCalls: resp.toolCalls.isEmpty ? nil : resp.toolCalls))

            if resp.toolCalls.isEmpty {
                finish(text: resp.content); return
            }

            switch await executeBatch(&wire, resp.toolCalls, startAt: 0, bypassFirstAudit: false,
                                      ctx: ctx, model: model) {
            case .completed: continue
            case .halted: return // blocked (state stashed for "Allow") or cancelled
            }
        }
        // Hit the step ceiling — stash the scratchpad and offer to continue (like the web's resumeId).
        resumeWire = wire
        replaceTyping(with: "I paused after several steps to check in.")
        messages.append(ChatTurn(role: .resume, text: ""))
        busy = false
    }

    private enum BatchOutcome { case completed, halted }

    /// Execute one LLM step's batch of tool calls, starting at `startAt`. Mutating tools are gated
    /// by the sandboxed auditor; a denial stashes (wire, calls, index) in `blockedState`, posts an
    /// interactive blocked card, and halts the turn. The card's "Allow" resumes from that exact call
    /// with the audit bypassed — the user's explicit override (the web's /api/assistant/allow).
    private func executeBatch(_ wire: inout [ChatMessage], _ calls: [ToolCall], startAt: Int,
                              bypassFirstAudit: Bool, ctx: ToolContext, model: String) async -> BatchOutcome {
        for i in startAt ..< calls.count {
            let call = calls[i]
            guard let tool = AssistantTools.tool(named: call.function.name) else {
                wire.append(ChatMessage(role: "tool",
                                        content: JSONValue.obj(["error": .str("unknown tool: \(call.function.name)")])
                                            .jsonString,
                                        toolCallId: call.id))
                continue
            }
            let args = JSONValue.parse(call.function.arguments)

            if !tool.readOnly, !(bypassFirstAudit && i == startAt) {
                let verdict = await Auditor.audit(userTurns: userTurns(), userAllowed: allowedOverrides,
                                                  call: call, engine: engine, model: model)
                if Task.isCancelled {
                    return .halted
                }
                if verdict.decision == .deny {
                    blockedState = BlockedState(wire: wire, calls: calls, index: i, reason: verdict.reason)
                    insertBeforeTyping(ChatTurn(role: .blocked, text: "",
                                                blockedReq: BlockedRequest(
                                                    toolName: call.function.name,
                                                    reason: verdict.reason
                                                )))
                    messages.removeAll { $0.role == .typing }
                    busy = false
                    persistCurrent()
                    return .halted
                }
            }

            let started = Date()
            let output = await run(tool, args, ctx)
            if Task.isCancelled {
                return .halted
            }
            let result = JSONValue.parse(output)
            if tool.confirm, result["staged"]?.boolValue == true, let id = result["id"]?.stringValue {
                // Resolve-only delete → an interactive confirmation card, not a plain chip.
                addConfirm(ConfirmRequest(id: id,
                                          title: result["title"]?.stringValue ?? "item",
                                          kind: result["kind"]?.stringValue ?? "",
                                          date: result["date"]?.stringValue ?? "",
                                          occurrenceDate: result["occurrenceDate"]?.stringValue))
            } else {
                // Every other tool call — read or write — posts an expandable action bubble.
                // Compact JSON is stored; the card renders it as structured rows (web-app style).
                let detail = ActionDetail(params: args.jsonString,
                                          result: String(result.jsonString.prefix(4000)),
                                          seconds: Date().timeIntervalSince(started))
                addAction(tool.card(args, result: result), icon: tool.actionKind.icon, detail: detail)
                await paceToTouchedItem(tool, result)
            }
            wire.append(ChatMessage(role: "tool", content: output, toolCallId: call.id))
        }
        return .completed
    }

    /// "Allow" on a blocked card — the user's explicit override. Re-runs the denied call with the
    /// auditor bypassed, finishes the interrupted batch, then rejoins the agent loop.
    func allowBlocked(_ turnId: UUID) {
        guard let bs = blockedState, !busy else { return }
        blockedState = nil
        // Remember the override: later audits see what the user already approved, so a batch of
        // near-identical edits doesn't demand one "Allow" per item.
        let call = bs.calls[bs.index]
        allowedOverrides.append("\(call.function.name)(\(call.function.arguments))")
        if let i = messages.firstIndex(where: { $0.id == turnId }) {
            messages[i].blockedReq?.status = .allowed
        }
        messages.append(ChatTurn(role: .typing, text: ""))
        busy = true
        let model = self.model
        task = Task { [weak self] in await self?.resumeAllowed(bs, model: model) }
    }

    private func resumeAllowed(_ bs: BlockedState, model: String) async {
        var wire = bs.wire
        let ctx = ToolContext(engine: engine)
        switch await executeBatch(&wire, bs.calls, startAt: bs.index, bypassFirstAudit: true,
                                  ctx: ctx, model: model) {
        case .halted: return // a LATER call in the batch got blocked (new card posted)
        case .completed: await runAgent(model: model, resuming: wire)
        }
    }

    /// "Tell it what to do" on a blocked card — drop the stashed run; the composer takes over.
    func dismissBlocked(_ turnId: UUID) {
        blockedState = nil
        if let i = messages.firstIndex(where: { $0.id == turnId }) {
            messages[i].blockedReq?.status = .dismissed
        }
        persistCurrent()
    }

    /// Chip tap — toggle an action bubble's expandable details.
    func toggleExpanded(_ turnId: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == turnId }) else { return }
        messages[i].expanded.toggle()
    }

    /// Run one tool, returning its output as a JSON string for the tool message.
    private func run(_ tool: any AssistantTool, _ args: JSONValue, _ ctx: ToolContext) async -> String {
        do {
            return try await tool.run(args, ctx).jsonString
        } catch {
            return JSONValue.obj(["error": .str(error.localizedDescription)]).jsonString
        }
    }

    /// The user's verbatim messages — the only untrusted input the auditor is allowed to see.
    private func userTurns() -> [String] {
        messages.filter { $0.role == .user }.map(\.text)
    }

    /// Insert a tool-activity chip just above the trailing typing indicator.
    private func addAction(_ text: String, icon: String, detail: ActionDetail? = nil) {
        insertBeforeTyping(ChatTurn(role: .action, text: text, icon: icon, detail: detail))
    }

    /// Insert an interactive delete-confirmation card just above the trailing typing indicator.
    private func addConfirm(_ req: ConfirmRequest) {
        insertBeforeTyping(ChatTurn(role: .confirm, text: "", confirm: req))
    }

    private func insertBeforeTyping(_ turn: ChatTurn) {
        if let i = messages.lastIndex(where: { $0.role == .typing }) {
            messages.insert(turn, at: i)
        } else {
            messages.append(turn)
        }
    }

    /// Confirm-card buttons call this. Confirmed → navigate to the item, then delete (the whole
    /// item, or — for an occurrence-scoped request — just that date's exdate hole); else cancel.
    func resolveDelete(_ turnId: UUID, confirmed: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == turnId }),
              var req = messages[i].confirm, req.status == .pending else { return }
        if confirmed, let e = engine {
            if let (y, m, _) = e.dateOf(req.id) {
                e.setView(year: y, zoom: "month", focusedMonth: m)
            }
            if let od = req.occurrenceDate, let (oy, om, oday) = parseDate(od) {
                e.deleteOccurrence(req.id, occKey(req.id, YMD(oy, om, oday)))
            } else {
                e.remove(req.id)
            }
        }
        req.status = confirmed ? .confirmed : .cancelled
        messages[i].confirm = req
        persistCurrent()
    }

    /// After a create/update, move the calendar to the item's month so the change is visible, with a
    /// short pause to let the move animate — mirrors the web's post-mutation navigate + pacing.
    private func paceToTouchedItem(_ tool: any AssistantTool, _ result: JSONValue) async {
        guard tool.actionKind == .createEvent || tool.actionKind == .updateEvent,
              let id = result["id"]?.stringValue, let e = engine,
              let (y, m, _) = e.dateOf(id) else { return }
        e.setView(year: y, zoom: "month", focusedMonth: m)
        try? await Task.sleep(for: .milliseconds(450))
    }

    /// Resume a run that hit the step ceiling. Called by a `.resume` card's "Continue" button.
    func continueChat(_ turnId: UUID) {
        guard let wire = resumeWire, !busy else { return }
        resumeWire = nil
        if let i = messages.firstIndex(where: { $0.id == turnId }) {
            messages[i].resumeConsumed = true
        }
        messages.append(ChatTurn(role: .typing, text: ""))
        busy = true
        let model = self.model
        task = Task { [weak self] in await self?.runAgent(model: model, resuming: wire) }
    }

    private func finish(text: String) {
        resumeWire = nil // a completed turn has nothing left to resume
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        replaceTyping(with: body.isEmpty ? "_(no response)_" : body)
        busy = false
        persistCurrent()
    }

    private func finish(error: Error) {
        replaceTyping(with: "⚠️ " + error.localizedDescription)
        busy = false
        persistCurrent()
    }

    func stop() {
        task?.cancel(); task = nil
        resumeWire = nil; blockedState = nil
        messages.removeAll { $0.role == .typing }
        busy = false
        persistCurrent()
    }

    /// Bumped to ask the conversation view to focus the composer (the input view observes it).
    private(set) var focusInput = 0

    /// Put the keyboard focus back in the composer (blocked-card "Tell it what to do", etc.).
    func requestInputFocus() {
        focusInput &+= 1
    }

    public func newChat() {
        task?.cancel(); task = nil
        resumeWire = nil; blockedState = nil
        persistCurrent()
        messages.removeAll()
        currentId = nil
        busy = false
        focusInput &+= 1 // a fresh chat starts with the input box ready to type
    }

    // ── Conversation history ─────────────────────────────────────────────────────────

    /// Switch the live transcript to a saved conversation (nil → a fresh, empty chat). Any
    /// in-flight run is stopped and the outgoing transcript saved first.
    func selectConversation(_ id: UUID?) {
        guard id != currentId else { return }
        task?.cancel(); task = nil
        resumeWire = nil; blockedState = nil; busy = false
        allowedOverrides = [] // approvals are per conversation
        persistCurrent()
        if let id, let convo = conversations.first(where: { $0.id == id }) {
            messages = Self.sanitized(convo.turns)
            currentId = id
        } else {
            messages = []
            currentId = nil
        }
    }

    func deleteConversation(_ id: UUID) {
        store.delete(id)
        if currentId == id {
            task?.cancel(); task = nil
            resumeWire = nil; blockedState = nil; busy = false
            messages = []
            currentId = nil
        }
    }

    /// Mirror the live transcript into the shared store (creating the entry on first user message).
    /// Transient typing rows are dropped. Ranking/timestamps live in ConversationStore.record.
    private func persistCurrent() {
        guard let firstUser = messages.first(where: { $0.role == .user }) else { return }
        let id = currentId ?? UUID()
        currentId = id
        store.record(id: id, title: Self.title(from: firstUser.text),
                     turns: messages.filter { $0.role != .typing })
    }

    /// Flush the live transcript to the store NOW (before handing this thread to another surface).
    func persistNow() {
        persistCurrent()
    }

    /// Pending interactive cards can't survive a reload — their stashed run state (the blocked
    /// batch, the resume scratchpad) lives only in memory. Downgrade them to settled states.
    private static func sanitized(_ turns: [ChatTurn]) -> [ChatTurn] {
        turns.map { turn in
            var t = turn
            if t.confirm?.status == .pending {
                t.confirm?.status = .cancelled
            }
            if t.blockedReq?.status == .pending {
                t.blockedReq?.status = .dismissed
            }
            if t.role == .resume {
                t.resumeConsumed = true
            }
            return t
        }
    }

    private static func title(from text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }

    private func replaceTyping(with text: String) {
        if let i = messages.lastIndex(where: { $0.role == .typing }) {
            messages[i] = ChatTurn(role: .assistant, text: text)
        } else {
            messages.append(ChatTurn(role: .assistant, text: text))
        }
    }

    // ── Prompt assembly ──────────────────────────────────────────────────────────────

    private func buildWireMessages() -> [ChatMessage] {
        var wire: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt())]
        for turn in messages {
            switch turn.role {
            case .user: wire.append(ChatMessage(role: "user", content: turn.text))
            case .assistant: wire.append(ChatMessage(role: "assistant", content: turn.text))
            case .typing, .action, .confirm, .resume, .blocked:
                break // transient UI-only rows — not LLM history
            }
        }
        return wire
    }

    /// The system prompt — ported from the web's buildSystem (src/lib/assistant/agent.ts), with
    /// native-only additions (daily notes, track rename, scoped-reads convention). Recurrence and
    /// per-occurrence delete are supported natively too, matching the web text.
    private func systemPrompt() -> String {
        let now = Date()
        let today = isoDayString(now)
        let weekday = Self.weekdayFmt.string(from: now)
        var lines: [String] = [
            "You are the assistant inside MagnifiCal, a research calendar app. You help the user understand and plan their calendar.",
            "Today is \(weekday), \(today).",
            viewContextLine(),
            timezoneLine(),
        ]
        if let mem = memoryLine() {
            lines.append(mem)
        }
        lines += [
            "",
            "Event kinds: 'timed' (an hourly event on one day), 'band' (a multi-day bar pinned to the year-scale track lanes — that's just WHERE it's shown; it does NOT mean the event lasts all day, so never call it 'all-day'), 'deadline' (a single moment, optionally in a timezone like AOE). Each has title, color, tags (string[]), notes (markdown), optional repeat.",
            "",
            "Tools: get_screen_state grounds 'this week'/'next month' (and reports today's date); list_events reads the calendar; get_event fetches one item's full detail (notes, tags, lane, repeat); get_daily_note / set_daily_note read and edit the per-day dashboard note (markdown, often holds the day's TODOs and plans); list_todos gathers every TODO checkbox from event notes AND daily notes (the TODO panel) — for 'what should I work on' questions, combine it with list_events; web_search then web_open look things up online; create_event adds an event (with optional repeat: weekly days, until, exdates for holidays); update_event edits one (patch repeat/notes/appendNotes too); delete_event removes one (or one occurrence via occurrenceDate); set_track_name renames a monthly lane; set_view navigates the user's view (year/month/week zoom, or a date for the day view); remember saves a durable preference for next time.",
            "",
            "You can create, edit, and delete events, and navigate the view. Creates and edits apply immediately (auditor-checked). DELETES require the user to confirm in the UI: after you call delete_event, tell the user you've QUEUED the deletion for their confirmation — do NOT say it's already deleted. To remove a single occurrence of a recurring event (a one-time skip), pass occurrenceDate to delete_event — never delete the whole series for one skip. To edit/delete, first find the event's id via list_events.",
            "Not built yet (you have NO tools for these): People / contacts (look up or add a person's name & email); Projects (link work to a project); Funding (grants / funding sources a proposal or trip is tied to); Travel (trips and reimbursements); Papers / Proposals (track submissions and grant proposals). If a request needs one, do what you CAN with the calendar (e.g. put a person's name/email or other detail into the relevant event's notes), tell the user that module isn't available yet, and never pretend you did it.",
            "",
            "Conventions:",
            "- Scope your reads to the question: for 'today'/'tomorrow'/'this week', call list_events with a from/to window covering just those days (bands overlapping the window are included) — never fetch a whole year to answer about one day. Use query to search by text.",
            "- Colors are personal. Before choosing one, read the user's existing similar events with list_events and reuse their color/tags; don't guess. Palette: default, red, orange, yellow, green, blue, purple.",
            "- Conference CFP deadlines are almost always Anywhere-on-Earth: create a 'deadline' with originTz:\"AOE\" due 23:59 on the date.",
            "- Finding an event: search across ALL kinds (omit `kind` in list_events). A 'deadline' the user names may actually be stored as a timed or all-day (band) event — don't conclude it doesn't exist just because it isn't a 'deadline'.",
            "- Event kinds: a deadline (a due-moment) and a timed event (hourly) carry TIME; a band is an all-day, multi-day bar on a monthly track lane. Deadline/timed are the single source of truth — they have finer info. Do NOT create a separate all-day band that merely mirrors a deadline/timed event (no duplicates).",
            "- Promotion (promoteTrack — mirroring a deadline/timed event onto a monthly track lane as a ghost band) is strictly OPT-IN: NEVER set promoteTrack unless the user explicitly asks to promote/pin items to a track or a saved memory says to. Creating events plain is the default. If the user asks to un-promote, clear promoteTrack.",
            "- When the user DOES ask to promote: call get_tracks and match the lane NAME to the event's topic (e.g. a paper-submission deadline in a month whose lane 3 is 'research' → promoteTrack 3).",
            "- Timezones: when a source states times in a specific zone (a Japanese broadcast at 24:00 JST, a conference CfP in AOE), pass `timezone` (IANA id like Asia/Tokyo, or AOE) with date/start/end AS THAT ZONE'S OWN WALL CLOCK. NEVER convert to the user's zone yourself — conversion is error-prone and destroys the original time; the calendar anchors the item to its zone and converts for display automatically. Japanese late-night notation ≥24:00 rolls into the next date (25:30 Sun → 01:30 Mon; 24:00 Sun → 00:00 Mon).",
            "- The `notes` field is MARKDOWN, rendered in the event drawer. Write real multi-line Markdown (headings, lists, links); newlines are ordinary JSON string newlines — NEVER write a literal backslash-n sequence in the text.",
            "- Tag every item you create: 2–3 short lowercase tags covering topic and life-area (e.g. anime, entertainment, life; research, deadline-work). Reuse the user's existing tag vocabulary when list_events/get_event shows tags on similar items, instead of inventing near-duplicates.",
            "- Track numbering is 1-BASED, top to bottom: track 1 is the topmost lane, track 4 the bottom. When the user says 'the 3rd track' or 'track 3' they mean track 3 in the tools — never shift by one. Lane NAMES vary per month (get_tracks), so match by name when the user gives a name, by number when they give a number.",
            "- Memory: when you learn a DURABLE, GENERAL fact (a color/tag convention, a contact's details, a default, a standing constraint), call remember so future sessions reuse it. Don't memorize one-off chatter, single events, or things already in the calendar. If a remembered fact is wrong or the user corrects it, call remember with the same key to update it, or forget to drop it.",
            "- To add a TODO, put a markdown checkbox in an event's notes with DSL tokens, e.g. `- [ ] submit abstract due:2026-07-01 p:!! #paper-submission @project:foo start:2026-06-15`. Priority MUST use the `p:` prefix with bang-count for the level — `p:!` (low) … `p:!!!` (high) … `p:!!!!!` (top); bare `!!!` is NOT a priority. Other tokens: `due:YYYY-MM-DD` (accepts `today`/`tomorrow`/`3d`/`5pm`), `start:` (defer until), `#tag`, `@person` / `@project:slug`, `followup:30d` (off the event's end). Use real markdown links [label](url).",
            "- Don't fabricate facts (dates, URLs). If something isn't known yet, mark it tentative, add a TODO to confirm, or ask.",
            "",
            "Every create is checked by a separate safety auditor. If a tool result says the action was denied/blocked, tell the user it was blocked and the reason — do NOT claim you made the change, and do NOT retry the same action.",
            "",
            "Response style:",
            "- Be brief and conversational. Don't pad. NEVER use markdown tables or raw HTML (no <br>, <td>) — use short bullets or plain prose.",
            "- Describe events naturally (day, time, title; for a multi-day band give its date range). Do NOT surface internal fields (color, track, tags, ids, kind) and NEVER label an event 'all-day' or mention bands/tracks — unless the user explicitly asks.",
            "- DON'T ask clarifying questions for routine requests — make the sensible default assumption and just answer. (\"next week\" = the upcoming Mon–Sun; \"my week\" = the focused week.) Only ask when a request is genuinely ambiguous, or before a consequential/irreversible change.",
            "- For overview questions (\"what's on my radar\", \"what's coming up\", \"how's my week\"): give a SHORT, prioritized highlight of just the few most important or time-sensitive items (deadlines, key meetings) — do NOT list everything. Offer to show the full list if they want it. Enumerate fully only when the user explicitly asks to list events.",
            "- Make sure any weekday you mention actually matches the date.",
        ]
        return lines.joined(separator: "\n")
    }

    /// Remembered facts injected into the prompt — the web's memory line, verbatim phrasing.
    private func memoryLine() -> String? {
        let mem = AssistantMemory.recallAll()
        guard !mem.isEmpty else { return nil }
        return "What you remember about this user (reuse it; don't re-derive or re-ask): \(JSONValue.object(mem).jsonString)"
    }

    /// The timezone every time in the tools + this prompt is expressed in — the user's current view zone.
    /// (Events are anchored to their own zones internally, but the assistant always reads/writes in this one.)
    private func timezoneLine() -> String {
        guard let engine else { return "" }
        let tz = DeadlineTZ.concrete(engine.mainTz) // resolve "auto" → the device zone id
        let name = CalendarTimezones.label(for: tz)
        let abbr = DeadlineTZ.shortLabel(tz, at: Date())
        return "All times you read (list_events, get_event) and write (create_event, update_event) are in the user's CURRENT timezone: \(name) (\(abbr)). get_event also returns each item's own 'anchorTz' for reference, but you always work in the current zone."
    }

    /// The web's view-context line: year, zoom, focused month (0-based, like ViewContext).
    private func viewContextLine() -> String {
        guard let engine else { return "The user's current view is unavailable." }
        let zoom = engine.isDayLevel ? "day" : engine.isWeekLevel ? "week"
            : engine.isMonthLevel ? "month" : "year"
        return "The user's current view: year \(engine.year), zoom \"\(zoom)\", focused month \(engine.focus) (0=Jan)."
    }

    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEEE"; return f
    }()
}
