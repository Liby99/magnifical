#!/usr/bin/env python3
"""Generate the DENSE stress payload: bench/year-dense-2026.json.

Starts from the real exported store (~/.magical-bench/data.json — CC_DUMP_DISPLAY of the live
calendar) and densifies it deterministically (seeded RNG, stable output):
  • bands: every (month, track) lane filled to ~80% day-coverage — synthetic bands (len 2–6d,
    gaps 0–2d) packed into the free runs AROUND the real bands, titles/colors sampled from the
    real distribution. ~18% → ~80% fill ≈ 4× the band count.
  • timed events: synthetic events added to reach TARGET_EVENTS total (default 3000), spread
    over every day of the year (07:00–22:00, 30m–2.5h), same color/title distributions.
  • deadlines: topped up to 50.

Usage: python3 scripts/gen-dense-payload.py  (writes bench/year-dense-2026.json; prints stats)
"""
import json, os, random, calendar

SEED = 20260720
TARGET_FILL = 0.80
TARGET_EVENTS = 3000
TARGET_DEADLINES = 50
YEAR = 2026

src_path = os.path.expanduser('~/.magical-bench/data.json')
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'bench', 'year-dense-2026.json')
d = json.load(open(src_path))
rng = random.Random(SEED)

colors = [e['color'] for e in d['events']] + [b['color'] for b in d['bands']]
ev_titles = sorted({e['title'] for e in d['events'] if e['title'].strip()})
band_titles = sorted({b['title'] for b in d['bands'] if b['title'].strip()})

def dim(m):
    return calendar.monthrange(YEAR, m + 1)[1]

# ── Bands: fill each lane's free runs to ~TARGET_FILL ────────────────────────────────────────
bands = [b for b in d['bands']]
n = 0
for m in range(12):
    for t in range(4):
        covered = set()
        for b in d['bands']:
            if b['year'] == YEAR and b['month'] == m and b.get('track', 0) == t:
                covered.update(range(b['startDay'], b['endDay'] + 1))
        # walk free runs; inside each, alternate band(2-6d) / gap(0-2d) — expected fill ~80%
        day = 1
        while day <= dim(m):
            if day in covered:
                day += 1
                continue
            run_end = day
            while run_end + 1 <= dim(m) and (run_end + 1) not in covered:
                run_end += 1
            pos = day
            while pos <= run_end:
                length = rng.randint(2, 6)
                end = min(pos + length - 1, run_end)
                if end - pos >= 0:  # even 1-day remnants become bands (dense!)
                    n += 1
                    bands.append({
                        'id': f'dense-b-{n}', 'year': YEAR, 'month': m, 'track': t,
                        'startDay': pos, 'endDay': end,
                        'title': rng.choice(band_titles) if band_titles else f'Band {n}',
                        'color': rng.choice(colors),
                    })
                pos = end + 1 + rng.choice([0, 1, 1, 2])
            day = run_end + 1

# ── Timed events: top up to TARGET_EVENTS across the whole year ──────────────────────────────
events = [e for e in d['events']]
need = max(0, TARGET_EVENTS - len(events))
days = [(m, day) for m in range(12) for day in range(1, dim(m) + 1)]
k = 0
while k < need:
    m, day = days[k % len(days)]
    start = rng.randrange(7 * 4, int(21.5 * 4)) / 4  # 07:00–21:30, 15-min grid
    dur = rng.randrange(2, 11) / 4                   # 30m–2.5h
    k += 1
    events.append({
        'id': f'dense-e-{k}', 'year': YEAR, 'month': m, 'day': day,
        'startHour': start, 'endHour': min(23.75, start + dur),
        'title': rng.choice(ev_titles) if ev_titles else f'Event {k}',
        'color': rng.choice(colors), 'anchorTz': 'America/New_York',
    })

# ── Deadlines: top up to TARGET_DEADLINES ────────────────────────────────────────────────────
deadlines = [x for x in d['deadlines']]
k = 0
while len(deadlines) < TARGET_DEADLINES:
    m, day = days[rng.randrange(len(days))]
    k += 1
    deadlines.append({
        'id': f'dense-d-{k}', 'year': YEAR, 'month': m, 'day': day,
        'hour': rng.choice([8, 9, 12, 17, 23]),
        'title': f'Deadline {k}', 'color': rng.choice(colors),
        'anchorTz': 'America/New_York',
    })

out = {'bands': bands, 'deadlines': deadlines, 'events': events,
       'monthTrackNames': d['monthTrackNames'], 'rich': {}}
json.dump(out, open(out_path, 'w'), separators=(',', ':'), sort_keys=True)

# stats
cov = {}
for b in bands:
    cov.setdefault((b['month'], b.get('track', 0)), set()).update(range(b['startDay'], b['endDay'] + 1))
tot = sum(dim(m) for m in range(12)) * 4
full = sum(len(v) for v in cov.values())
per_day = {}
for e in events:
    per_day[(e['month'], e['day'])] = per_day.get((e['month'], e['day']), 0) + 1
mx = max(per_day.values())
print(f'bands: {len(bands)} (was {len(d["bands"])}) — lane fill {full}/{tot} = {full/tot*100:.0f}%')
print(f'events: {len(events)} (was {len(d["events"])}) — busiest day {mx}/day')
print(f'deadlines: {len(deadlines)} (was {len(d["deadlines"])})')
print(f'wrote {os.path.normpath(out_path)} ({os.path.getsize(out_path)} bytes)')
