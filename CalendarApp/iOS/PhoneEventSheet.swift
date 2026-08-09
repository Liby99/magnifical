// Read-only detail sheet for a tapped item — the iPhone's stand-in for the Mac's edit drawer.
// Resolves the tapped BOX id against the display arrays (so recurrence ghosts and promoted
// bars show their occurrence's dates) and reads notes/tags/repeat through the source/overlay
// id, exactly like the drawer does. Content mirrors the drawer's inventory: kind + title,
// full date/time (with the anchor-timezone sublabel), repeat rule, tags, provenance badges,
// and the note rendered as NATIVE selectable markdown (see PhoneMarkdown). Strictly
// read-only: no engine mutation besides selection.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

struct PhoneEventSheet: View {
    let engine: CalendarEngine
    let boxId: String
    let theme: Theme

    var body: some View {
        let d = details()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // ── Header: color dot, kind, title ──
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(theme.eventBorder(d.color)).frame(width: 10, height: 10)
                        Text(d.kind.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .kerning(0.8)
                    }
                    Text(d.title.isEmpty ? "(untitled)" : d.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                }

                // ── When / repeat / provenance rows ──
                VStack(alignment: .leading, spacing: 6) {
                    row(icon: "calendar", d.when)
                    if let t = d.time {
                        row(icon: "clock", t)
                    }
                    if let a = d.anchorLabel {
                        row(icon: "globe", a) // anchor-timezone wall time
                    }
                    if let r = d.repeatText {
                        row(icon: "repeat", r)
                    }
                    if let p = d.provenance {
                        row(icon: d.provenanceIcon, p)
                    }
                }
                .textSelection(.enabled)

                // ── Tags ──
                if !d.tags.isEmpty {
                    FlowChips(tags: d.tags, fill: theme.eventFill(d.color))
                }

                // ── Notes: native, selectable markdown ──
                if !d.notes.isEmpty {
                    Divider()
                    PhoneMarkdown(text: d.notes, accent: theme.eventBorder(d.color), theme: theme)
                }
                Spacer(minLength: 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium, .large]) // large: long notes get the full screen
        .presentationDragIndicator(.visible)
        // Keep the (lifted) calendar behind the medium sheet live — the selected event stays
        // visible and highlighted up top, and taps there still work.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func row(icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // ── Data ─────────────────────────────────────────────────────────────────────────

    private struct Details {
        var kind = "Event"
        var title = ""
        var when = ""
        var time: String?
        var anchorLabel: String?
        var repeatText: String?
        var provenance: String?
        var provenanceIcon = "square.and.arrow.down"
        var color = "red"
        var notes = ""
        var tags: [String] = []
    }

    private func details() -> Details {
        var d = Details()
        let src = sourceId(of: boxId)
        d.notes = engine.notes(src)
        d.tags = engine.richTags(src)
        d.repeatText = engine.repeatRule(src).map(describeRepeat)
        if let e = engine.viewEvents().first(where: { $0.id == boxId }) {
            d.kind = "Event"
            d.title = e.title; d.color = e.color
            d.when = fullDate(e.year, e.month, e.day)
            d.time = fmtHourRange(e.startHour, e.endHour)
            d.anchorLabel = anchorRangeLabel(e, mainTz: engine.mainTz)
        } else if let b = engine.viewBands().first(where: { $0.id == boxId }) {
            d.kind = b.startDay == b.endDay ? "All-day" : "Multi-day"
            d.title = b.title; d.color = b.color
            d.when = b.startDay == b.endDay
                ? fullDate(b.year, b.month, b.startDay)
                : "\(MONTH_LONG[b.month]) \(b.startDay) – \(b.endDay), \(b.year)"
        } else if let dl = engine.viewDeadlines().first(where: { $0.id == boxId }) {
            d.kind = "Deadline"
            d.title = dl.title; d.color = dl.color
            d.when = fullDate(dl.year, dl.month, dl.day)
            let h = Int(dl.hour), m = Int((dl.hour - CGFloat(h)) * 60)
            d.time = String(format: "due %02d:%02d", h, m)
        }
        // Provenance from the display badges (imported / AI-created / recurrence ghost).
        let badges = engine.viewEventBadges()[boxId] ?? engine.viewBandBadges()[boxId] ?? []
        if badges.contains(.imported) {
            d.provenance = "Imported from an external calendar"
            d.provenanceIcon = "square.and.arrow.down"
        } else if badges.contains(.ai) {
            d.provenance = "Created by the AI assistant"
            d.provenanceIcon = "sparkles"
        }
        return d
    }

    private func fullDate(_ y: Int, _ m: Int, _ day: Int) -> String {
        "\(WD_LONG[dayOfWeek(y, m, day)]), \(MONTH_LONG[m]) \(day), \(y)"
    }

    /// Human description of a Repeat rule ("Repeats weekly until Sep 30, 2026").
    private func describeRepeat(_ r: Repeat) -> String {
        let n = r.n ?? 1
        var s: String
        switch r.kind {
        case "daily": s = n == 1 ? "Repeats daily" : "Repeats every \(n) days"
        case "weekly": s = n == 1 ? "Repeats weekly" : "Repeats every \(n) weeks"
        case "weekdays":
            let names = (r.days ?? []).sorted().map { String(WD_LONG[$0].prefix(3)) }
            s = names.isEmpty ? "Repeats on weekdays" : "Repeats \(names.joined(separator: ", "))"
        case "yearly": s = n == 1 ? "Repeats yearly" : "Repeats every \(n) years"
        default: s = "Repeats \(r.kind)"
        }
        if let u = r.until, let pretty = prettyISO(u) {
            s += " until \(pretty)"
        }
        return s
    }

    /// "2026-09-30" → "Sep 30, 2026".
    private func prettyISO(_ iso: String) -> String? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1 ... 12).contains(parts[1]) else { return nil }
        return "\(MONTH_LONG[parts[1] - 1].prefix(3)) \(parts[2]), \(parts[0])"
    }
}

/// Tag chips in a simple wrapping row.
private struct FlowChips: View {
    let tags: [String]
    let fill: Color

    var body: some View {
        // A plain HStack wraps poorly, but tag counts are small; a grid keeps rows tidy.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { t in
                Text("#\(t)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(fill))
                    .textSelection(.enabled)
            }
        }
    }
}
