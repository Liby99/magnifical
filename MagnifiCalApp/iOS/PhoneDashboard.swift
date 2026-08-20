// The iPhone dashboard DRAWER — the Mac's TODO / PROJ / NOTE panels for the current scope,
// presented as a bottom sheet over the calendar (deliberately NOT colocated with the canvas:
// the Mac's pinned side panels don't fit a 390pt portrait screen). The panels themselves are
// the SHARED CalendarRender views the Mac mounts — read-only here (NativeDash.readOnly is set
// at launch, so checkbox/row writes no-op); interactability = tab flips, folds, the PROJ
// accordion, and deadline/todo taps that dismiss the drawer and fly the canvas to the item.
//
// Scope follows the zoom level: year/month → the focused month, week → the settled week of the
// carousel, day → the focused day — the same keys the Mac's dashBodyPanels derive.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

struct PhoneDashboardDrawer: View {
    let engine: CalendarEngine
    let theme: Theme
    @Binding var tab: DashTab
    /// Dismiss the drawer, then fly the canvas to an item (deadline rows, event-todo rows).
    var onReveal: (String) -> Void
    /// Dismiss the drawer, then navigate to a note's home scope (daily ISO / "week:…" / "month:…").
    var onJumpNote: (String) -> Void

    /// One nav model + settings for the drawer's lifetime: folds survive tab flips and
    /// scope changes; the layering prefs are the Mac's same UserDefaults-backed store.
    @State private var nav = NativeDashNavModel()
    @State private var settings = DashTodoSettings()

    var body: some View {
        // Re-derive scope/key when the canvas navigates under a medium detent (awake flips)
        // and when a sync lands note edits while the drawer is open; the equatable host below
        // stops those re-derivations from re-rendering panels unless (scope,key,tab,stamp)
        // actually changed — the Mac's 120Hz NativePanelHost fix, carried over.
        let _ = engine.renderClock.awake
        let _ = engine.noteEdits.gen
        let level = engine.chrome.level
        let _ = engine.chrome.dailyDom // day paging re-keys the day scope
        let (scope, key, headline) = Self.scopeKey(engine)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    // The Canvas header's eyebrow + headline (drawPanelChrome's type), as text.
                    Text(scope == "day" ? "DAILY DASHBOARD"
                        : scope == "week" ? "WEEKLY DASHBOARD" : "MONTHLY DASHBOARD")
                        .font(.system(size: 10))
                        .kerning(1.5)
                        .foregroundStyle(theme.textMuted)
                    Text(headline)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(theme.text)
                }
                Spacer()
                PhoneDashTabs(tab: $tab, theme: theme)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)
            PhoneDashHost(engine: engine, scope: scope, key: key, tab: tab, theme: theme,
                          dataStamp: engine.todoDataStamp, settings: settings, nav: nav,
                          onReveal: onReveal, onJumpNote: onJumpNote)
                .equatable()
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // NO background paint: all three tabs sit directly on the sheet's native styled
        // background — the same surface PhoneEventSheet uses, so every drawer/sheet in the
        // app shares one look (an opaque theme.bg here left the sheet chrome mismatched).
        .onChange(of: level) { _, _ in
            // The keyboard-nav registry keys rows by scope|key; keep it pointed at the live panel.
            nav.activePanel = scope + "|" + key
        }
        .onAppear { nav.activePanel = scope + "|" + key }
    }

    /// (scope, key, headline) for the current view — the same derivations the Mac's
    /// dashBodyPanels/drawPanelChrome use. Year level shows the focused month's dashboard.
    static func scopeKey(_ engine: CalendarEngine) -> (String, String, String) {
        let g = engine.snapshotInput()
        switch engine.chrome.level {
        case 3:
            let key = dayKeyIso(g.year, g.focus, engine.chrome.dailyDom)
            return ("day", key, Self.dayHeadline(key))
        case 2:
            // The settled side of the week carousel (mid-turn, whichever is closer).
            let wt = weekDashTurn(g)
            return wt.p >= 0.5 ? ("week", wt.toKey, wt.to) : ("week", wt.fromKey, wt.from)
        default:
            let key = String(format: "%04d-%02d", g.year, g.focus + 1)
            return ("month", key, "\(MONTH_LONG[g.focus]) \(g.year)")
        }
    }

    /// "Aug 19, 2026" from a day key ("2026-08-19").
    static func dayHeadline(_ iso: String) -> String {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1 ... 12).contains(p[1]) else { return iso }
        return "\(MONTH_NAMES[p[1] - 1]) \(p[2]), \(p[0])"
    }
}

/// The TODO / PROJ / NOTE tab row — the Mac DashTabs' uppercase tracked language, sized
/// for touch (28pt hit targets).
private struct PhoneDashTabs: View {
    @Binding var tab: DashTab
    let theme: Theme

    var body: some View {
        HStack(spacing: 2) {
            tabButton("TODO", .todo)
            tabButton("PROJ", .proj)
            tabButton("NOTE", .note)
        }
    }

    private func tabButton(_ label: String, _ t: DashTab) -> some View {
        Button {
            tab = t
        } label: {
            Text(label)
                .font(.system(size: 11, weight: tab == t ? .bold : .regular))
                .kerning(1.2)
                .foregroundStyle(tab == t ? Theme.accent : theme.textMuted)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Capsule().fill(tab == t ? Theme.accent.opacity(0.12) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One drawer body for a (scope, key): mounts the shared panels with the Mac's opacity-swap
/// tab retention, WITHOUT the Mac carousel's park/warm/trim machinery (the drawer is one
/// panel, not a swipe tour). Equatable on (scope, key, tab, dataStamp) — the drawer body's
/// awake-flip re-derivations equate away unless something real changed.
private struct PhoneDashHost: View, Equatable {
    let engine: CalendarEngine
    let scope: String
    let key: String
    let tab: DashTab
    let theme: Theme
    var dataStamp: String
    let settings: DashTodoSettings
    let nav: NativeDashNavModel
    var onReveal: (String) -> Void
    var onJumpNote: (String) -> Void

    static func == (a: PhoneDashHost, b: PhoneDashHost) -> Bool {
        a.scope == b.scope && a.key == b.key && a.tab == b.tab && a.dataStamp == b.dataStamp
    }

    /// Tabs that have EVER been shown stay mounted — a flip back is an opacity swap instead
    /// of re-paying the mount (NativePanelHost's pattern).
    @State private var mountedTabs: Set<DashTab> = []

    var body: some View {
        ZStack {
            if tab == .todo || mountedTabs.contains(.todo) {
                NativeDashPanel(engine: engine, scope: scope, key: key, theme: theme,
                                settings: settings, nav: nav,
                                onOpen: { id, _, _ in onReveal(id) },
                                onJump: { key, _ in onJumpNote(key) },
                                onReveal: onReveal)
                    .opacity(tab == .todo ? 1 : 0)
                    .allowsHitTesting(tab == .todo)
            }
            if tab == .proj || mountedTabs.contains(.proj) {
                NativeProjPanel(engine: engine, scope: scope, key: key, theme: theme,
                                onOpen: { id, _, _ in onReveal(id) },
                                onJump: { key, _ in onJumpNote(key) })
                    .opacity(tab == .proj ? 1 : 0)
                    .allowsHitTesting(tab == .proj)
            }
            if tab == .note || mountedTabs.contains(.note) {
                PhoneNotePanel(engine: engine, scope: scope, key: key, theme: theme)
                    .opacity(tab == .note ? 1 : 0)
                    .allowsHitTesting(tab == .note)
            }
        }
        .onChange(of: tab) { old, new in
            mountedTabs.insert(old)
            mountedTabs.insert(new)
        }
    }
}

/// The NOTE tab, read-only: the scope note rendered by the phone's own markdown view (the
/// event sheet's renderer). Storage keys match NativeNotePanel's exactly — day: the bare ISO;
/// week: "week:<sunday>"; month: "month:<YYYY-MM>".
private struct PhoneNotePanel: View {
    let engine: CalendarEngine
    let scope: String
    let key: String
    let theme: Theme

    var body: some View {
        let storageKey = scope == "day" ? key : scope == "week" ? "week:\(key)" : "month:\(key)"
        let _ = engine.noteEdits.gen // external note writes repaint at rest
        let text = engine.dailyNote(storageKey)
        ScrollView {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(
                    "No \(scope == "day" ? "daily" : scope == "week" ? "weekly" : "monthly") note yet — write one on the Mac and it syncs here."
                )
                .font(.system(size: 12))
                .foregroundStyle(theme.text.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } else {
                // Managed import blocks flattened: their HTML-comment markers would render
                // as paragraphs in a plain markdown pass.
                PhoneMarkdown(text: ManagedNote.flattenManaged(text), accent: Theme.accent,
                              theme: theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollIndicators(.hidden)
    }
}
