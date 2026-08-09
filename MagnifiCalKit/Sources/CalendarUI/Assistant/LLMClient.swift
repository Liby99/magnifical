// A thin OpenAI-compatible chat client — the native counterpart of the web app's
// the web app's gateway client. It POSTs OpenAI-format JSON to `{base}/compat/chat/completions`
// with the Keychain bearer key and parses the reply.
//
// This is NOT a LiteLLM reimplementation: the agent loop, prompts, and guardrails are our own
// application logic (ported separately). The client just speaks OpenAI-compat, so any OpenAI-compat gateway
// works today and an external LiteLLM proxy can be swapped in later by changing only the base URL.
// Non-streaming (the gateway beta doesn't stream) — the UI shows a typing indicator meanwhile.

import Foundation

// ── Wire types (OpenAI chat-completions shape) ──────────────────────────────────────

/// One chat message. `toolCalls`/`toolCallId` are unused in v1 but defined now for the Phase-2
/// tool loop.
struct ChatMessage: Codable {
    var role: String // "system" | "user" | "assistant" | "tool"
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?

    init(role: String, content: String?, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallId = toolCallId
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

struct ToolCall: Codable {
    var id: String
    var type: String = "function"
    var function: Function
    struct Function: Codable { var name: String; var arguments: String } // arguments = JSON string
}

/// A function/tool the model may call. Defined for Phase 2; unused in v1.
struct ToolDef: Codable {
    var name: String
    var description: String
    var parameters: JSONValue // JSON Schema
}

/// The parsed assistant turn.
struct ChatResponse {
    var content: String
    var toolCalls: [ToolCall]
    var finishReason: String?
    var reasoning: String?
}

enum LLMError: LocalizedError {
    case missingKey
    case http(status: Int, body: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No AI provider is configured. Pick one and add its key in Settings → API Keys."
        case let .http(status, body):
            let trimmed = body.count > 300 ? String(body.prefix(300)) + "…" : body
            return "The assistant service returned an error (\(status)). \(trimmed)"
        case .badResponse:
            return "The assistant returned an unexpected response."
        }
    }
}

// ── Client ──────────────────────────────────────────────────────────────────────────

enum LLMClient {
    /// No built-in backend: the user types their gateway's base URL in Settings ▸ API Keys.
    static let baseURLKey = "cc.assistant.baseURL"
    /// Legacy Keychain account id for the gateway key — the string predates the multi-provider
    /// settings and is kept verbatim so existing stored keys migrate with zero touch.
    static let keychainAccount = "jhu-gateway"

    private static var baseURL: String {
        let raw = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// One OpenAI-compat chat completion against an arbitrary endpoint (the gateway and OpenAI
    /// adapters both route here). Retries transient failures, mirroring the web client.
    static func chatOpenAICompat(url: URL, headers: [String: String],
                                 messages: [ChatMessage], model: String, tools: [ToolDef] = [],
                                 temperature: Double = 1.0, maxTokens: Int = 2048) async throws -> ChatResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model, messages: messages, temperature: temperature, maxTokens: maxTokens,
            tools: tools.isEmpty ? nil : tools.map { ToolWrapper(function: $0) }
        ))
        return try await parse(send(request))
    }

    /// Shared transport: POST with retries on 5xx/429/network (exponential backoff); returns the
    /// body on 2xx, throws LLMError.http otherwise. All provider adapters funnel through this.
    static func send(_ request: URLRequest) async throws -> Data {
        var lastError: Error = LLMError.badResponse
        for attempt in 0 ..< 3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 || (500 ... 599).contains(status) {
                    lastError = LLMError.http(status: status, body: String(decoding: data, as: UTF8.self))
                    try await backoff(attempt); continue
                }
                guard (200 ... 299).contains(status) else {
                    throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self))
                }
                return data
            } catch let error as LLMError {
                throw error // permanent (4xx / bad response) — don't retry
            } catch {
                lastError = error // network — retry
                if attempt < 2 {
                    try await backoff(attempt)
                }
            }
        }
        throw lastError
    }

    private static func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(400_000_000) * UInt64(attempt + 1))
    }

    private static func parse(_ data: Data) throws -> ChatResponse {
        guard let root = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let choice = root.choices.first else { throw LLMError.badResponse }
        let m = choice.message
        return ChatResponse(
            content: m.content ?? "",
            toolCalls: m.toolCalls ?? [],
            finishReason: choice.finishReason,
            reasoning: m.reasoningContent ?? m.reasoning
        )
    }

    /// Encoded request/response envelopes.
    private struct RequestBody: Encodable {
        var model: String
        var messages: [ChatMessage]
        var temperature: Double
        var maxTokens: Int
        var tools: [ToolWrapper]?
        enum CodingKeys: String, CodingKey { case model, messages, temperature, tools; case maxTokens = "max_tokens" }
    }

    private struct ToolWrapper: Encodable { var type = "function"; var function: ToolDef }

    private struct ResponseBody: Decodable {
        var choices: [Choice]
        struct Choice: Decodable {
            var message: Msg
            var finishReason: String?
            enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
        }

        struct Msg: Decodable {
            var content: String?
            var toolCalls: [ToolCall]?
            var reasoningContent: String?
            var reasoning: String?
            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case toolCalls = "tool_calls"
                case reasoningContent = "reasoning_content"
            }
        }
    }
}
