// The phone's full-screen Menu — the heavy-lifting surface behind the toolbar's "Menu"
// button (calendar switching, sync, and future configuration like tag filtering live here,
// keeping the calendar surface itself chrome-free). Presented as a fullScreenCover.

import CalendarEngine
import SwiftUI

struct PhoneMenuView: View {
    let engine: CalendarEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cc.fpsHUD") private var fpsHUD = false // same key as the Mac's Developer toggle

    var body: some View {
        NavigationStack {
            List {
                Section("Calendar") {
                    ForEach(engine.allCalendars, id: \.id) { c in
                        Button {
                            if c.id != engine.activeCalendar?.id {
                                engine.switchCalendar(to: c.id)
                            }
                        } label: {
                            HStack {
                                Text(c.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if c.id == engine.activeCalendar?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("iCloud") {
                    syncRow
                    Button("Sync now") {
                        engine.syncMonitor.isSyncing = true
                        engine.syncNow()
                    }
                    .disabled(engine.syncMonitor.isSyncing)
                }

                Section("Filters") {
                    Text("Tag filtering is coming to iPhone.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Frame rate HUD", isOn: $fpsHUD)
                } header: {
                    Text("Developer")
                } footer: {
                    Text(
                        "fps · p95 · max over the last second. Numbers are only meaningful in a Release build — Debug SwiftUI is far slower."
                    )
                }
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var syncRow: some View {
        HStack(spacing: 8) {
            let m = engine.syncMonitor
            let _ = m.minuteTick // re-render each minute so the relative label advances
            if m.isSyncing {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            } else if let at = m.lastSyncedAt {
                Image(systemName: "checkmark.icloud")
                Text("Synced \(at.formatted(.relative(presentation: .named)))")
            } else {
                Image(systemName: "icloud.slash")
                Text(m.cloudEnabled ? "Not synced yet" : "Local only")
            }
        }
        .foregroundStyle(.secondary)
    }
}
