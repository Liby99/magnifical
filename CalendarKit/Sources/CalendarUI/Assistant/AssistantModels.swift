// Model catalog + transcript view types for the assistant panel.

import Foundation

// ── Model catalog ─────────────────────────────────────────────────────────────────
// Mirrors src/lib/assistant/models.ts. The gateway routes these provider-prefixed ids.

struct AssistantModel: Identifiable, Hashable {
    var id: String
    var label: String
    var note: String
}

enum AssistantModels {
    static let all: [AssistantModel] = [
        .init(id: "anthropic/claude-sonnet-4.6", label: "Claude Sonnet 4.6", note: "Anthropic"),
        .init(id: "openai/gpt-5.2", label: "GPT-5.2", note: "OpenAI"),
        .init(id: "workers-ai/@cf/zai-org/glm-5.2", label: "GLM-5.2", note: "Z.ai · open"),
        .init(id: "workers-ai/@cf/openai/gpt-oss-120b", label: "gpt-oss 120B", note: "open weights"),
        .init(id: "workers-ai/@cf/qwen/qwq-32b", label: "Qwen QwQ 32B", note: "reasoning"),
    ]
    static let fallback = all[0].id
    static let defaultsKey = "cc.assistant.model"

    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? id
    }
}

// ── Transcript view model ───────────────────────────────────────────────────────────

/// One rendered row in the transcript. `.typing` is a transient placeholder shown while the
/// assistant's reply is in flight. `.action` is a small tool-activity chip (create/edit/blocked).
/// `.confirm` is an interactive delete-confirmation card (Stage 3).
struct ChatTurn: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, typing, action, confirm, resume, blocked }
    var id = UUID()
    var role: Role
    var text: String
    var icon: String? = nil // SF Symbol for an .action chip
    var confirm: ConfirmRequest? = nil // payload for a .confirm card
    var resumeConsumed: Bool = false // a .resume ("Continue") card that's been tapped
    var detail: ActionDetail? = nil // expandable payload for an .action chip
    var expanded: Bool = false // the .action chip's disclosure state
    var blockedReq: BlockedRequest? = nil // payload for a .blocked card
}

/// The expandable details behind an action chip: what the tool was called with, what it returned,
/// and how long it took.
struct ActionDetail: Equatable, Codable {
    var params: String // pretty-printed tool arguments
    var result: String // pretty-printed (truncated) tool result
    var seconds: Double // tool execution time
}

/// A safety-check denial shown as an interactive card. "Allow" overrides the auditor (the user's
/// explicit consent) and resumes the run; "Tell it what to do" returns control to the composer.
struct BlockedRequest: Equatable, Codable {
    enum Status: String, Codable { case pending, allowed, dismissed }
    var toolName: String
    var reason: String
    var status: Status = .pending
}

/// One saved conversation for the sidebar — the live transcript mirrors into this on every
/// meaningful change, persisted as JSON in Application Support.
struct StoredConversation: Codable, Identifiable {
    var id = UUID()
    var title: String // derived from the first user message
    var updatedAt: Date
    var turns: [ChatTurn]
}

/// A staged deletion awaiting the user's confirmation in the transcript. `delete_event` resolves
/// this (without deleting); the card's buttons drive the actual removal — mirroring the web's
/// confirm-gated delete (resolve → confirm → execute).
struct ConfirmRequest: Equatable, Codable {
    enum Status: String, Codable { case pending, confirmed, cancelled }
    var id: String
    var title: String
    var kind: String
    var date: String
    var occurrenceDate: String? = nil // set → skip ONE occurrence of a recurrence, not the series
    var status: Status = .pending
}

// ── Minimal JSON value ──────────────────────────────────────────────────────────────
// Codable arbitrary JSON — carries tool JSON Schemas (ToolDef.parameters), tool arguments and
// results throughout the agent loop, and the assistant memory values.

indirect enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
