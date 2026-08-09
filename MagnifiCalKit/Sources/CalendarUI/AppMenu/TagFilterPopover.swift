// View ▸ Filter by Tags — a stay-open checklist popover (macOS menus can't stay open while multi-toggling;
// see the AppMenu notes). Shows the 10 most-used tags by default with a search field to reach the rest;
// the tag universe is served from the engine's per-edit cache (CalendarEngine.tagUniverse). Toggling a row
// writes the hidden-tags pref and repaints the calendar (.calendarViewPrefsChanged → engine.viewPrefsChanged).

import CalendarEngine
import SwiftUI

public struct TagFilterPopover: View {
    let engine: CalendarEngine
    @State private var query = ""
    @State private var tick = 0 // bumped on each toggle so checkmarks re-read the pref live
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme

    public init(engine: CalendarEngine) {
        self.engine = engine
    }

    private var hidden: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: PrefKeys.hiddenTags) ?? [])
    }

    private func setHidden(_ s: Set<String>) {
        UserDefaults.standard.set(Array(s).sorted(), forKey: PrefKeys.hiddenTags)
        NotificationCenter.default.post(name: .calendarViewPrefsChanged, object: nil)
        tick += 1
    }

    private func toggle(_ key: String) {
        var s = hidden; if s.contains(key) {
            s.remove(key)
        } else {
            s.insert(key)
        }; setHidden(s)
    }

    private func bind(_ key: String) -> Binding<Bool> { // ✓ = shown → the key is NOT in the hidden set
        Binding(get: { !hidden.contains(key) }, set: { _ in toggle(key) })
    }

    public var body: some View {
        let _ = tick
        let uni = engine.tagUniverse()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty
        // Idle → the 10 most-used tags; searching → every match across the full (cached) universe.
        let rows = searching
            ? uni.rows.filter { $0.key.contains(q) || $0.label.lowercased().contains(q) }
            : Array(uni.rows.prefix(10))
        let showUntagged = uni.untagged > 0 && (!searching || "untagged".contains(q))
        let allKeys = Set(uni.rows.map(\.key) + (uni.untagged > 0 ? [CalendarEngine.untaggedKey] : []))
        let theme = Theme(dark: scheme == .dark)

        VStack(alignment: .leading, spacing: 8) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search tags", text: $query).textFieldStyle(.plain).focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.text.opacity(0.08)))

            if !searching, !uni.rows.isEmpty {
                Text(uni.rows.count > 10 ? "Top 10 of \(uni.rows.count) tags — search for more"
                    : "\(uni.rows.count) tag\(uni.rows.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            // Tag rows (✓ = shown). A checkbox toggle keeps the popover open on each click.
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if rows.isEmpty, !showUntagged {
                        Text(searching ? "No matching tags" : "No tags yet")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                    ForEach(rows, id: \.key) { row in
                        Toggle(isOn: bind(row.key)) { tagRow(row.label, row.count) }
                    }
                    if showUntagged {
                        Toggle(isOn: bind(CalendarEngine.untaggedKey)) { tagRow("Untagged", uni.untagged, italic: true)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 260)

            Divider()
            HStack {
                Button("Show All") { setHidden([]) }.disabled(hidden.isEmpty)
                Spacer()
                Button("Show None") { setHidden(allKeys) }
                    .disabled(allKeys.isEmpty || allKeys.isSubset(of: hidden))
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .frame(width: 280)
        .tint(Theme.accent) // app accent on the checkboxes + buttons (default was system blue)
        .onAppear { searchFocused = true }
    }

    private func tagRow(_ label: String, _ count: Int, italic: Bool = false) -> some View {
        HStack {
            Text(label).italic(italic)
            Spacer(minLength: 8)
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
