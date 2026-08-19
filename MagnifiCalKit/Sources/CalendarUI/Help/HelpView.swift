// The in-app Help browser (Help ▸ MagnifiCal Help), hosted in its own window by the AppKit shell. A searchable
// category sidebar on the left, a task topic on the right — the modern stand-in for a registered Help book.
// Content is data (HelpContent); this file is just presentation.

import AppKit
import SwiftUI

public extension Notification.Name {
    /// Open the Help window at a topic (object: the topic id String). Posted by any UI (e.g. the
    /// Settings "How to…" button); each shell listens and shows ITS Help window, and HelpView
    /// selects the topic. Set `HelpNav.pending` before posting, so a not-yet-open window still
    /// lands on the topic when it appears.
    static let openHelpTopic = Notification.Name("cc.help.openTopic")
}

/// The topic a not-yet-created Help window should open on (see .openHelpTopic).
@MainActor public enum HelpNav {
    public static var pending: String?
}

public struct HelpView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var selection: String? // selected topic id
    /// Optional topic to open on launch (e.g. a “?” button could deep-link here later).
    private let initialTopic: String

    public init(initialTopic: String = "welcome") {
        self.initialTopic = initialTopic
    }

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        NavigationSplitView {
            sidebar(theme)
                .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 320)
        } detail: {
            detail(theme)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 500, idealHeight: 620)
        .onAppear {
            if let pending = HelpNav.pending {
                selection = pending // deep-link queued before the window existed
                HelpNav.pending = nil
            } else if selection == nil {
                selection = initialTopic
            }
        }
        // Already-open window: jump straight to the requested topic.
        .onReceive(NotificationCenter.default.publisher(for: .openHelpTopic)) { note in
            if let topic = note.object as? String {
                selection = topic
                HelpNav.pending = nil
            }
        }
    }

    private var results: [HelpTopic] {
        HelpContent.search(query)
    }

    /// ── Sidebar ───────────────────────────────────────────────────────────────────────
    private func sidebar(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search Help", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.text.opacity(0.06)))
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

            List(selection: $selection) {
                if query.isEmpty {
                    ForEach(HelpContent.categories) { cat in
                        Section {
                            ForEach(cat.topics) { topicRow($0, theme) }
                        } header: {
                            Label(cat.title, systemImage: cat.symbol).font(.system(size: 11, weight: .semibold))
                        }
                    }
                } else if results.isEmpty {
                    Text("No results").font(.system(size: 12)).foregroundStyle(theme.textMuted)
                } else {
                    Section("Results") { ForEach(results) { topicRow($0, theme) } }
                }
            }
            .listStyle(.sidebar)
        }
        // Searching: keep a valid selection so the detail always shows something relevant.
        .onChange(of: query) { _, _ in
            if !query.isEmpty, !results.contains(where: { $0.id == selection }) {
                selection = results.first?.id
            }
        }
    }

    private func topicRow(_ topic: HelpTopic, _ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(topic.title).font(.system(size: 13, weight: .medium))
            Text(topic.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
        .tag(topic.id)
    }

    /// ── Detail ────────────────────────────────────────────────────────────────────────
    @ViewBuilder private func detail(_ theme: Theme) -> some View {
        if let id = selection, let topic = HelpContent.allTopics.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if let cat = HelpContent.category(of: id) {
                        Label(cat.title, systemImage: cat.symbol)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textMuted)
                    }
                    Text(topic.title).font(.system(size: 24, weight: .bold)).foregroundStyle(theme.text)
                    Text(topic.summary).font(.system(size: 15)).foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let gif = topic.gif {
                        DemoClip(name: gif, dark: theme.dark)
                            .frame(maxWidth: 540)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(theme.text.opacity(0.08)))
                            .padding(.vertical, 4)
                    }

                    ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block, theme)
                    }
                    if !topic.shortcuts.isEmpty {
                        shortcutsView(topic.shortcuts, theme)
                    }
                }
                .padding(30)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(id) // reset scroll position when switching topics
        } else {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.circle").font(.system(size: 34)).foregroundStyle(theme.textMuted)
                Text("Select a topic").foregroundStyle(theme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func blockView(_ block: HelpBlock, _ theme: Theme) -> some View {
        switch block {
        case let .paragraph(s):
            Text(s).font(.system(size: 14)).foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        case let .steps(xs):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(xs.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 11) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 19, height: 19).background(Circle().fill(Theme.accent))
                        Text(s).font(.system(size: 14)).foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .bullets(xs):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(xs.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.system(size: 14)).foregroundStyle(theme.textMuted)
                        Text(s).font(.system(size: 14)).foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .image(name):
            RemoteStill(name: name, dark: theme.dark)
                .frame(maxWidth: 540)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.text.opacity(0.08)))
                .padding(.vertical, 4)
        case let .tip(s):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "lightbulb.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                Text(s).font(.system(size: 13)).foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent.opacity(0.10)))
        }
    }

    private func shortcutsView(_ shortcuts: [HelpShortcut], _ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHORTCUTS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(theme.textMuted)
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, sc in
                HStack(spacing: 10) {
                    Text(sc.keys).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.text.opacity(0.08)))
                        .frame(minWidth: 44)
                    Text(sc.label).font(.system(size: 13)).foregroundStyle(theme.text)
                }
            }
        }
        .padding(.top, 8)
    }
}

// (Demo clips + stills live in HelpMedia.swift — DemoClip / RemoteStill: bundle → cache → GitHub.)
