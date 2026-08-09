// Amazon Bedrock adapter: the Converse API over raw HTTPS with hand-rolled SigV4 signing
// (CryptoKit HMAC-SHA256 — no AWS SDK). Reference: docs.aws.amazon.com Bedrock API_runtime_Converse
// + aws-samples/sigv4-signing-examples (no-sdk).
//
//   POST https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/converse
//   system: [{text}], messages: [{role, content:[{text} | {toolUse} | {toolResult}]}],
//   toolConfig.tools: [{toolSpec:{name, description, inputSchema:{json}}}]; stopReason "tool_use".

import CryptoKit
import Foundation

struct BedrockProvider: LLMProvider {
    let id: ProviderID = .bedrock
    let region: String
    let accessKey: String
    let secretKey: String
    let sessionToken: String // empty = long-lived credentials

    func chat(messages: [ChatMessage], model: String, tools: [ToolDef],
              temperature: Double, maxTokens: Int) async throws -> ChatResponse {
        guard !accessKey.isEmpty, !secretKey.isEmpty else { throw LLMError.missingKey }

        // ── Wire → Converse shapes (same conversion strategy as the Anthropic adapter) ──
        var system: [[String: Any]] = []
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
                if let c = m.content, !c.isEmpty {
                    system.append(["text": c])
                }
            case "tool":
                pendingToolResults.append(["toolResult": [
                    "toolUseId": m.toolCallId ?? "",
                    "content": [["text": m.content ?? ""]],
                ]])
            case "assistant":
                flushToolResults()
                var blocks: [[String: Any]] = []
                if let c = m.content, !c.isEmpty {
                    blocks.append(["text": c])
                }
                for tc in m.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(with: Data(tc.function.arguments.utf8))) ?? [:]
                    blocks.append(["toolUse": ["toolUseId": tc.id, "name": tc.function.name, "input": input]])
                }
                if !blocks.isEmpty {
                    out.append(["role": "assistant", "content": blocks])
                }
            default:
                flushToolResults()
                out.append(["role": "user", "content": [["text": m.content ?? ""]]])
            }
        }
        flushToolResults()

        var body: [String: Any] = [
            "messages": out,
            "inferenceConfig": ["maxTokens": maxTokens, "temperature": temperature],
        ]
        if !system.isEmpty {
            body["system"] = system
        }
        if !tools.isEmpty {
            body["toolConfig"] = ["tools": tools.map { t -> [String: Any] in
                let schema = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(t.parameters))) ?? [:]
                return ["toolSpec": ["name": t.name, "description": t.description, "inputSchema": ["json": schema]]]
            }]
        }

        let host = "bedrock-runtime.\(region).amazonaws.com"
        let modelPath = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let path = "/model/\(modelPath)/converse"
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw LLMError.http(status: 0, body: "invalid bedrock region/model")
        }
        let payload = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = payload
        req.timeoutInterval = 90
        sign(&req, host: host, path: path, payload: payload)

        let data = try await LLMClient.send(req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { throw LLMError.badResponse }
        var text = ""
        var calls: [ToolCall] = []
        for block in content {
            if let t = block["text"] as? String {
                text += t
            }
            if let tu = block["toolUse"] as? [String: Any] {
                let input = tu["input"] ?? [:]
                let args = (try? JSONSerialization.data(withJSONObject: input))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                calls.append(ToolCall(id: (tu["toolUseId"] as? String) ?? UUID().uuidString,
                                      function: .init(name: (tu["name"] as? String) ?? "", arguments: args)))
            }
        }
        return ChatResponse(content: text, toolCalls: calls,
                            finishReason: root["stopReason"] as? String, reasoning: nil)
    }

    // ── SigV4 ───────────────────────────────────────────────────────────────────────

    private func sign(_ req: inout URLRequest, host: String, path: String, payload: Data) {
        let now = Date()
        let amzFmt = DateFormatter()
        amzFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        amzFmt.timeZone = TimeZone(identifier: "UTC")
        let amzDate = amzFmt.string(from: now)
        let dateStamp = String(amzDate.prefix(8))

        let payloadHash = SHA256.hash(data: payload).hex
        var headers: [(String, String)] = [("content-type", "application/json"),
                                           ("host", host),
                                           ("x-amz-date", amzDate)]
        if !sessionToken.isEmpty {
            headers.append(("x-amz-security-token", sessionToken))
        }
        headers.sort { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()

        // Canonical URI: each path segment percent-encoded (the model id contains ':' → %3A).
        let canonicalPath = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { seg -> String in
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                return String(seg).removingPercentEncoding.flatMap {
                    $0.addingPercentEncoding(withAllowedCharacters: allowed)
                } ?? String(seg)
            }
            .reduce("") { $0 + "/" + $1 }

        let canonicalRequest = ["POST", canonicalPath, "", canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/bedrock/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            SHA256.hash(data: Data(canonicalRequest.utf8)).hex].joined(separator: "\n")

        let kDate = Self.hmac(Data("AWS4\(secretKey)".utf8), dateStamp)
        let kRegion = Self.hmac(kDate, region)
        let kService = Self.hmac(kRegion, "bedrock")
        let kSigning = Self.hmac(kService, "aws4_request")
        let signature = Self.hmac(kSigning, stringToSign).hex

        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if !sessionToken.isEmpty {
            req.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        req.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension SHA256Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
