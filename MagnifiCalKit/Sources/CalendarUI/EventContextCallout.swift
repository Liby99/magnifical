// The right-click callouts — compact popovers (the same NSPopover chrome as the assistant
// callout, so they can overflow the window edge). EventContextCallout: color row + action rows
// for a clicked event. SpaceContextCallout: create/paste for a clicked empty spot. Actions are
// injected so every row reuses the exact path its hotkey takes; they're bundled into
// EventMenuActions built field-by-field — NEVER grow a many-argument call here (type-checker
// cliff, bisected 2026-07-18).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI
import UniformTypeIdentifiers

/// Every action the event callout can trigger. Assignment-style construction only.
struct EventMenuActions {
    var details: () -> Void = {}
    var rename: () -> Void = {}
    var cut: () -> Void = {}
    var copy: () -> Void = {}
    var pasteHere: () -> Void = {}
    var repeatCfg: () -> Void = {}
    var promote: () -> Void = {}
    var goOriginal: () -> Void = {}
    var occurrence: (Int) -> Void = { _ in } // −1 previous / +1 next
    var exportICS: () -> Void = {}
    var email: () -> Void = {}
    var delete: () -> Void = {}
    var close: () -> Void = {}
}

/// Presents both callouts on the calendar content with explicit anchor RECTs (an offset proxy
/// view does NOT work — popover anchoring uses the layout frame, not render transforms).
/// `arrowEdge: .trailing` puts them on the RIGHT; AppKit flips left at screen edges.
struct EventMenuOverlay: ViewModifier {
    var ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    let onRename: (String) -> Void
    let onCopy: () -> Void
    var onCut: () -> Void = {}
    var onPaste: () -> Void = {}
    var readClip: () -> CalendarEngine.ClipPayload? = { nil }

    private var shown: Binding<Bool> {
        Binding<Bool>(get: { ui.eventMenu != nil }, set: {
            (v: Bool) in if !v {
                ui.eventMenu = nil
            }
        })
    }

    private var spaceShown: Binding<Bool> {
        Binding<Bool>(get: { ui.spaceMenu != nil }, set: {
            (v: Bool) in if !v {
                ui.spaceMenu = nil
            }
        })
    }

    private func eventActions(_ id: String) -> EventMenuActions {
        var a = EventMenuActions()
        a.details = { ui.openEventId = sourceId(of: id) }
        a.rename = { onRename(id) }
        a.cut = { onCut() }
        a.copy = { onCopy() }
        a.pasteHere = {
            if let clip = readClip() {
                engine.pasteHere(clip, on: id)
            }
        }
        a.repeatCfg = { ui.openRepeatOnOpen = true; ui.openEventId = sourceId(of: id) }
        a.promote = { engine.togglePromote(id) }
        a.goOriginal = { engine.goToBox(sourceId(of: id)) }
        a.occurrence = {
            dir in if let t = engine.neighborOccurrence(of: id, dir: dir) {
                engine.goToBox(t)
            }
        }
        a.exportICS = { Self.exportICS(engine: engine, boxId: id) }
        a.email = { Self.emailEvent(engine: engine, boxId: id) }
        a.delete = {
            if let t = engine.deleteTargetForSelection() {
                ui.requestDelete(id: t.id, occKey: t.occKey, recurring: t.recurring,
                                 imported: t.imported, alreadyHidden: t.alreadyHidden,
                                 kind: engine.kind(of: t.id) ?? .timed,
                                 viaGhost: t.viaGhost, atBase: t.atBase)
            }
        }
        a.close = { ui.eventMenu = nil }
        return a
    }

    /// New Event from the empty-space menu: a 1-hour timed event on a timeline slot, a 1-day
    /// band on a lane cell. Opens the drawer with the title selected, like the deadline "+".
    private func createAtSpot(_ spot: CalendarEngine.EmptySpot) {
        let id: String
        switch spot {
        case let .timeline(y, m, d, h):
            let start = min(h, 23)
            id = engine.createTimedEvent(year: y, month: m, day: d, startHour: start,
                                         endHour: min(start + 1, 24), title: "New event", color: "blue")
        case let .bandLane(y, m, t, d):
            id = engine.createBand(year: y, month: m, track: t, startDay: d, endDay: d,
                                   title: "New event", color: "blue")
        }
        ui.selectTitleOnOpen = true; ui.openEventId = id
    }

    private func createDeadlineAtSpot(_ spot: CalendarEngine.EmptySpot) {
        guard case let .timeline(y, m, d, h) = spot else { return }
        let id = engine.createDeadline(year: y, month: m, day: d, hour: min(h, 23.75),
                                       title: "New Deadline", color: "default")
        ui.selectTitleOnOpen = true; ui.openEventId = id
    }

    func body(content: Content) -> some View {
        content.popover(isPresented: shown,
                        attachmentAnchor: .rect(.rect(ui.eventMenu?.anchor ?? .zero)),
                        arrowEdge: .trailing) {
            if let menu = ui.eventMenu {
                EventContextCallout(engine: engine, id: menu.id, theme: theme,
                                    clipKind: readClip()?.kind, actions: eventActions(menu.id))
            }
        }
        .popover(isPresented: spaceShown,
                 attachmentAnchor: .rect(.rect(ui.spaceMenu?.anchor ?? .zero)),
                 arrowEdge: .trailing) {
            if let menu = ui.spaceMenu {
                SpaceContextCallout(
                    spot: menu.spot, theme: theme, clipKind: readClip()?.kind,
                    onNewEvent: { createAtSpot(menu.spot) },
                    onNewDeadline: { createDeadlineAtSpot(menu.spot) },
                    onPaste: { onPaste() },
                    onClose: { ui.spaceMenu = nil }
                )
            }
        }
    }

    /// ── Export / email (Apple Mail via NSSharingService) ──
    private static func icsFileName(engine: CalendarEngine, boxId: String) -> String {
        let src = sourceId(of: boxId)
        let title = engine.event(src)?.title ?? engine.band(src)?.title ?? engine.deadline(src)?.title ?? "event"
        let safe = String(title.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "-" })
            .trimmingCharacters(in: .whitespaces)
        return (safe.isEmpty ? "event" : safe) + ".ics"
    }

    static func exportICS(engine: CalendarEngine, boxId: String) {
        guard let ics = engine.icsText(for: boxId) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        panel.nameFieldStringValue = icsFileName(engine: engine, boxId: boxId)
        if panel.runModal() == .OK, let url = panel.url {
            try? Data(ics.utf8).write(to: url)
        }
    }

    static func emailEvent(engine: CalendarEngine, boxId: String) {
        guard let ics = engine.icsText(for: boxId) else { return }
        let name = icsFileName(engine: engine, boxId: boxId)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? Data(ics.utf8).write(to: tmp)) != nil,
              let svc = NSSharingService(named: .composeEmail) else { NSSound.beep(); return }
        svc.subject = String(name.dropLast(4)) // event title (sans .ics)
        svc.perform(withItems: [tmp])
    }
}

struct EventContextCallout: View {
    let engine: CalendarEngine
    let id: String // the clicked BOX id (a ghost is fine; actions resolve the source)
    let theme: Theme
    let clipKind: String? // "timed" | "band" | "deadline" on the pasteboard, else nil
    let actions: EventMenuActions

    private var imported: Bool {
        engine.isImported(id)
    }

    private var kind: CalendarEngine.ItemKind? {
        // IncludingImported: plain kind(of:) only sees the editable store, which hid the
        // kind-gated overlay rows (Promote, Paste Here) on imported boxes.
        engine.kindIncludingImported(id)
    }

    private var promoted: Bool {
        engine.promoteTrack(id) != nil
    }

    private var isGhost: Bool {
        sourceId(of: id) != id
    } // recurrence occurrence / promoted mirror
    private var recurring: Bool {
        engine.repeatConfig(sourceId(of: id)) != nil
    }

    private var canPasteHere: Bool {
        clipKind == "timed" || clipKind == "deadline"
    }

    private var currentColor: String {
        if let o = engine.colorOverride(id) {
            return o
        }
        return engine.event(sourceId(of: id))?.color
            ?? engine.band(sourceId(of: id))?.color
            ?? engine.deadline(sourceId(of: id))?.color ?? "default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            colorRow.padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 6)
            Divider().padding(.bottom, 3)
            row("Details", icon: "info.circle", key: "Space", action: actions.details)
            if !imported { // imported bodies are read-only (rename/repeat live in Calendar.app)
                row("Rename", icon: "pencil", key: "⏎", action: actions.rename)
            }
            row("Cut", icon: "scissors", key: "⌘X", disabled: !engine.cutEligible(id), action: actions.cut)
            row("Copy", icon: "doc.on.doc", key: "⌘C", action: actions.copy)
            if kind == .timed {
                row("Paste Here", icon: "doc.on.clipboard", key: nil, disabled: !canPasteHere,
                    action: actions.pasteHere)
            }
            if !imported {
                row("Repeat…", icon: "repeat", key: nil, action: actions.repeatCfg)
            }
            if kind == .timed || kind == .deadline { // promote is an overlay (imported timed events too)
                row(promoted ? "Unpromote" : "Promote", icon: promoted ? "arrow.uturn.down" : "arrow.up.to.line",
                    key: "⌘U", action: actions.promote)
            }
            if isGhost || recurring {
                Divider().padding(.vertical, 3)
                if isGhost {
                    row("Go to Original", icon: "arrow.uturn.backward.circle", key: nil, action: actions.goOriginal)
                }
                if recurring {
                    row("Previous Occurrence", icon: "chevron.backward.circle", key: nil,
                        disabled: engine.neighborOccurrence(of: id, dir: -1) == nil) { actions.occurrence(-1) }
                    row("Next Occurrence", icon: "chevron.forward.circle", key: nil,
                        disabled: engine.neighborOccurrence(of: id, dir: 1) == nil) { actions.occurrence(1) }
                }
            }
            Divider().padding(.vertical, 3)
            row("Export .ics…", icon: "square.and.arrow.up", key: nil, action: actions.exportICS)
            row("Email Event…", icon: "envelope", key: nil, action: actions.email)
            Divider().padding(.vertical, 3)
            row(imported ? "Hide" : "Delete", icon: imported ? "eye.slash" : "trash", key: "⌫",
                destructive: true, action: actions.delete)
        }
        .padding(6)
        .frame(width: 208)
    }

    /// ── Quick colors: the web's MENU_COLORS subset of the drawer's full palette ──
    private var colorRow: some View {
        HStack(spacing: 7) {
            ForEach(MENU_COLORS, id: \.self) { key in
                Circle()
                    .fill(theme.eventBorder(key))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(theme.text, lineWidth: key == currentColor ? 2 : 0))
                    .contentShape(Circle())
                    .onHover { hovering in
                        if hovering {
                            engine.setColorPreview(id, key)
                        } else {
                            engine.clearColorPreview(key)
                        }
                    }
                    .onTapGesture { commitColor(key); actions.close() }
                    .help(key)
            }
            Spacer(minLength: 0)
        }
    }

    private func commitColor(_ v: String) {
        // Mirrors the drawer: imported events keep a local color overlay; own items edit the body.
        let sid = sourceId(of: id)
        if imported {
            engine.setColorOverride(sid, v); return
        }
        switch kind {
        case .timed: engine.update(sid) { $0.color = v }
        case .band: engine.updateBand(sid) { $0.color = v }
        case .deadline: engine.updateDeadline(sid) { $0.color = v }
        default: break
        }
    }

    /// ── One menu row: icon + label, hotkey right-aligned, hover highlight; closes after ──
    private func row(_ label: String, icon: String, key: String?, destructive: Bool = false,
                     disabled: Bool = false, action: @escaping () -> Void) -> some View {
        MenuRow(label: label, icon: icon, key: key, destructive: destructive, disabled: disabled,
                theme: theme) {
            action(); actions.close()
        }
    }
}

/// The empty-space right-click callout: create actions for the clicked spot + Paste. Timeline
/// slots (week/day) offer New Event + New Deadline and accept timed/deadline pastes; band-lane
/// cells offer New Event (a band) and accept band pastes.
struct SpaceContextCallout: View {
    let spot: CalendarEngine.EmptySpot
    let theme: Theme
    let clipKind: String?
    let onNewEvent: () -> Void
    let onNewDeadline: () -> Void
    let onPaste: () -> Void
    let onClose: () -> Void

    private var isTimeline: Bool {
        if case .timeline = spot {
            return true
        }; return false
    }

    private var canPaste: Bool {
        guard let clipKind else { return false }
        return isTimeline ? (clipKind == "timed" || clipKind == "deadline") : clipKind == "band"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            MenuRow(label: "New Event", icon: "plus.square", key: isTimeline ? "⌘N" : nil,
                    destructive: false, theme: theme) { onNewEvent(); onClose() }
            if isTimeline {
                MenuRow(label: "New Deadline", icon: "flag", key: "⌘L",
                        destructive: false, theme: theme) { onNewDeadline(); onClose() }
            }
            Divider().padding(.vertical, 3)
            MenuRow(label: "Paste", icon: "doc.on.clipboard", key: "⌘V",
                    destructive: false, disabled: !canPaste, theme: theme) { onPaste(); onClose() }
        }
        .padding(6)
        .frame(width: 172)
    }
}

struct MenuRow: View { // internal (was private): reused by the PROJ row callout (NativeProjPanel)
    let label: String
    let icon: String
    let key: String?
    let destructive: Bool
    var disabled: Bool = false
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .frame(width: 15)
                Text(label).font(.system(size: 12.5))
                Spacer(minLength: 12)
                if let key {
                    Text(key).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(disabled ? theme.text.opacity(0.35) : (destructive ? Color.red : theme.text))
            .padding(.horizontal, 7).padding(.vertical, 4.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering && !disabled ? theme.text.opacity(0.09) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}
