// CLI shell for AssistantEval (the headless assistant trajectory collector — see
// CalendarUI/Assistant/AssistantEval.swift for the policy + isolation details).
//
//   swift run assistant-eval --ids S001,S045 [--file docs/assistant-scenarios.md] [--out bench/eval]
//   CC_KEY_JHU_GATEWAY=<key> CC_KEY_TAVILY=<key> swift run assistant-eval --ids S030
//
// No --ids runs EVERY scenario in the file (long + token-hungry; prefer explicit batches).

import CalendarUI
import Foundation

var file = "docs/assistant-scenarios.md"
var ids: [String] = []
var out = "bench/eval"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--ids":
        if !args.isEmpty {
            ids = args.removeFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    case "--file":
        if !args.isEmpty {
            file = args.removeFirst()
        }
    case "--out":
        if !args.isEmpty {
            out = args.removeFirst()
        }
    default:
        print("unknown argument: \(a)")
        exit(2)
    }
}

let opts = await MainActor.run { AssistantEval.Options(scenarioFile: file, ids: ids, outDir: out) }
await AssistantEval.run(opts)
