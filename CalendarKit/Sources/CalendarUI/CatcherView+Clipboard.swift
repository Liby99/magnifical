// CatcherView's clipboard surface: Copy/Cut/Paste/Delete responders, menu validation
// (NSMenuItemValidation, declared on the class), and the NSPasteboard plumbing. The
// selectAll(_:) responder stays in CalendarInputLayer.swift — it overrides
// NSResponder.selectAll, and overrides must live in the class body.
// Split from CalendarInputLayer.swift (audit round, 2026-08-02).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

extension CatcherView {
    /// ── Clipboard: Copy / Cut / Paste / Delete (Edit menu + ⌘C/⌘X/⌘V, targeting the first responder) ──
    private static let clipType = NSPasteboard.PasteboardType("com.libirabu.calendarkit.clip")

    /// Unambiguous entry point for programmatic copy (the context menu): `copy(nil)` from outside
    /// collides with NSObject's `copy()`/`copy(with:)` overloads, this name can't.
    func copySelection() {
        copy(nil as Any?)
    }

    func cutSelection() {
        cut(nil as Any?)
    }

    @objc func copy(_ sender: Any?) {
        guard let engine, let id = engine.selectedId,
              let clip = engine.clipPayload(of: id, full: false) else { NSSound.beep(); return }
        writeClip(clip)
    }

    @objc func cut(_ sender: Any?) {
        guard let engine, let id = engine.selectedId, engine.cutEligible(id),
              let clip = engine.clipPayload(of: id, full: true)
        else { NSSound.beep(); return } // read-only / ghost / promoted → no cut
        writeClip(clip)
        engine.remove(id) // undoable (beginTxn/commitTxn)
    }

    @objc func paste(_ sender: Any?) {
        performPaste()
    }

    /// Unambiguous entry point for programmatic paste (the empty-space context menu).
    func performPaste() {
        guard let engine else { return }
        if importICSFromPasteboard(engine) {
            return
        } // a system .ics file / VCALENDAR text → import
        guard let clip = readClip() else { NSSound.beep(); return }
        if engine.paste(clip) == nil {
            NSSound.beep()
        } // no valid drop target for this kind/view
    }

    @objc func delete(_ sender: Any?) {
        guard engine?.selectedId != nil else { NSSound.beep(); return }
        onRequestDelete?() // raise the confirm dialog (imported → "make invisible", recurring → scope)
    }

    @objc func deselectAll(_ sender: Any?) {
        engine?.deselectAll()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return engine?.canUndo ?? false
        case #selector(redo(_:)): return engine?.canRedo ?? false
        case #selector(copy(_:)): return engine?.selectedId != nil
        case #selector(delete(_:)): return engine?.selectedId != nil
        case #selector(cut(_:)): if let e = engine, let id = e.selectedId {
                return e.cutEligible(id)
            }; return false
        case #selector(paste(_:)): return pasteboardHasPasteable()
        case #selector(selectAll(_:)): return engine
            .map { !($0.viewEvents().isEmpty && $0.viewBands().isEmpty && $0.viewDeadlines().isEmpty) } ?? false
        case #selector(deselectAll(_:)): return !(engine?.selectedIds.isEmpty ?? true)
        default: return true
        }
    }

    /// ── NSPasteboard plumbing ─────────────────────────────────────────────────────
    private func writeClip(_ clip: CalendarEngine.ClipPayload) {
        guard let data = try? JSONEncoder().encode(clip) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.clipType)
        pb.setString(clip.title, forType: .string) // a plain-text flavor so the title can paste elsewhere
    }

    func readClip() -> CalendarEngine.ClipPayload? { // internal: the context menu checks the kind
        NSPasteboard.general.data(forType: Self.clipType).flatMap { try? JSONDecoder().decode(
            CalendarEngine.ClipPayload.self,
            from: $0
        ) }
    }

    /// If the system clipboard holds a `.ics` file (Finder copy) or raw VCALENDAR text, import it and
    /// return true (⌘V then acts as Import). Otherwise false → fall through to the in-app clipboard.
    private func importICSFromPasteboard(_ engine: CalendarEngine) -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let ics = urls.filter { $0.pathExtension.lowercased() == "ics" }
            if !ics.isEmpty {
                let n = ics.reduce(0) { $0 + ((try? engine.importICS(from: $1)) ?? 0) }
                if n == 0 {
                    NSSound.beep()
                }
                return true
            }
        }
        if let s = pb.string(forType: .string), s.contains("BEGIN:VCALENDAR") {
            if ((try? engine.importICS(text: s, provenance: "Clipboard")) ?? 0) == 0 {
                NSSound.beep()
            }
            return true
        }
        return false
    }

    private func pasteboardHasPasteable() -> Bool {
        let pb = NSPasteboard.general
        if pb.data(forType: Self.clipType) != nil {
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: { $0.pathExtension.lowercased() == "ics" }) {
            return true
        }
        if let s = pb.string(forType: .string), s.contains("BEGIN:VCALENDAR") {
            return true
        }
        return false
    }
}
