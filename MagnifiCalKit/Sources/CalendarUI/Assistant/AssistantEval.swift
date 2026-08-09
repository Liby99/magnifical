// Headless TRAJECTORY collection for the assistant — drives the REAL stack (AssistantState →
// runAgent → tools → auditor → engine) with scenario prompts from docs/assistant-scenarios.md
// and dumps one inspectable JSON trajectory per scenario: every tool call (args/result/latency),
// auditor blocks, pause cards, the final answer, and the calendar's before/after diff.
//
// Isolation: each scenario runs in demo mode (CC_DEMO) with a throwaway CC_DEMO_DATADIR, so no
// cloud sync, no Apple import, no notifications, no real-store writes — and (since the store
// honors the demo dir) no pollution of the user's conversation list. LLM keys come from the
// app's prefs (UserDefaults suite) + CC_KEY_* env overrides (the app's data-protection keychain
// isn't readable from an unsigned headless binary).
//
// Interaction policy (recorded into the trajectory, so grading can see it):
//   • blocked card   → auto-"Allow" ONCE (exercises the allow-history), second block ends the run
//   • pause (resume) → auto-"continue" up to maxContinues
//   • delete confirm → recorded but NOT executed (the card is the datapoint)
//
// Invoked by the `assistant-eval` executable: swift run assistant-eval --ids S001,S045

import CalendarEngine
import CalendarGeometry
import Foundation

@MainActor
public enum AssistantEval {
    public struct Options {
        public var scenarioFile: String
        public var ids: [String] // empty = every scenario in the file
        public var outDir: String
        public var maxContinues = 2
        public var timeout: TimeInterval = 240
        public init(scenarioFile: String, ids: [String], outDir: String) {
            self.scenarioFile = scenarioFile; self.ids = ids; self.outDir = outDir
        }
    }

    struct Scenario {
        var id: String
        var name: String
        var prompt: String
    }

    public static func run(_ opts: Options) async {
        // Read the APP's preferences (active provider, its tested settings, view prefs) from this
        // headless process — its own defaults domain is empty. Both domains: the app's current
        // (dev.magnifical.calendar, post-2026-08 bundle-id rename) and the legacy one it migrated from.
        UserDefaults.standard.addSuite(named: "dev.magnifical.calendar")
        UserDefaults.standard.addSuite(named: "dev.libirabu.calendar")
        let all = parseScenarios(at: opts.scenarioFile)
        let scenarios = opts.ids.isEmpty ? all : all.filter { opts.ids.contains($0.id) }
        guard !scenarios.isEmpty else {
            print("no scenarios matched (\(all.count) in file)"); return
        }
        guard ProviderStore.activeReady else {
            print("""
            ⚠️ no ready LLM provider from here. Either the app's prefs weren't readable, or the key
            is keychain-only. Export the key for headless use, e.g.:
              CC_KEY_JHU_GATEWAY=<key> [CC_KEY_TAVILY=<key>] swift run assistant-eval --ids S001
            """)
            return
        }
        try? FileManager.default.createDirectory(atPath: opts.outDir, withIntermediateDirectories: true)
        print("▶ \(scenarios.count) scenario(s), model \(ProviderStore.activeModel), out \(opts.outDir)")
        for s in scenarios {
            await runOne(s, opts: opts)
        }
        print("done.")
    }

    /// ── One scenario: isolated engine + state, seeded fixture, send, settle, dump ───────────
    private static func runOne(_ s: Scenario, opts: Options) async {
        let dataDir = NSTemporaryDirectory() + "cc-eval-\(s.id)-\(UUID().uuidString.prefix(8))"
        setenv("CC_DEMO", "eval", 1)
        setenv("CC_DEMO_DATADIR", dataDir, 1)
        let engine = CalendarEngine()
        seedFixture(engine)
        let state = AssistantState(store: ConversationStore())
        state.engine = engine
        let before = snapshot(engine)
        var policies: [String] = []
        let t0 = Date()

        state.draft = s.prompt
        state.send()
        var continues = 0, allows = 0
        while true {
            guard await settle(state, deadline: t0.addingTimeInterval(opts.timeout)) else {
                policies.append("timeout@\(Int(opts.timeout))s")
                break
            }
            if let turn = state.messages.last(where: { $0.blockedReq?.status == .pending }) {
                if allows < 1 {
                    allows += 1
                    policies.append("auto-allow:\(turn.blockedReq?.toolName ?? "?")")
                    state.allowBlocked(turn.id)
                    continue
                }
                policies.append("second-block-stop:\(turn.blockedReq?.toolName ?? "?")")
                state.dismissBlocked(turn.id)
                break
            }
            let resumes = state.messages.filter { $0.role == .resume }.count
            if resumes > continues, continues < opts.maxContinues {
                continues += 1
                policies.append("auto-continue")
                state.draft = "continue"
                state.send()
                continue
            }
            break
        }

        dump(s, state: state, before: before, after: snapshot(engine), policies: policies,
             seconds: Date().timeIntervalSince(t0), outDir: opts.outDir)
        try? FileManager.default.removeItem(atPath: dataDir)
    }

    /// Poll until the agent loop settles (busy false). False on deadline.
    private static func settle(_ state: AssistantState, deadline: Date) async -> Bool {
        while state.busy {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return true
    }

    /// ── Fixture: a deterministic, plausible personal calendar around "today" ────────────────
    /// Enough material for query / conflict / optimization scenarios: weekly meetings spread
    /// across weekdays (so "condense to Monday" has work to do), classes, a deadline, tags.
    private static func seedFixture(_ e: CalendarEngine) {
        let cal = Calendar.current
        let now = Date()
        func day(offset: Int) -> (y: Int, m: Int, d: Int, weekday: Int) {
            let d = cal.date(byAdding: .day, value: offset, to: now) ?? now
            let c = cal.dateComponents([.year, .month, .day, .weekday], from: d)
            return (c.year ?? 2026, (c.month ?? 1) - 1, c.day ?? 1, c.weekday ?? 1)
        }
        // Next Monday (1-14 days out) anchors the weekly series.
        var mon = day(offset: 1)
        for off in 1 ... 14 where day(offset: off).weekday == 2 {
            mon = day(offset: off); break
        }
        func weekly(_ id: String) {
            e.setRepeat(id, Repeat(kind: "weekly"))
        }
        // Weekly 1:1s scattered over the week (targets for "condense my meetings").
        weekly(e.createTimedEvent(year: mon.y, month: mon.m, day: mon.d, startHour: 10, endHour: 11,
                                  title: "Advising 1:1 — Kai", color: "blue", tags: ["research", "meeting"],
                                  byAI: false))
        let tue = day(offset: (2 - day(offset: 0).weekday + 8) % 7 + 1)
        weekly(e.createTimedEvent(year: tue.y, month: tue.m, day: tue.d, startHour: 14, endHour: 15,
                                  title: "Lab meeting", color: "purple", tags: ["research", "meeting"], byAI: false))
        let wed = day(offset: (3 - day(offset: 0).weekday + 8) % 7 + 1)
        weekly(e.createTimedEvent(year: wed.y, month: wed.m, day: wed.d, startHour: 9, endHour: 9.5,
                                  title: "1:1 — Morgan", color: "blue", tags: ["meeting"], byAI: false))
        // Twice-weekly class (an immovable).
        let cls = e.createTimedEvent(year: tue.y, month: tue.m, day: tue.d, startHour: 10.5, endHour: 12,
                                     title: "CS 601 lecture", color: "orange", tags: ["teaching"], byAI: false)
        e.setRepeat(cls, Repeat(kind: "weekdays", days: [2, 4]))
        // A looming deadline + an all-day band.
        let dl = day(offset: 10)
        _ = e.createDeadline(year: dl.y, month: dl.m, day: dl.d, hour: 23.983, title: "NSF report due",
                             color: "red", tags: ["research", "deadline-work"], byAI: false)
        let trip = day(offset: 20)
        _ = e.createBand(year: trip.y, month: trip.m, track: 1, startDay: trip.d,
                         endDay: min(trip.d + 3, 28), title: "PLDI travel", color: "green",
                         tags: ["travel", "conference"], byAI: false)
    }

    /// ── Calendar snapshot: one normalized line per item (diffable) ──────────────────────────
    private static func snapshot(_ e: CalendarEngine) -> [String] {
        func t(_ h: CGFloat) -> String {
            String(format: "%02d:%02d", Int(h), Int((h - CGFloat(Int(h))) * 60 + 0.5))
        }
        var out: [String] = []
        for ev in e.items.events {
            out.append("timed|\(ev.year)-\(ev.month + 1)-\(ev.day) \(t(ev.startHour))–\(t(ev.endHour))|\(ev.title)"
                + "|tz:\(ev.anchorTz ?? "-")|rep:\(e.repeatConfig(ev.id)?.kind ?? "-")"
                +
                "|tags:\(e.richTags(ev.id).joined(separator: ","))|promote:\(e.promoteTrack(ev.id).map(String.init) ?? "-")")
        }
        for b in e.items.bands {
            out.append("band|\(b.year)-\(b.month + 1) d\(b.startDay)–\(b.endDay) track\(b.track + 1)|\(b.title)"
                + "|rep:\(e.repeatConfig(b.id)?.kind ?? "-")|tags:\(e.richTags(b.id).joined(separator: ","))")
        }
        for d in e.items.deadlines {
            out.append("deadline|\(d.year)-\(d.month + 1)-\(d.day) \(t(d.hour))|\(d.title)"
                + "|tz:\(d.anchorTz ?? "-")|rep:\(e.repeatConfig(d.id)?.kind ?? "-")"
                +
                "|tags:\(e.richTags(d.id).joined(separator: ","))|promote:\(e.promoteTrack(d.id).map(String.init) ?? "-")")
        }
        return out.sorted()
    }

    /// ── Trajectory dump ─────────────────────────────────────────────────────────────────────
    private static func dump(_ s: Scenario, state: AssistantState, before: [String], after: [String],
                             policies: [String], seconds: TimeInterval, outDir: String) {
        let beforeSet = Set(before)
        let afterSet = Set(after)
        var obj: [String: Any] = [
            "scenario": s.id, "name": s.name, "prompt": s.prompt,
            "model": ProviderStore.activeModel,
            "seconds": Int(seconds),
            "policies": policies,
            "finalText": state.messages.last(where: { $0.role == .assistant })?.text ?? "",
            "calendarCreated": after.filter { !beforeSet.contains($0) },
            "calendarRemoved": before.filter { !afterSet.contains($0) },
        ]
        // The full transcript, verbatim — ChatTurn is Codable (roles, action chips with
        // params/result/latency, blocked cards with reasons, confirm cards).
        if let turnsData = try? JSONEncoder().encode(state.messages),
           let turns = try? JSONSerialization.jsonObject(with: turnsData) {
            obj["turns"] = turns
        }
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(s.id).json")
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        let blocks = state.messages.filter { $0.role == .blocked }.count
        let actions = state.messages.filter { $0.role == .action }.count
        print("  \(s.id) — \(Int(seconds))s, \(actions) tool calls, \(blocks) blocks, "
            + "+\(afterSet.subtracting(beforeSet).count)/−\(beforeSet.subtracting(afterSet).count) items"
            + (policies.isEmpty ? "" : "  [\(policies.joined(separator: ", "))]"))
    }

    // ── Scenario parsing from docs/assistant-scenarios.md ───────────────────────────────────
    // Matches:  **S0NN — name**  followed by  - **User says:** "…"
    static func parseScenarios(at path: String) -> [Scenario] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [Scenario] = []
        var current: (id: String, name: String)?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let m = line.range(of: #"^\*\*(S\d+) — (.+?)\*\*"#, options: .regularExpression) {
                let inner = String(line[m]).dropFirst(2).dropLast(2)
                let parts = inner.split(separator: "—", maxSplits: 1)
                current = (parts[0].trimmingCharacters(in: .whitespaces),
                           parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
            } else if let c = current,
                      let r = line.range(of: #"^- \*\*User says:\*\*\s*"#, options: .regularExpression) {
                var prompt = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if prompt.hasPrefix("\""), prompt.hasSuffix("\""), prompt.count >= 2 {
                    prompt = String(prompt.dropFirst().dropLast())
                }
                out.append(Scenario(id: c.id, name: c.name, prompt: prompt))
                current = nil
            }
        }
        return out
    }
}
