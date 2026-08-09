// The native assistant's tool contract — the Swift counterpart of src/lib/assistant/types.ts.
// A tool is an OpenAI function definition (name + description + JSON-Schema parameters) plus a
// handler that runs on the main actor (tools read/mutate the @MainActor CalendarEngine).
//
// Stage 1 wires only the read-only tools (get_screen_state, list_events, get_tracks, set_view).
// `readOnly`/`confirm`/`actionKind` are defined now for the mutating tools + auditor + action
// cards that land in later stages.

import CalendarEngine
import Foundation

/// What kind of action a tool performs. Drives the action-card UI (later stages) and mirrors the
/// web `ActionKind`.
enum ActionKind: String {
    case getScreenState = "get_screen_state"
    case readCalendar = "read_calendar"
    case webSearch = "web_search"
    case webOpen = "web_open"
    case createEvent = "create_event"
    case updateEvent = "update_event"
    case deleteEvent = "delete_event"
    case setView = "set_view"
    case setDailyNote = "set_daily_note"
    case setTrackName = "set_track_name"
    case remember
    case forget

    /// SF Symbol for the action chip.
    var icon: String {
        switch self {
        case .getScreenState, .readCalendar: "magnifyingglass"
        case .setView: "location.circle.fill"
        case .createEvent: "plus.circle.fill"
        case .updateEvent: "pencil.circle.fill"
        case .deleteEvent: "trash.circle.fill"
        case .setDailyNote: "note.text"
        case .setTrackName: "tag"
        case .webSearch: "globe"
        case .webOpen: "safari.fill"
        case .remember, .forget: "brain"
        }
    }
}

/// Ambient context handed to every tool. Grows over stages (memory store, web keys, user id).
/// `weak`, not `unowned` — an engine outlived by a running tool call must degrade to
/// "calendar unavailable", never dangle (same reasoning as CloudSync's weak engine).
@MainActor
struct ToolContext {
    weak var engine: CalendarEngine?
}

/// One assistant tool: an OpenAI function def + a handler. Mirrors `AssistantTool` in types.ts.
@MainActor
protocol AssistantTool {
    var def: ToolDef { get }
    var readOnly: Bool { get } // false → mutating → auditor-gated (Stage 2)
    var confirm: Bool { get } // true → human confirm in the UI (delete, Stage 3)
    var actionKind: ActionKind { get }
    /// The action-chip label shown in the transcript, built from the call args + the tool's result.
    /// Format is "Category: detail" (e.g. "Navigation: Sep 2026", "Created: Team sync").
    func card(_ args: JSONValue, result: JSONValue) -> String
    /// Execute the tool. Returns a JSON value that is stringified into the `role:"tool"` message.
    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue
}

extension AssistantTool {
    var confirm: Bool {
        false
    } // most tools don't need confirmation
}

// ── JSONValue ergonomics ──────────────────────────────────────────────────────────────
// Read accessors for tool arguments + builders for tool output. Keeps the tool bodies terse.

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        if case let .object(o) = self {
            return o[key]
        }
        return nil
    }

    var stringValue: String? {
        if case let .string(s) = self {
            return s
        }; return nil
    }

    var intValue: Int? {
        if case let .number(n) = self {
            return Int(n)
        }; return nil
    }

    var boolValue: Bool? {
        if case let .bool(b) = self {
            return b
        }; return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(a) = self {
            return a
        }; return nil
    }

    /// Parse a JSON string (a tool call's `arguments`, or a schema literal) → JSONValue; `.null` on failure.
    static func parse(_ s: String) -> JSONValue {
        guard let data = s.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return v
    }

    /// Compact JSON string (tool output → `role:"tool"` message content).
    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// Terse builders for tool output.
    static func obj(_ d: [String: JSONValue]) -> JSONValue {
        .object(d)
    }

    static func arr(_ a: [JSONValue]) -> JSONValue {
        .array(a)
    }

    static func str(_ s: String) -> JSONValue {
        .string(s)
    }

    static func num(_ n: Int) -> JSONValue {
        .number(Double(n))
    }

    static func num(_ n: Double) -> JSONValue {
        .number(n)
    }
}
