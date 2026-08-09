// The persisted conversation list, shared by BOTH assistant sessions (the standalone window and
// the quick-ask callout each hold their own live AssistantState, but mirror into this one store —
// so the sidebar shows every thread, whichever surface it was typed in).

import Foundation
import Observation
import os

@MainActor
@Observable
public final class ConversationStore {
    private(set) var conversations: [StoredConversation] = []

    @ObservationIgnored private lazy var url: URL = {
        // Demo/recording/eval sessions get an isolated conversation store too (mirrors
        // calendarKitBaseDir) — a scripted session must never pollute the user's real chats.
        let base: URL = if let demo = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !demo.isEmpty {
            URL(fileURLWithPath: demo, isDirectory: true)
        } else {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
        let dir = base.appendingPathComponent("CalendarKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }()

    public init() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([StoredConversation].self, from: data) else { return }
        conversations = list
    }

    /// Mirror a live transcript into the store. Rank is by LAST ACTIVE MESSAGE: the timestamp and
    /// move-to-front happen only when the turns actually changed (chip expansion is cosmetic and
    /// ignored in the comparison, but still stored). Inserts a new entry when `id` is unknown.
    func record(id: UUID, title: String, turns: [ChatTurn]) {
        func normalized(_ ts: [ChatTurn]) -> [ChatTurn] {
            ts.map { var t = $0; t.expanded = false; return t }
        }
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            guard normalized(conversations[idx].turns) != normalized(turns) else {
                conversations[idx].turns = turns // keep cosmetic state without re-ranking
                save()
                return
            }
            conversations[idx].turns = turns
            conversations[idx].updatedAt = Date()
            if idx != 0 {
                conversations.insert(conversations.remove(at: idx), at: 0)
            } // newest first
        } else {
            conversations.insert(StoredConversation(id: id, title: title, updatedAt: Date(), turns: turns),
                                 at: 0)
        }
        save()
    }

    func turns(for id: UUID) -> [ChatTurn]? {
        conversations.first { $0.id == id }?.turns
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        save()
    }

    private func save() {
        // Conversation history is user data too — write failures are logged, never swallowed.
        do {
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "dev.magnifical.calendar", category: "chat")
                .error("conversation store write FAILED: \(error.localizedDescription, privacy: .public)")
        }
    }
}
