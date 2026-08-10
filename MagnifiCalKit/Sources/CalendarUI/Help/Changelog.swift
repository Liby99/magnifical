// Help ▸ What's New — the in-app, user-facing changelog, shown in its own window (both
// shells host ChangelogView like they host HelpView). Content is DATA, curated by hand:
// on every version bump, distill the release's section of the PRIVATE native/CHANGELOG.md
// into a few user-visible entries here (same step that writes the GitHub release notes —
// see DISTRIBUTE.md "Versioning & changelog"). Entries support inline markdown (bold etc.).

import SwiftUI

// ── Data ─────────────────────────────────────────────────────────────────────────

public enum ChangeKind: String, Sendable {
    case added = "Added"
    case improved = "Improved"
    case fixed = "Fixed"

    var tint: Color {
        switch self {
        case .added: .green
        case .improved: .blue
        case .fixed: .orange
        }
    }
}

public struct ChangelogChange: Identifiable, Sendable {
    public let id = UUID()
    public let kind: ChangeKind
    public let text: String
    init(_ kind: ChangeKind, _ text: String) {
        self.kind = kind; self.text = text
    }
}

public struct ChangelogRelease: Identifiable, Sendable {
    public var id: String { version }
    public let version: String
    public let date: String // "August 10, 2026" — display form
    public let headline: String? // one-line theme of the release, shown under the version
    public let changes: [ChangelogChange]
}

public enum ChangelogContent {
    /// Newest first. Keep entries ONE line each, user-visible phrasing.
    public static let releases: [ChangelogRelease] = [
        ChangelogRelease(
            version: "0.2.0", date: "August 10, 2026",
            headline: "External calendars, multiple MagnifiCals, and self-updating builds.",
            changes: [
                .init(.added, "**Automatic updates** for the direct-download build — MagnifiCal ▸ Check for Updates…, plus a daily background check."),
                .init(.added, "**Google Calendar and Outlook** feeds via their secret/published ICS addresses — subscriptions belong to the MagnifiCal calendar that adds them, rows show the real calendar names, and Google events link back with *Edit original*."),
                .init(.added, "Multiple-calendar polish: File ▸ **Calendars** lists every calendar with its item count and a tick on the open one; Main can never be removed; Settings clearly shows which calendar imports configure."),
                .init(.added, "Per-dashboard **TODO layering**: each scope chooses which note sources and collections feed its list (⚙ in the TODO panel)."),
                .init(.added, "**Project boxes** on the projects timeline: a band event tagged `@project:` charts as a region spanning its dates."),
                .init(.added, "The sidebar **auto-hides** when a pinned dashboard leaves the window too narrow."),
                .init(.improved, "Hovered events read as real **Liquid Glass** again — the glass frosts what's beneath, and overlapping events join in. Runs on macOS 15+ with a material fallback."),
                .init(.improved, "The **delete dialog** is systematic: *Remove from Lane* for promoted bars, *Hide Occurrence / Hide Series / Unhide* for imported events."),
                .init(.improved, "Note-preview **checkboxes** match the dashboard TODO list — same styling, strike-through on done, `done:` stamps on toggle."),
                .init(.improved, "**Projects panel** opens without lag — scoring and date math rebuilt, note indexing moved off the main thread."),
                .init(.fixed, "Per-occurrence (*This Event*) notes save correctly and round-trip through iCloud."),
                .init(.fixed, "Deleted events no longer resurrect from other calendars' iCloud zones; Settings ▸ Developer can prune orphaned zones."),
                .init(.fixed, "`.ics` import keeps Outlook/Exchange events at the right time — full timezone resolution (Windows zone names, embedded VTIMEZONE rules, UTC offsets)."),
                .init(.fixed, "Clicking a note-sourced TODO lands in the note editor at that line; imported events no longer offer a Repeat section (recurrence belongs to the source calendar)."),
            ]
        ),
        ChangelogRelease(
            version: "0.1.0", date: "July 21, 2026",
            headline: "The baseline: a calendar you zoom.",
            changes: [
                .init(.added, "The zoomable calendar: year, month, week, and day on one canvas — continuous gestures, timed events, multi-day bands, deadlines with origin timezones, recurrence, and full keyboard control (⌘K guide)."),
                .init(.added, "Daily / weekly / monthly **dashboards**: a TODO index over event and note tasks (nested sub-tasks with folding), upcoming deadlines, and per-scope Markdown notes."),
                .init(.added, "**Markdown notes** everywhere, with task lists and a todo token language (`due:` `start:` `p:` `followup:` `#tag` `@project`)."),
                .init(.added, "**Apple Calendar** import (read-only), `.ics` import/export, iCloud sync across Macs, multiple calendars, and notifications with per-kind preferences."),
                .init(.added, "An optional **AI assistant** that reads and edits the calendar through audited tools, with your own API keys."),
                .init(.added, "An iPhone **companion app** (read-only) over the same iCloud data."),
            ]
        ),
    ]
}

// ── View ─────────────────────────────────────────────────────────────────────────

/// The What's New window's content: releases newest-first, each entry a kind badge + text.
public struct ChangelogView: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(ChangelogContent.releases) { release in
                    releaseView(release, theme)
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(theme.bg)
        .frame(minWidth: 480, idealWidth: 620, minHeight: 420, idealHeight: 640)
    }

    private func releaseView(_ release: ChangelogRelease, _ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Version \(release.version)")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                Text(release.date)
                    .font(.system(size: 12)).foregroundStyle(theme.textMuted)
            }
            if let headline = release.headline {
                Text(headline).font(.system(size: 13)).foregroundStyle(theme.textMuted)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(release.changes) { change in
                    changeRow(change, theme)
                }
            }
            .padding(.top, 2)
        }
    }

    private func changeRow(_ change: ChangelogChange, _ theme: Theme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(change.kind.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(change.kind.tint)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(change.kind.tint.opacity(0.14)))
                .frame(width: 76, alignment: .trailing) // badges align; text starts on one column
            Text(.init(change.text)) // inline markdown (bold/italic/code)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
