#!/usr/bin/env python3
"""Amplify the REAL store's July todo load into a stress fixture (bench/todo-dense-2026.json).

Starts from the live store (~/Library/Application Support/MagnifiCalKit/data.json) so shapes stay
authentic (real events, bands, deadlines, existing notes), then piles todo items into July 2026:
  - every July day gets a daily note with a dozen mixed todos (open/done, due:, p:, tags, nesting)
  - July events get todo-bearing notes
Deterministic (seeded) so runs compare. Target: the "too many todos — monthly dashboard laggy"
payload the windowed-rendering work optimizes against.

Usage: python3 scripts/gen-todo-dense.py [TODOS_PER_DAY]   (default 12)
"""
import json, random, sys
from pathlib import Path

per_day = int(sys.argv[1]) if len(sys.argv) > 1 else 12
rng = random.Random(20260729)
src = Path.home() / "Library/Application Support/MagnifiCalKit/data.json"
d = json.loads(src.read_text())

TAGS = ["paper", "grant", "teaching", "reading", "admin", "travel", "review", "demo"]
PEOPLE = ["alex", "sam", "jordan", "chair", "advisor"]
VERBS = ["Draft", "Review", "Email", "Refactor", "Benchmark", "Summarize", "Schedule", "Prepare",
         "Polish", "Debug", "Read", "Annotate", "Merge", "Deploy", "Outline", "Rehearse"]
NOUNS = ["the intro section", "figure 3", "the sync layer", "unit tests", "the slides",
         "related work", "the rebuttal", "meeting notes", "the roadmap", "the dataset",
         "eval harness", "the release notes", "user feedback", "the API draft"]

def todo_line(day: int, i: int, indent: int = 0) -> str:
    done = rng.random() < 0.45
    box = "x" if done else " "
    title = f"{rng.choice(VERBS)} {rng.choice(NOUNS)}"
    extras = []
    if rng.random() < 0.5:
        extras.append(f"due:2026-07-{rng.randint(max(1, day - 2), min(31, day + 9)):02d}")
    if rng.random() < 0.3:
        extras.append("p:" + "!" * rng.randint(1, 3))
    if rng.random() < 0.4:
        extras.append(f"#{rng.choice(TAGS)}")
    if rng.random() < 0.25:
        extras.append(f"@{rng.choice(PEOPLE)}")
    if done:
        extras.append(f"done:2026-07-{day:02d}T{rng.randint(8, 21):02d}:{rng.randint(0, 59):02d}:00")
    return f"{'  ' * indent}- [{box}] {title} {' '.join(extras)}".rstrip()

# ── daily notes across July ──
notes = d.setdefault("dailyNotes", {})
added_daily = 0
for day in range(1, 32):
    iso = f"2026-07-{day:02d}"
    lines = [f"## Plan for {iso}"]
    i = 0
    while i < per_day:
        lines.append(todo_line(day, i))
        i += 1
        for _ in range(rng.randint(0, 2)):     # nested children under some roots
            if i >= per_day:
                break
            lines.append(todo_line(day, i, indent=1))
            i += 1
    added_daily += i
    notes[iso] = (notes.get(iso, "") + "\n\n" + "\n".join(lines)).strip()

# ── event notes on July events ──
rich = d.setdefault("rich", {})
added_event = 0
july_events = [e for e in d.get("events", []) if e.get("month") == 6 and e.get("year") == 2026]
for e in july_events:
    rf = rich.setdefault(e["id"], {})
    day = max(1, min(31, e.get("day", 15)))
    lines = [todo_line(day, i) for i in range(4)]
    added_event += len(lines)
    rf["notes"] = ((rf.get("notes") or "") + "\n" + "\n".join(lines)).strip()

out = Path(__file__).resolve().parent.parent / "bench" / "todo-dense-2026.json"
out.write_text(json.dumps(d))
print(f"wrote {out}")
print(f"July todos added: {added_daily} daily + {added_event} event (over {len(july_events)} events)")
