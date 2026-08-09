// A deliberately plain SwiftUI harness over CalendarEngine — NOT the real calendar UI.
// It exists to see the CloudKit sync layer working on iPhone: the lists reflect whatever the
// engine currently holds (seeds + anything pulled from CloudKit via applyRemote), and the row
// actions mutate through the engine's public API so the edit pushes back up to the Mac.
//
// CalendarEngine isn't @Observable (it's driven by a per-frame clock on macOS), so we re-read it
// on a 1s TimelineView tick rather than via property observation — coarse, but all a harness needs.

import CalendarEngine
import CalendarGeometry
import CloudKit
import SwiftUI

struct SyncHarnessView: View {
    let engine: CalendarEngine
    @State private var account = "checking…"

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                List {
                    Section("iCloud") {
                        LabeledContent("Account", value: account)
                        Button("Sync now") { engine.syncNow() }
                    }

                    Section("Bands (\(engine.items.bands.count))") {
                        ForEach(engine.items.bands, id: \.id) { b in
                            row(title: b.title,
                                subtitle: "\(b.year)-\(b.month + 1) · lane \(b.track) · \(b.startDay)–\(b.endDay)",
                                color: b.color,
                                bump: { engine.setBandTitle(b.id, b.title + "·") })
                        }
                        .onDelete { idx in idx.map { engine.items.bands[$0].id }.forEach(engine.remove) }
                    }

                    Section("Timed (\(engine.items.events.count))") {
                        ForEach(engine.items.events, id: \.id) { e in
                            row(title: e.title,
                                subtitle: "m\(e.month + 1) d\(e.day) · \(fmt(e.startHour))–\(fmt(e.endHour))",
                                color: e.color,
                                bump: { engine.update(e.id) { $0.title += "·" } })
                        }
                        .onDelete { idx in idx.map { engine.items.events[$0].id }.forEach(engine.remove) }
                    }

                    Section("Deadlines (\(engine.items.deadlines.count))") {
                        ForEach(engine.items.deadlines, id: \.id) { d in
                            row(title: d.title,
                                subtitle: "\(d.year)-\(d.month + 1)-\(d.day) · \(fmt(d.hour))",
                                color: d.color,
                                bump: { engine.updateDeadline(d.id) { $0.title += "·" } })
                        }
                        .onDelete { idx in idx.map { engine.items.deadlines[$0].id }.forEach(engine.remove) }
                    }
                }
            }
            .navigationTitle("Calendar Sync")
            .toolbar { EditButton() }
        }
        .task { await refreshAccount() }
    }

    /// One item row: a color dot, the title, a compact field summary, and a "bump" button that
    /// appends a marker to the title so you can watch the edit propagate to the other device.
    private func row(title: String, subtitle: String, color: String, bump: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Circle().fill(swatch(color)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "(untitled)" : title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { bump() } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
        }
    }

    private func fmt(_ hour: CGFloat) -> String {
        let h = Int(hour), m = Int((hour - CGFloat(Int(hour))) * 60)
        return String(format: "%02d:%02d", h, m)
    }

    private func swatch(_ key: String) -> Color {
        switch key {
        case "red", "rose": .red
        case "orange": .orange
        case "yellow", "amber": .yellow
        case "green": .green
        case "blue": .blue
        case "purple", "violet": .purple
        case "pink": .pink
        default: .gray
        }
    }

    private func refreshAccount() async {
        let container = CKContainer(identifier: "iCloud.dev.libirabu.calendar")
        let status = await (try? container.accountStatus()) ?? .couldNotDetermine
        account = {
            switch status {
            case .available: return "available"
            case .noAccount: return "no iCloud account"
            case .restricted: return "restricted"
            case .couldNotDetermine: return "unknown"
            case .temporarilyUnavailable: return "temporarily unavailable"
            @unknown default: return "unknown"
            }
        }()
    }
}
