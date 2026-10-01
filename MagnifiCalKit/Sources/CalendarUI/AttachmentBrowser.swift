// Settings ▸ Developer ▸ "Browse Attachments…" — the file browser over the attachment store:
// every imported blob with its type/size/date, EVERYTHING that references it (the reverse
// index, computed live from the notes — see AttachmentInventory.swift for why it is derived,
// never stored), orphans (no references) and ghosts (referenced, blob still syncing) both
// flagged. Reveal-in-Finder and Quick Look per row. One shared window, both shells.

import AppKit
import CalendarEngine
import CalendarRender
import QuickLookUI
import SwiftUI

public extension Notification.Name {
    /// Settings ▸ Developer posts; CalendarView (which owns the engine) opens the window.
    static let openAttachmentBrowser = Notification.Name("cc.attachments.browse")
    /// Settings ▸ Developer "Sweep Attachments Now" — the daily pass, run on demand.
    static let sweepAttachments = Notification.Name("cc.attachments.sweep")
}

/// Run the sweep and show the result — the Developer button's handler (CalendarView receives).
@MainActor public func runAttachmentSweepNow(_ engine: CalendarEngine) {
    let r = engine.sweepAttachments()
    let a = NSAlert()
    a.messageText = "Attachment sweep complete"
    a.informativeText = r.swept == 0
        ? "Nothing to reclaim. \(r.referenced) referenced file\(r.referenced == 1 ? "" : "s"), "
        + "\(r.inGrace) unreferenced within the 7-day grace period."
        : "Deleted \(r.swept) file\(r.swept == 1 ? "" : "s") "
        + "(\(AttachmentCards.fmtBytes(r.sweptBytes))). \(r.referenced) referenced kept, "
        + "\(r.inGrace) unreferenced still in the 7-day grace period."
    a.alertStyle = .informational
    a.addButton(withTitle: "OK")
    a.runModal()
}

/// The shared browser window (the Help/Changelog window pattern, engine-parameterized).
@MainActor public enum AttachmentBrowser {
    private static var window: NSWindow?

    /// userInfo key on .openAttachmentBrowser: a token id / hash (prefix ok) whose row the
    /// browser should reveal — expanded, scrolled to, briefly highlighted.
    public static let focusKey = "focusId"

    public static func show(engine: CalendarEngine,
                            navigate: ((AttachmentRef) -> Void)? = nil,
                            focus: String? = nil) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Attachments"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // Fresh content on every open — the inventory is a live scan, not a cache.
        window?.contentView = NSHostingView(
            rootView: AttachmentBrowserView(engine: engine, navigate: navigate, focus: focus))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AttachmentBrowserView: View {
    let engine: CalendarEngine
    let navigate: ((AttachmentRef) -> Void)?
    var focus: String? = nil // a token id/hash prefix: reveal this row on open
    @Environment(\.colorScheme) private var scheme
    @State private var rows: [AttachmentInventoryRow] = []
    @State private var expanded: Set<String> = []
    @State private var focusedRow: String? // briefly highlighted (the "here it is" flash)

    var body: some View {
        let theme = Theme(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 0) {
            header(theme)
            Divider()
            if rows.isEmpty {
                Text("No attachments yet — paste or drag files into any note.")
                    .font(.system(size: 12)).foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row in
                                rowView(row, theme).id(row.id)
                            }
                        }
                        .padding(10)
                    }
                    .onAppear { revealFocusedRow(proxy) }
                }
            }
        }
        .background(theme.bg)
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { rows = engine.attachmentInventory() }
    }

    /// "Show in Attachment Browser": expand the focused file's row, scroll it to center,
    /// and flash a highlight so the eye lands on it. `focus` may be a token PREFIX (the
    /// preview's id) or a full hash; ghost rows are keyed by the prefix itself.
    private func revealFocusedRow(_ proxy: ScrollViewProxy) {
        guard let focus,
              let row = rows.first(where: { $0.id.hasPrefix(focus) || focus.hasPrefix($0.id) })
        else { return }
        if !row.refs.isEmpty {
            expanded.insert(row.id)
        }
        focusedRow = row.id
        proxy.scrollTo(row.id, anchor: .center)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation(.easeOut(duration: 0.6)) { focusedRow = nil }
        }
    }

    private func header(_ theme: Theme) -> some View {
        let bytes = rows.compactMap(\.meta?.bytes).reduce(0, +)
        let orphans = rows.filter { $0.refs.isEmpty }.count
        let waiting = rows.filter { $0.meta == nil }.count
        var parts = ["\(rows.count) file\(rows.count == 1 ? "" : "s")",
                     AttachmentCards.fmtBytes(bytes)]
        if orphans > 0 {
            parts.append("\(orphans) unreferenced")
        }
        if waiting > 0 {
            parts.append("\(waiting) waiting for iCloud")
        }
        return HStack {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
            Spacer()
            if orphans > 0 {
                Button("Remove Unreferenced…") {
                    removeBlobs(rows.filter { $0.refs.isEmpty && $0.meta != nil })
                }
                .font(.system(size: 11))
            }
            Button("Refresh") { rows = engine.attachmentInventory() }
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Delete orphan blobs, confirmed. Only unreferenced files ever reach here — the trash
    /// button and the header bulk button both filter on refs.isEmpty first.
    private func removeBlobs(_ doomed: [AttachmentInventoryRow]) {
        guard !doomed.isEmpty else { return }
        let bytes = doomed.compactMap(\.meta?.bytes).reduce(0, +)
        let a = NSAlert()
        a.messageText = doomed.count == 1
            ? "Remove “\(doomed[0].name)”?"
            : "Remove \(doomed.count) unreferenced files?"
        a.informativeText = "No note in any calendar references "
            + (doomed.count == 1 ? "this file" : "these files")
            + ". \(AttachmentCards.fmtBytes(bytes)) will be deleted from the attachment store. "
            + "This cannot be undone."
        a.alertStyle = .warning
        a.addButton(withTitle: "Remove").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for row in doomed {
            engine.attachments.remove(hash: row.id)
        }
        rows = engine.attachmentInventory()
    }

    @ViewBuilder private func rowView(_ row: AttachmentInventoryRow, _ theme: Theme) -> some View {
        let open = expanded.contains(row.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textMuted)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .opacity(row.refs.isEmpty ? 0 : 1)
                icon(row)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(detail(row))
                        .font(.system(size: 10.5)).foregroundStyle(theme.textMuted)
                }
                Spacer(minLength: 8)
                refBadge(row, theme)
                if let url = engine.attachments.url(forId: row.id) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [engine.attachments.displayURL(forId: row.id) ?? url])
                    } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).foregroundStyle(theme.textMuted)
                        .help("Reveal in Finder")
                }
                if row.refs.isEmpty, row.meta != nil {
                    Button { removeBlobs([row]) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Color.orange)
                        .help("Remove this unreferenced file")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !row.refs.isEmpty else { return }
                if open {
                    expanded.remove(row.id)
                } else {
                    expanded.insert(row.id)
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(row.refs) { ref in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8)).foregroundStyle(theme.textMuted)
                            Text(ref.label)
                                .font(.system(size: 11)).foregroundStyle(theme.text.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            // Navigation runs on the OPEN calendar's engine, so other
                            // calendars' references stay label-only.
                            if ref.inActiveCalendar, let navigate {
                                Button { navigate(ref) } label: {
                                    Image(systemName: "arrow.up.forward")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.plain).foregroundStyle(Color(Theme.accent))
                                .help("Show in calendar")
                            }
                        }
                    }
                }
                .padding(.leading, 46).padding(.bottom, 3)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(focusedRow == row.id ? Color(Theme.accent).opacity(0.14)
                : theme.text.opacity(row.refs.isEmpty ? 0.035 : 0)))
        .animation(.easeOut(duration: 0.12), value: open)
    }

    private func icon(_ row: AttachmentInventoryRow) -> some View {
        Group {
            if row.meta == nil {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 15)).foregroundStyle(Color.secondary)
            } else if let url = engine.attachments.url(forId: row.id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "doc").font(.system(size: 15))
            }
        }
        .frame(width: 24)
    }

    private func detail(_ row: AttachmentInventoryRow) -> String {
        guard let meta = row.meta else {
            return "waiting for iCloud · \(String(row.id.prefix(16)))"
        }
        return "\(AttachmentCards.fmtBytes(meta.bytes)) · added \(meta.addedAt) · \(String(row.id.prefix(16)))"
    }

    private func refBadge(_ row: AttachmentInventoryRow, _ theme: Theme) -> some View {
        Text(row.refs.isEmpty ? "unreferenced"
            : "\(row.refs.count) ref\(row.refs.count == 1 ? "" : "s")")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(row.refs.isEmpty ? Color.orange : Color(Theme.accent))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(
                (row.refs.isEmpty ? Color.orange : Color(Theme.accent)).opacity(0.13)))
    }
}
