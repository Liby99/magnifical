// The assistant's memory tools, ported from src/lib/assistant/tools/memory.ts. Both are read-only
// with respect to the CALENDAR (they write assistant memory, not events), so they aren't
// auditor-gated. Recalled facts are injected into the system prompt by AssistantState.

import Foundation

/// ── remember ────────────────────────────────────────────────────────────────────────────
struct RememberTool: AssistantTool {
    let def = ToolDef(
        name: "remember",
        description: "Store a durable fact about the user for future conversations (a preference, a "
            + "recurring detail, a name). Use a short stable key. Don't store trivia or one-off context.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "key":{"type":"string","description":"Short stable identifier, e.g. 'advisor' or 'timezone'."},
          "value":{"description":"Any JSON value to remember."}
        },"required":["key","value"],"additionalProperties":false}
        """#)
    )
    let readOnly = true
    let actionKind = ActionKind.remember
    func card(_ args: JSONValue, result: JSONValue) -> String {
        "Remembered: \(args["key"]?.stringValue ?? "note")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let key = args["key"]?.stringValue, !key.isEmpty else {
            return .obj(["error": .str("missing 'key'")])
        }
        AssistantMemory.remember(key, args["value"] ?? .null)
        return .obj(["ok": .bool(true), "key": .str(key)])
    }
}

/// ── forget ──────────────────────────────────────────────────────────────────────────────
struct ForgetTool: AssistantTool {
    let def = ToolDef(
        name: "forget",
        description: "Remove a previously remembered fact by its key.",
        parameters: .parse(
            #"{"type":"object","properties":{"key":{"type":"string"}},"required":["key"],"additionalProperties":false}"#
        )
    )
    let readOnly = true
    let actionKind = ActionKind.forget
    func card(_ args: JSONValue, result: JSONValue) -> String {
        "Forgot: \(args["key"]?.stringValue ?? "note")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let key = args["key"]?.stringValue, !key.isEmpty else {
            return .obj(["error": .str("missing 'key'")])
        }
        AssistantMemory.forget(key)
        return .obj(["ok": .bool(true), "key": .str(key)])
    }
}
