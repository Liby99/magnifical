// One native dashboard panel BODY: purely the active tab's content for a (scope, key) — NO
// motion logic lives here. Placement, slides, rides, and fades all come from the geometry's
// dashBodyPanels list (Frames.swift), the same brain the Canvas header draws from; CalendarView
// applies them as frame/offset/opacity. This view existing per (scope, key) is what makes the
// body a REAL member of the carousel instead of a floating mock-up tracking it.

import CalendarEngine
import CalendarRender
import SwiftUI

struct NativePanelHost: View, Equatable {
    let engine: CalendarEngine
    let scope: String // "week" | "month"
    let key: String
    let tab: DashTab
    let theme: Theme
    /// The data generation this render is for — the ONLY non-identity input that should force a
    /// re-evaluation (see ==). Passed by the caller from engine.todoDataStamp.
    var dataStamp: String = ""
    var settings: DashTodoSettings?
    var nav: NativeDashNavModel?
    @Binding var noteMode: NotesMode
    var onOpen: (String, Int?, String?) -> Void
    var onJump: (String, Int?) -> Void = { _, _ in }
    /// TODO/PROJ row-menu Delete → the window-level confirm dialog (CalendarView hosts it).
    var onDeleteRequest: (String, @escaping () -> Void) -> Void = { _, _ in }

    /// The per-frame TimelineView re-creates this view every frame; the closures make SwiftUI
    /// assume it changed, so WITHOUT this the whole panel body (sections, dictionaries, gantt
    /// sorts) re-evaluated at 120Hz — the "severe lag". Equality = identity + data stamp; state
    /// the body READS from @Observable models (nav ring, settings) invalidates through
    /// observation-tracking regardless, and @State (hover, expansion, frozen structure) is
    /// internal. Use with .equatable() at the mount.
    static func == (a: NativePanelHost, b: NativePanelHost) -> Bool {
        a.scope == b.scope && a.key == b.key && a.tab == b.tab
            && a.dataStamp == b.dataStamp && a.noteMode == b.noteMode
            && a.warmAllTabs == b.warmAllTabs // late warms must reach onChange
    }

    /// Warm the inactive tabs too (parked/pre-built panels only): mounting happens at rest,
    /// staggered one tab per runloop turn, so the first ⌘E/⌘J flip finds its body built.
    var warmAllTabs: Bool = false
    /// Parked and NOT the warm target → trim to the active tab. Every mounted NOTE tab keeps
    /// an NSTextView+NSScrollView+ruler alive, and AppKit's per-commit Auto Layout scan
    /// (_findAnySubviewNeedingAutoLayoutEngine — caught red-handed at 129ms by the watchdog)
    /// walks EVERY hosted view in the window on EVERY display commit.
    var trimToActiveTab: Bool = false

    /// Tabs that have EVER been shown (or warmed) stay mounted — a flip back is an opacity
    /// swap instead of re-paying the whole mount (the "first ⌘J, again on every return"
    /// hitch). Mid-gesture LIVE mounts (day paging, page-turn arrivals) still build only the
    /// active tab, so gestures never pay for three.
    @State private var mountedTabs: Set<DashTab> = []
    @State private var trimWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            if tab == .todo || mountedTabs.contains(.todo) {
                NativeDashPanel(engine: engine, scope: scope, key: key, theme: theme,
                                settings: settings, nav: nav, onOpen: onOpen, onJump: onJump,
                                onDeleteRequest: onDeleteRequest)
                    .opacity(tab == .todo ? 1 : 0)
                    .allowsHitTesting(tab == .todo)
            }
            if tab == .proj || mountedTabs.contains(.proj) {
                NativeProjPanel(engine: engine, scope: scope, key: key, theme: theme,
                                onOpen: onOpen, onJump: onJump, onDeleteRequest: onDeleteRequest)
                    .opacity(tab == .proj ? 1 : 0)
                    .allowsHitTesting(tab == .proj)
            }
            if tab == .note || mountedTabs.contains(.note) {
                NativeNotePanel(engine: engine, scope: scope, key: key, theme: theme,
                                dataStamp: dataStamp, active: tab == .note,
                                noteMode: $noteMode, nav: nav)
                    .opacity(tab == .note ? 1 : 0)
                    .allowsHitTesting(tab == .note)
            }
        }
        .onChange(of: tab) { old, new in
            mountedTabs.insert(old) // the tab you left stays alive
            mountedTabs.insert(new)
        }
        .onChange(of: trimToActiveTab, initial: true) { _, trim in
            // Hosted-view diet, DEFERRED: trimming at park time tore down thousands of
            // Text/CoreText objects on the toggle's tail (the trace's TLine/TRun destructor
            // stall). Trim 4s later — teardown lands at idle — unless the panel went live
            // (or became the warm target) again first.
            trimWork?.cancel()
            guard trim else { return }
            let w = DispatchWorkItem { mountedTabs = [] }
            trimWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
        }
        // onChange(initial:) — NOT onAppear: warmAllTabs can flip true AFTER the host is
        // mounted (a panel parked by live use gets warmed at the next retracted rest), and
        // the settled-dwell warm arrives mid-session too.
        .onChange(of: warmAllTabs, initial: true) { _, warm in
            guard warm else { return }
            DispatchQueue.main.async {
                mountedTabs.insert(.todo)
                DispatchQueue.main.async {
                    mountedTabs.insert(.proj)
                    DispatchQueue.main.async { mountedTabs.insert(.note) }
                }
            }
        }
    }
}
