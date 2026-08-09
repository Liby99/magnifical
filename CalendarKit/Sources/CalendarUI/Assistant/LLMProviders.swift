// The LLM provider abstraction. The agent framework (AssistantState, Auditor) talks ONLY to the
// `LLM` facade + `LLMProvider` protocol — never to a concrete endpoint. Four backends:
//
//   • gateway    — any OpenAI-compatible proxy (user-supplied base URL; verified against the
//                  web app's gateway client: POST {base}/compat/chat/completions, Bearer key).
//   • openai     — api.openai.com/v1/chat/completions (same wire shape).
//   • anthropic  — Anthropic Messages API (/v1/messages; tools → input_schema, tool_use/tool_result
//                  content blocks; docs.anthropic.com "Messages").
//   • bedrock    — Amazon Bedrock Converse API with SigV4 request signing (see BedrockProvider.swift).
//
// The canonical in-app wire format stays the OpenAI-shaped ChatMessage/ToolCall/ChatResponse
// (LLMClient.swift) — adapters convert at their boundary. Config is per-provider and persists
// side-by-side: secrets in the Keychain, the rest as JSON in UserDefaults. The assistant uses the
// selected provider once its key/model (+ gateway URL) are set; "Test Connection" is an optional
// verification aid, not a gate.

import Foundation

// ── Provider identity + per-provider settings ───────────────────────────────────────

enum ProviderID: String, CaseIterable, Codable, Identifiable {
    case gateway, openai, anthropic, bedrock
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .gateway: "Gateway (OpenAI-compatible)"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic (Claude)"
        case .bedrock: "Amazon Bedrock"
        }
    }

    /// Curated model choices shown in Settings. Every provider also accepts a custom model id.
    var supportedModels: [(id: String, label: String)] {
        switch self {
        case .gateway: AssistantModels.all.map { ($0.id, $0.label) }
        case .openai: [("gpt-5.2", "GPT-5.2"), ("gpt-5.2-mini", "GPT-5.2 mini"), ("gpt-5.1", "GPT-5.1")]
        case .anthropic: [("claude-sonnet-5", "Claude Sonnet 5"),
                          ("claude-opus-4-8", "Claude Opus 4.8"),
                          ("claude-haiku-4-5-20251001", "Claude Haiku 4.5")]
        case .bedrock: [("global.anthropic.claude-sonnet-5-20250929-v1:0", "Claude Sonnet 5 (global)"),
                        ("us.anthropic.claude-haiku-4-5-20251001-v1:0", "Claude Haiku 4.5 (us)")]
        }
    }
}

/// Non-secret, per-provider persisted config (defaults key "cc.llm.provider.<id>").
struct ProviderSettings: Codable, Equatable {
    var model: String = ""
    var baseURL: String = "" // gateway only
    var region: String = "us-east-1" // bedrock only
    var testedOK: Bool = false

    init() {}

    /// Tolerant decode (the RichFields pattern): a field ADDED in a newer build must not fail the
    /// whole blob — that silently reset `testedOK` on every schema-growing rebuild, re-demanding
    /// "Test Connection" even though the stored key and model were intact.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        testedOK = try c.decodeIfPresent(Bool.self, forKey: .testedOK) ?? false
    }
}

/// Persistence + construction. Secrets live in the Keychain; the gateway key keeps the legacy
/// "jhu-gateway" account so existing users' keys migrate with zero touch.
enum ProviderStore {
    static let activeKey = "cc.llm.activeProvider"

    static var active: ProviderID? {
        get {
            if let raw = UserDefaults.standard.string(forKey: activeKey) {
                return raw.isEmpty ? nil : ProviderID(rawValue: raw)
            }
            // Migration default: a pre-existing gateway key pre-selects Gateway.
            // Fresh installs default to none.
            return secret(.gateway).isEmpty ? nil : .gateway
        }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: activeKey) }
    }

    static func settings(_ id: ProviderID) -> ProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: "cc.llm.provider.\(id.rawValue)"),
              let s = try? JSONDecoder().decode(ProviderSettings.self, from: data) else {
            var s = ProviderSettings()
            s.model = id.supportedModels.first?.id ?? ""
            return s // gateway baseURL has NO default — the user types their own endpoint
        }
        return s
    }

    static func save(_ id: ProviderID, _ s: ProviderSettings) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: "cc.llm.provider.\(id.rawValue)")
        }
    }

    /// Keychain account for a provider's (primary) secret.
    static func secretAccount(_ id: ProviderID, field: String = "key") -> String {
        if id == .gateway, field == "key" {
            return LLMClient.keychainAccount
        } // legacy migration
        return "llm-\(id.rawValue)-\(field)"
    }

    static func secret(_ id: ProviderID, field: String = "key") -> String {
        (Keychain.get(account: secretAccount(id, field: field)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The active provider is usable: selected with its secret(s) + model (+ endpoint for the
    /// gateway). Test Connection is OPTIONAL — a verification aid, not a gate; `testedOK` is
    /// only the green status line in Settings.
    static var activeReady: Bool {
        guard let id = active else { return false }
        guard !settings(id).model.isEmpty else { return false }
        switch id {
        case .gateway: return !secret(id).isEmpty && !settings(id).baseURL
            .trimmingCharacters(in: .whitespaces).isEmpty
        case .bedrock: return !secret(id, field: "akid").isEmpty && !secret(id, field: "secret").isEmpty
        default: return !secret(id).isEmpty
        }
    }

    static var activeModel: String {
        active.map { settings($0).model } ?? AssistantModels.fallback
    }

    static func provider(_ id: ProviderID) -> LLMProvider {
        let s = settings(id)
        switch id {
        case .gateway:
            return OpenAICompatProvider(id: id, endpoint: s.baseURL.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/compat/chat/completions",
                key: secret(id))
        case .openai:
            return OpenAICompatProvider(id: id, endpoint: "https://api.openai.com/v1/chat/completions",
                                        key: secret(id))
        case .anthropic:
            return AnthropicProvider(key: secret(id))
        case .bedrock:
            return BedrockProvider(region: s.region, accessKey: secret(id, field: "akid"),
                                   secretKey: secret(id, field: "secret"),
                                   sessionToken: secret(id, field: "session"))
        }
    }
}

// ── The abstraction ────────────────────────────────────────────────────────────────

protocol LLMProvider {
    var id: ProviderID { get }
    func chat(messages: [ChatMessage], model: String, tools: [ToolDef],
              temperature: Double, maxTokens: Int) async throws -> ChatResponse
}

extension LLMProvider {
    /// A cheap round-trip proving endpoint + credentials + model all work.
    func testConnection(model: String) async throws {
        _ = try await chat(messages: [ChatMessage(role: "user", content: "Reply with the single word: ok")],
                           model: model, tools: [], temperature: 0, maxTokens: 16)
    }
}

/// What the agent framework calls. Routes to the ACTIVE provider; throws `.notConfigured`
/// when none is selected/tested (callers surface a Settings pointer instead).
enum LLM {
    static func chat(messages: [ChatMessage], model: String, tools: [ToolDef] = [],
                     temperature: Double = 1.0, maxTokens: Int = 2048) async throws -> ChatResponse {
        guard let id = ProviderStore.active, ProviderStore.activeReady else { throw LLMError.missingKey }
        return try await ProviderStore.provider(id).chat(messages: messages, model: model, tools: tools,
                                                         temperature: temperature, maxTokens: maxTokens)
    }
}

// ── OpenAI-compatible adapter (gateway + OpenAI) ────────────────────────────────────

struct OpenAICompatProvider: LLMProvider {
    let id: ProviderID
    let endpoint: String
    let key: String

    func chat(messages: [ChatMessage], model: String, tools: [ToolDef],
              temperature: Double, maxTokens: Int) async throws -> ChatResponse {
        guard !key.isEmpty else { throw LLMError.missingKey }
        guard let url = URL(string: endpoint) else {
            throw LLMError.http(status: 0, body: "invalid endpoint: \(endpoint)")
        }
        return try await LLMClient.chatOpenAICompat(url: url, headers: ["Authorization": "Bearer \(key)"],
                                                    messages: messages, model: model, tools: tools,
                                                    temperature: temperature, maxTokens: maxTokens)
    }
}

// ── Anthropic Messages API adapter ──────────────────────────────────────────────────

struct AnthropicProvider: LLMProvider {
    let id: ProviderID = .anthropic
    let key: String

    func chat(messages: [ChatMessage], model: String, tools: [ToolDef],
              temperature: Double, maxTokens: Int) async throws -> ChatResponse {
        guard !key.isEmpty else { throw LLMError.missingKey }
        // Convert the OpenAI-shaped wire → Messages API. System messages lift to `system`;
        // assistant tool calls become tool_use blocks; role:"tool" results become user-turn
        // tool_result blocks (consecutive ones merge into one user turn — the API requires
        // strictly alternating user/assistant roles).
        var system = ""
        var out: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []
        func flushToolResults() {
            if !pendingToolResults.isEmpty {
                out.append(["role": "user", "content": pendingToolResults]); pendingToolResults = []
            }
        }
        for m in messages {
            switch m.role {
            case "system":
                system += (system.isEmpty ? "" : "\n") + (m.content ?? "")
            case "tool":
                pendingToolResults.append(["type": "tool_result",
                                           "tool_use_id": m.toolCallId ?? "",
                                           "content": m.content ?? ""])
            case "assistant":
                flushToolResults()
                var blocks: [[String: Any]] = []
                if let c = m.content, !c.isEmpty {
                    blocks.append(["type": "text", "text": c])
                }
                for tc in m.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(with: Data(tc.function.arguments.utf8))) ?? [:]
                    blocks.append(["type": "tool_use", "id": tc.id, "name": tc.function.name, "input": input])
                }
                if !blocks.isEmpty {
                    out.append(["role": "assistant", "content": blocks])
                }
            default: // user
                flushToolResults()
                out.append(["role": "user", "content": m.content ?? ""])
            }
        }
        flushToolResults()

        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": out, "temperature": temperature]
        if !system.isEmpty {
            body["system"] = system
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> [String: Any] in
                let schema = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(t.parameters))) ?? [:]
                return ["name": t.name, "description": t.description, "input_schema": schema]
            }
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 90
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await LLMClient.send(req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else { throw LLMError.badResponse }
        var text = ""
        var calls: [ToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text": text += (block["text"] as? String) ?? ""
            case "tool_use":
                let input = block["input"] ?? [:]
                let args = (try? JSONSerialization.data(withJSONObject: input))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                calls.append(ToolCall(id: (block["id"] as? String) ?? UUID().uuidString,
                                      function: .init(name: (block["name"] as? String) ?? "", arguments: args)))
            default: break
            }
        }
        return ChatResponse(content: text, toolCalls: calls,
                            finishReason: root["stop_reason"] as? String, reasoning: nil)
    }
}
