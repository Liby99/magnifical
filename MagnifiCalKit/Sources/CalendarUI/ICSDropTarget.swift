// Drag-and-drop .ics import for the main calendar window: drag calendar files from Finder
// anywhere over the window → a full-window mask (dashed border, centered "Drop .ics files
// here") → drop runs the same engine.importICS path as File ▸ Import, one summary alert for
// the batch (MenuFileActions.importICSFiles).

import CalendarEngine
import CalendarRender
import SwiftUI
import UniformTypeIdentifiers

/// Validates that the drag actually carries .ics files (so random file drags never flash the
/// mask), drives the overlay's visibility, and resolves the dropped file URLs on the drop.
struct ICSDropDelegate: DropDelegate {
    let engine: CalendarEngine
    @Binding var active: Bool

    /// com.apple.ical.ics — resolved from the extension so we don't hardcode the identifier.
    static let icsType = UTType(filenameExtension: "ics")

    func validateDrop(info: DropInfo) -> Bool {
        guard let t = Self.icsType else { return info.hasItemsConforming(to: [.fileURL]) }
        return info.hasItemsConforming(to: [t])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.12)) { active = true }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.12)) { active = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.easeOut(duration: 0.12)) { active = false }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        // Providers resolve asynchronously (and off-main); gather every URL, then import the
        // batch on main in one pass so multiple files produce ONE summary alert.
        let group = DispatchGroup()
        let box = URLBox()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL? = (item as? URL)
                    ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url {
                    box.append(url)
                }
            }
        }
        let engine = engine
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                MenuFileActions.importICSFiles(box.urls, engine: engine)
            }
        }
        return true
    }

    /// Thread-safe URL collector for the concurrent provider callbacks.
    final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        var urls: [URL] {
            lock.lock(); defer { lock.unlock() }; return stored
        }

        func append(_ u: URL) {
            lock.lock(); stored.append(u); lock.unlock()
        }
    }
}

/// The full-window drop mask: a frosted wash, a large dashed border just inside the window
/// edges, and the centered import glyph + "Drop .ics files here".
struct ICSDropOverlay: View {
    let theme: Theme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Theme.accent.opacity(0.85),
                              style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                .padding(16)
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 44, weight: .medium))
                Text("Drop .ics files here")
                    .font(.system(size: 21, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .allowsHitTesting(false) // visual only — the drop lands on the window's drop target
        .transition(.opacity)
    }
}
