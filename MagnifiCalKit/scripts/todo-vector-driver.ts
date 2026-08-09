// Golden-vector generator for the Swift TodoIndex port (webview retirement phase 0).
// Runs the LEGACY web tokenizer (todos.ts — the original source of truth) over a corpus that
// exercises the whole grammar, and prints the parsed results as JSON. The output is committed as
// Tests/CalendarEngineTests/Fixtures/todo-vectors.json and replayed against the Swift port in
// TodoIndexTests. Regenerate via scripts/gen-todo-vectors.sh (should rarely be needed — the web
// app is legacy; the Swift port owns the grammar going forward).
import {
  indexTodos,
  parseDailyNoteTodos,
  type TodoEventContext,
} from "../../../src/lib/assistant/tools/todos";

const TODAY = "2026-07-30";

const events: TodoEventContext[] = [
  {
    id: "ev-basic", kind: "timed", title: "Grant review", color: "indigo",
    tags: ["Work"], start: "2026-07-15T15:00:00", end: "2026-07-15T16:00:00",
    notes: [
      "- [ ] plain item",
      "- [x] done item done:2026-07-14T09:30:00",
      "- [ ] tokens due:2026-08-01 p:!!! #paper #Work color:red tz:America/New_York",
      "- [ ] datetime due:2026-08-01T09:30",
      "- [ ] keywords due:today start:tomorrow",
      "- [ ] offsets due:3d",
      "- [ ] negative due:-2w",
      "- [ ] time12 due:5pm",
      "- [ ] time12m due:5:30pm",
      "- [ ] time24 due:17:00",
      "- [ ] deferred start:2026-08-15",
      "- [ ] followup dur followup:30d",
      "- [ ] followup date followup:2026-8-5",
      "- [ ] priority clamp p:!!!!!!!",
      "- [ ] people @alex @Sam",
      "- [ ] typed @project:magical @funding:nsf-123 project:webless",
      "- [ ] email tommy@cs.jhu.edu stays text",
      "- [ ] md link [the paper](https://example.com/p#frag) #real",
      "- [ ] bare url https://example.com/x?a=b#c",
      "- [ ] link no label [](https://example.com/empty)",
      "- [ ] created created:2026-07-01T08:00",
      "1. [ ] ordered marker",
      "* [X] star done",
      "+ [ ] plus marker",
    ].join("\n"),
  },
  {
    id: "ev-nest", kind: "band", title: "Conference", color: "green",
    tags: [], start: "2026-09-02", end: "2026-09-06",
    notes: [
      "- [ ] parent one",
      "  - [ ] child a",
      "  - [x] child b done",
      "    - [ ] grandchild",
      "- [ ] parent two",
      "",
      "  - [ ] child after blank line",
      "prose breaks the chain",
      "  - [ ] new root despite indent",
      "- [ ]   ",
      "  - [ ] parent was empty checkbox, so this is a root",
      "\t- [ ] tab indented root",
    ].join("\n"),
  },
  {
    id: "ev-ddl", kind: "deadline", title: "Abstract due", color: "red",
    tags: ["deadline"], start: "2026-08-20T23:59:00", end: "2026-08-20T23:59:00",
    originTz: "AOE",
    notes: "- [ ] inherits deadline tz\n- [ ] own tz tz:Asia/Tokyo due:2026-08-19",
  },
  {
    id: "ev-occ", kind: "timed", title: "Weekly sync", color: "blue",
    tags: [], start: "2026-07-06T10:00:00", end: "2026-07-06T11:00:00",
    notes: "- [ ] base note item",
    occurrenceNotes: {
      "2026-07-13": "- [ ] occ item one\n- [x] occ item two done:2026-07-13T11:05",
      "2026-07-20": "- [ ] followup off occurrence followup:1w",
    },
  },
  { id: "ev-empty", kind: "timed", title: "No notes", color: "grey", tags: [],
    start: "2026-07-01T09:00:00", end: "2026-07-01T10:00:00", notes: null },
];

const dailyNotes: Record<string, string> = {
  "2026-07-18": [
    "## Plan",
    "- [ ] daily root due:today p:!!",
    "  - [ ] daily child #home",
    "- [x] daily done done:2026-07-18T20:11:00",
    "- [ ] daily defer start:5d",
  ].join("\n"),
  "week:2026-07-12": "- [ ] weekly scope item due:2026-07-16",
};

const out = {
  today: TODAY,
  events,
  dailyNotes,
  expected: {
    index: indexTodos(events, TODAY),
    daily: Object.fromEntries(
      Object.entries(dailyNotes).map(([k, v]) => [k, parseDailyNoteTodos(k, v, TODAY)]),
    ),
  },
};
console.log(JSON.stringify(out, null, 1));
