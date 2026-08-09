#!/usr/bin/env python3
"""Analyze a cc-trace file (CC_TRACE=1 interaction profiler dump).

Usage: python3 scripts/cc-trace-report.py /path/to/cc-trace-*.trace [--top N]

Reconstructs, from the user's OWN interaction session:
  1. A frame-rate timeline segmented by input events (which action → which frame rate).
  2. The worst windows (lowest fps / longest frame stalls), each with its FOLDED main-thread
     stacks — a text flamegraph of what the main thread was doing while frames stalled.
"""
import sys
import collections

def main():
    path = sys.argv[1]
    top_n = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 8

    events = []   # (t_ms, label)
    frames = []   # (t_ms, z, pin)
    displays = [] # (t_ms) actual display-link ticks — frames PRESENTED to the screen
    samples = []  # (t_ms, [addr,...]) leaf-first
    syms = {}

    for line in open(path):
        parts = line.rstrip("\n").split(" ")
        if not parts:
            continue
        if parts[0] == "E":
            events.append((float(parts[1]), " ".join(parts[2:])))
        elif parts[0] == "F":
            frames.append((float(parts[1]), float(parts[2]), float(parts[3])))
        elif parts[0] == "D":
            displays.append(float(parts[1]))
        elif parts[0] == "S":
            samples.append((float(parts[1]), parts[2:]))
        elif parts[0] == "Y":
            syms[parts[1]] = " ".join(parts[2:])

    print(f"trace: {len(frames)} frames, {len(samples)} samples, {len(events)} events, "
          f"{len(syms)} symbols")
    if not frames:
        return

    def sym(addr):
        return syms.get(addr, "0x" + addr)

    # Clock-asleep spans (clockAsleep → clockAwake): frame silence inside them is a SLEEP,
    # not a stall; fps is only meaningful over awake time.
    asleep_spans = []
    sleep_start = None
    for t, lbl in events:
        if lbl == "clockAsleep" and sleep_start is None:
            sleep_start = t
        elif lbl == "clockAwake" and sleep_start is not None:
            asleep_spans.append((sleep_start, t))
            sleep_start = None
    if sleep_start is not None:
        asleep_spans.append((sleep_start, frames[-1][0] if frames else sleep_start))

    def asleep_overlap(a, b):
        return sum(max(0.0, min(b, s1) - max(a, s0)) for s0, s1 in asleep_spans)

    # ── 1. Interaction segments: event → next event, with frame stats ──
    print("\n== interaction timeline (event → fps until next event) ==")
    bounds = [(t, lbl) for t, lbl in events if not lbl.startswith("clock")] \
        + [(frames[-1][0], "<end>")]
    for i in range(len(bounds) - 1):
        t0, lbl = bounds[i]
        t1 = bounds[i + 1][0]
        if t1 - t0 < 30:
            continue
        fs = [t for t, _, _ in frames if t0 <= t < t1]
        if len(fs) < 2:
            print(f"  {t0/1000:7.2f}s {lbl:<28} {(t1-t0)/1000:6.2f}s   NO FRAMES")
            continue
        span = fs[-1] - fs[0]
        awake_ms = span - asleep_overlap(fs[0], fs[-1])
        fps = (len(fs) - 1) / (awake_ms / 1000) if awake_ms > 0 else 0
        # Worst AWAKE gap only (sleep silences excluded).
        worst = 0.0
        n_hitch = 0
        for a, b in zip(fs, fs[1:]):
            g = (b - a) - asleep_overlap(a, b)
            worst = max(worst, g)
            if g > 33:
                n_hitch += 1
        # DISPLAY-side cadence over the same window — the number the EYES see. Divergence
        # from eval-fps (bursty evals / coalesced commits / adaptive refresh) is the story.
        ds = [t for t in displays if t0 <= t < t1]
        if len(ds) >= 2:
            d_span = (ds[-1] - ds[0]) - asleep_overlap(ds[0], ds[-1])
            d_fps = (len(ds) - 1) / (d_span / 1000) if d_span > 0 else 0
            d_worst = 0.0
            for a, b in zip(ds, ds[1:]):
                d_worst = max(d_worst, (b - a) - asleep_overlap(a, b))
            dcol = f"  DISPLAY {d_fps:6.1f} fps worst {d_worst:5.0f}ms"
        else:
            dcol = "  DISPLAY: no ticks"
        flag = "  <<<" if fps < 60 or worst > 100 or "DISPLAY" in dcol and len(ds) >= 2 and d_fps < 60 else ""
        print(f"  {t0/1000:7.2f}s {lbl:<28} {(t1-t0)/1000:6.2f}s  "
              f"eval {fps:6.1f} fps worst {worst:5.0f}ms h{n_hitch}{dcol}{flag}")

    # ── 2. Worst stall windows with folded stacks ──
    print(f"\n== top {top_n} frame stalls, with main-thread stacks during each ==")
    gaps = []
    for (a, _, _), (b, _, _) in zip(frames, frames[1:]):
        real = (b - a) - asleep_overlap(a, b) # sleep-adjusted: only awake silence counts
        if real > 50:
            gaps.append((real, a, b))
    gaps.sort(reverse=True)
    for gap_ms, a, b in gaps[:top_n]:
        near = [lbl for t, lbl in events if a - 800 <= t <= b]
        print(f"\n-- stall {gap_ms:.0f}ms at {a/1000:.2f}s  (recent events: {near[-3:]}) --")
        window = [s for t, s in samples if a - 5 <= t <= b + 5]
        if not window:
            print("   (no samples in window)")
            continue
        folded = collections.Counter()
        for addrs in window:
            names = [sym(x) for x in addrs]
            # collapse to the most-informative frames: drop leaf runloop noise
            folded[";".join(reversed(names[:24]))] += 1
        for stack, w in folded.most_common(4):
            frames_list = stack.split(";")
            print(f"   {w:3d}× " + "\n        ".join(frames_list[-14:]))

    # ── 2b. DISPLAY stalls: the gaps the EYES see, with commits + stacks in-window ──
    print(f"\n== top {top_n} DISPLAY stalls (presented-frame gaps) ==")
    dgaps = []
    for a, b in zip(displays, displays[1:]):
        real = (b - a) - asleep_overlap(a, b)
        if real > 50:
            dgaps.append((real, a, b))
    dgaps.sort(reverse=True)
    for gap_ms, a, b in dgaps[:top_n]:
        near_ev = [lbl for t, lbl in events
                   if a - 500 <= t <= b + 100 and not lbl.startswith("clock")]
        evals_in = sum(1 for t, _, _ in frames if a <= t <= b)
        commits = [lbl for t, lbl in events if a - 50 <= t <= b + 50 and lbl.startswith("commit")]
        print(f"\n-- display stall {gap_ms:.0f}ms at {a/1000:.2f}s | {evals_in} evals ran inside | "
              f"commits: {commits or 'none >8ms'} | events: {near_ev[-3:]} --")
        window = [smp for t, smp in samples if a - 5 <= t <= b + 5]
        folded = collections.Counter()
        for addrs in window:
            names = [sym(x) for x in addrs]
            folded[";".join(reversed(names[:24]))] += 1
        for stack, w in folded.most_common(3):
            fl = stack.split(";")
            print(f"   {w:3d}× " + "\n        ".join(fl[-12:]))

    # ── 3. Whole-trace hot self frames (context) ──
    print("\n== whole-trace top leaf frames ==")
    leaf = collections.Counter()
    for _, addrs in samples:
        if addrs:
            leaf[sym(addrs[0])] += 1
    total = sum(leaf.values()) or 1
    for name, w in leaf.most_common(15):
        print(f"  {w:6d} ({100*w/total:4.1f}%)  {name[:100]}")

if __name__ == "__main__":
    main()
