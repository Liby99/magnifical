// The assistant's web tools, ported from src/lib/assistant/tools/web.ts:
//   • web_search — Tavily search (POST api.tavily.com/search) with the user's Keychain key.
//   • web_open   — fetch a URL and extract readable text (regex HTML→text, no dependencies).
//
// Both are read-only (no calendar mutation), so they are NOT auditor-gated. Note the auditor never
// sees fetched web content anyway — it only sees the user's verbatim turns — so injected page text
// can't reach a mutation decision even indirectly.

import Foundation

/// ── web_search (Tavily) ─────────────────────────────────────────────────────────────────
struct WebSearchTool: AssistantTool {
    static let keychainAccount = "tavily"

    let def = ToolDef(
        name: "web_search",
        description: "Search the web for current information. Returns a list of {title, url, snippet}.",
        parameters: .parse(#"""
        {"type":"object","properties":{
          "query":{"type":"string"},
          "max_results":{"type":"integer","minimum":1,"maximum":10,"description":"Default 5."}
        },"required":["query"],"additionalProperties":false}
        """#)
    )
    let readOnly = true
    let actionKind = ActionKind.webSearch
    func card(_ args: JSONValue, result: JSONValue) -> String {
        if result["available"]?.boolValue == false {
            return "Web search unavailable (no Tavily key)"
        }
        let n = result["results"]?.arrayValue?.count ?? 0
        return "Web search: \(n) result\(n == 1 ? "" : "s") · \(args["query"]?.stringValue ?? "")"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            return .obj(["error": .str("missing 'query'")])
        }
        let key = (Keychain.get(account: Self.keychainAccount) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            // Graceful degrade — matches the web tool: no throw, just report unavailability, with an
            // explicit relay instruction so the model tells the user how to enable it.
            return .obj([
                "available": .bool(false),
                "note": .str(
                    "Web search is unavailable because no Tavily API key is set. Tell the user verbatim: \"Please add your Tavily API key in the Settings window (Settings ▸ API Keys, ⌘,) to enable web search.\" Do not attempt the search again."
                ),
            ])
        }
        let maxResults = max(1, min(10, args["max_results"]?.intValue ?? 5))

        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": key, "query": query, "max_results": maxResults, "search_depth": "basic",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ... 299).contains(status) else {
            return .obj(["error": .str("Tavily returned HTTP \(status)")])
        }
        let root = JSONValue.parse(String(decoding: data, as: UTF8.self))
        let results = (root["results"]?.arrayValue ?? []).prefix(maxResults).map { r in
            JSONValue.obj([
                "title": .str(r["title"]?.stringValue ?? ""),
                "url": .str(r["url"]?.stringValue ?? ""),
                "snippet": .str(r["content"]?.stringValue ?? ""),
            ])
        }
        return .obj(["query": .str(query), "results": .arr(Array(results))])
    }
}

/// ── web_open ────────────────────────────────────────────────────────────────────────────
struct WebOpenTool: AssistantTool {
    private static let maxText = 8000

    let def = ToolDef(
        name: "web_open",
        description: "Fetch a web page by URL and return its readable text (truncated). Use after "
            + "web_search to read a result in detail.",
        parameters: .parse(
            #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"],"additionalProperties":false}"#
        )
    )
    let readOnly = true
    let actionKind = ActionKind.webOpen
    func card(_ args: JSONValue, result: JSONValue) -> String {
        if let err = result["error"]?.stringValue {
            return "Open failed: \(err)"
        }
        let title = result["title"]?.stringValue ?? ""
        let host = (result["url"]?.stringValue).flatMap { URL(string: $0)?.host } ?? ""
        return "Read page: \(title.isEmpty ? host : title)"
    }

    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> JSONValue {
        guard let urlStr = args["url"]?.stringValue, let url = URL(string: urlStr),
              url.scheme == "http" || url.scheme == "https" else {
            return .obj(["error": .str("missing or invalid 'url'")])
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (compatible; magical-assistant/1.0)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ... 299).contains(status) else {
            return .obj(["error": .str("HTTP \(status)"), "url": .str(url.absoluteString)])
        }
        let html = String(decoding: data, as: UTF8.self)
        let text = String(htmlToText(html).prefix(Self.maxText))
        return .obj([
            "url": .str(url.absoluteString),
            "title": .str(extractTitle(html)),
            "text": .str(text),
        ])
    }
}

/// ── Regex HTML → text (dependency-free, mirrors htmlToText in web.ts) ────────────────────
private func htmlToText(_ html: String) -> String {
    func strip(_ s: String, _ pattern: String, _ replacement: String) -> String {
        s.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
    var s = html
    // Drop non-content sections and comments first (dotall via (?s)).
    for pat in ["(?s)<script.*?</script>", "(?s)<style.*?</style>",
                "(?s)<head.*?</head>", "(?s)<!--.*?-->"] {
        s = strip(s, pat, " ")
    }
    // Block-level tags → line breaks so the text keeps some structure.
    s = strip(s, "<(br|/p|/div|/h[1-6]|/li|/tr|/table|/section)[^>]*>", "\n")
    // Remove every remaining tag.
    s = strip(s, "<[^>]+>", " ")
    // Decode the handful of entities the web version handles.
    for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                   "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
        s = s.replacingOccurrences(of: k, with: v)
    }
    // Collapse runs of spaces/blank lines.
    s = strip(s, "[ \\t]+", " ")
    s = strip(s, "\\n[ \\t]*\\n[ \\t]*\\n+", "\n\n")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func extractTitle(_ html: String) -> String {
    guard let r = html.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression)
    else { return "" }
    let inner = html[r].replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
    return inner.trimmingCharacters(in: .whitespacesAndNewlines)
}
