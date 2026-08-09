// The iPhone app shell — a READ-ONLY viewer over the same CloudKit data as the Mac app.
//
// The engine is constructed with cloudReadOnly: true, so CKSyncEngine fetches and applies
// remote changes but is hard-blocked from ever sending (see CloudSync/RegistrySync.readOnly).
// The UI (PhoneCalendarView) renders the Mac's scene via the shared CalendarRender target
// and never mutates. SyncHarnessView (the original sync test harness) is kept in the target
// for debugging but is no longer the root.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI
import UIKit

@main
struct CalendarPhoneApp: App {
    /// One engine + one bench runner for the process. Constructed in init() BODY (not property
    /// defaults) because bench-payload staging must land on disk before the engine loads the
    /// store — property defaults run before the init body ever gets a chance.
    @State private var engine: CalendarEngine
    @State private var bench: PhoneBenchRunner

    init() {
        // Phone-fit layout, write-once before the first render (see Layout.labelW/padLeft):
        // gutter collapses to just the rotated month name (no track-name column — the
        // desktop's 250pt gutter would eat most of a portrait screen), flush to the left
        // edge, so the day grid gets the full remaining width (padRight is already 0).
        // 44pt (vs the desktop name zone's 28) so the month timeline's in-gutter hour
        // labels ("9AM") fit; mnameW matches it, which is what flags compact-gutter mode.
        Layout.labelW = 44
        Layout.mnameW = 44
        Layout.padLeft = 0
        // Legible year cells: well above the ~12pt a 31-day month gets on a portrait screen.
        // Each quarter overflows into its own horizontal scroll (see PhoneYearDriver).
        Layout.yearMinDayW = 45
        // Week view shows a 3-day window (7 columns are unreadably narrow in portrait); the
        // window scrolls day-aligned across the month's full week grid (see PhoneWeekDriver).
        Layout.weekDaysVisible = 3
        // Top insets (yearTop/topPad) are finalized in PhoneCalendarRoot once the device's
        // status-bar inset is measured — the canvas runs full-bleed under the Dynamic Island
        // and the content starts just below it. These are pre-measure fallbacks only.
        Layout.yearTop = 0
        Layout.topPad = 32
        // The floating glass toolbar's footprint measured from the physical bottom edge
        // (34 home-indicator + 4 inset + 44 capsule). The month/week timeline bottoms out
        // above this; tune here as the toolbar evolves.
        Layout.bottomBarH = 82
        // …and the last quarter must scroll clear of the floating glass toolbar. The canvas
        // is full-bleed (ignores the bottom safe area), so measured from the PHYSICAL bottom:
        // ~34 home-indicator inset + 4 toolbar inset + 44 capsule + breathing room.
        Layout.bottomPad = 104
        // Larger event titles: only a screenful of cells is visible at a time on the phone.
        BandStyle.titleSize = 15

        // Bench mode (CC_DEMO=bench-*, set in the MagnifiCalPhoneBench scheme): stage the payload
        // into the throwaway Documents/bench-store dir BEFORE the engine loads — the ItemStore
        // base-dir redirect (calendarKitBaseDir) points every demo-mode read there, so a bench
        // run never touches the real store, and isDemoMode also disables sync/import/notify.
        if CalendarEngine.isDemoMode {
            Self.stageBenchPayload()
        }

        // Constructing the engine kicks off CloudKit sync (see enableCloudSyncIfEntitled →
        // CloudSync.startIfAccountAvailable). Cross-year flips are off on the phone for now:
        // the month pager rubber-bands at Jan/Dec instead of flipping into the neighbor year
        // (the year view's own flip is disabled in PhoneYearDriver by never arming its
        // overscroll gesture).
        let e = CalendarEngine(cloudReadOnly: true)
        e.monthYearFlipEnabled = false
        e.weekMonthFlipEnabled = false // week window rubber-bands at month edges, no silent month change
        e.dayMonthFlipEnabled = false // day paging rubber-bands at day 1 / last day, same policy
        e.maxZ = 3 // pinch zoom reaches every level — all four touch drivers are mounted
        e.hasDailyDashboard = false // no dashboard webview → day view is a full-width day column
        _engine = State(initialValue: e)

        // The bench runner is inert outside CC_DEMO/CC_FPS_HUD runs (benchTick is a cheap
        // no-op). Frame budget from the real display, so the HUD tints and frames_over_budget
        // are display-rate-aware (60 Hz non-Pro vs 120 Hz ProMotion).
        let b = PhoneBenchRunner()
        b.budgetMs = 1000.0 / Double(max(30, UIScreen.main.maximumFramesPerSecond))
        _bench = State(initialValue: b)
    }

    /// Resolve CC_BENCH_PAYLOAD and stage it as the demo store's data.json.
    ///   display|dense|todos|empty  — fixtures bundled from CalendarKit/bench/ (project.yml)
    ///   documents:<name>           — <Documents>/bench-payloads/<name>.json, dropped in via the
    ///                                Files app (how the real-store CC_DUMP_DISPLAY dump gets here)
    private static func stageBenchPayload() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let spec = ProcessInfo.processInfo.environment["CC_BENCH_PAYLOAD"] ?? "display"
        var fixture: URL?
        if spec.hasPrefix("documents:") {
            fixture = docs.appendingPathComponent("bench-payloads/\(spec.dropFirst("documents:".count)).json")
        } else {
            let bundled = ["display": "year-display-2026", "dense": "year-dense-2026",
                           "todos": "todo-dense-2026", "empty": "empty"]
            fixture = bundled[spec].flatMap { Bundle.main.url(forResource: $0, withExtension: "json") }
        }
        guard let fixture, FileManager.default.fileExists(atPath: fixture.path) else {
            print("PhoneBench: payload '\(spec)' not found — the store will start empty")
            return
        }
        do {
            try BenchStaging.stage(fixture: fixture,
                                   into: docs.appendingPathComponent("bench-store", isDirectory: true))
        } catch {
            print("PhoneBench: staging failed: \(error)")
        }
    }

    /// Extra breathing room between the bottom of the status bar / Dynamic Island and the
    /// first content (year: day-number header; month: date row). Tune to taste.
    private static let topBreathingRoom: CGFloat = 52

    /// Measures the device's top safe-area inset (Dynamic Island / status bar) BEFORE the
    /// calendar mounts, then finalizes the top layout knobs: the canvas itself runs
    /// full-bleed under the status bar (no solid strip up there — the grid shows through),
    /// and the content top insets (yearTop/topPad) clear the island by exactly its height.
    /// Mounting after measurement preserves the knobs' write-once-before-first-render rule.
    private struct PhoneCalendarRoot: View {
        let engine: CalendarEngine
        let bench: PhoneBenchRunner
        @State private var measured = false

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    if measured {
                        PhoneCalendarView(engine: engine, bench: bench)
                    }
                }
                .onAppear {
                    let contentTop = geo.safeAreaInsets.top + CalendarPhoneApp.topBreathingRoom
                    Layout.yearTop = contentTop // year: day-number header
                    Layout.topPad = contentTop + 30 // month: 1–31 date row sits 20pt above the band
                    measured = true
                }
            }
            .ignoresSafeArea(.container, edges: .top) // reintroduces the inset on the proxy
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some SwiftUI.Scene { // CalendarGeometry also has a `Scene` (the render item list)
        WindowGroup {
            PhoneCalendarRoot(engine: engine, bench: bench)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                engine.syncNow() // fetch-only under cloudReadOnly
            }
        }
    }
}
