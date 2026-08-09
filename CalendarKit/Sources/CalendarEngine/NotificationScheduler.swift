// The OS half of the notification system: reconciles NotifyPlanner's desired set with the
// system's pending-request list via UNUserNotificationCenter, owns authorization, and handles
// delivery (banner-while-frontmost + click-through navigation).
//
// Design: STATELESS sync. The pending-request list IS the state — every resync recomputes the
// desired set and diffs by identifier (the id encodes kind|box|offset|fire-minute, so any change
// of time produces a new id and the stale one is removed). Resyncs are debounced and triggered
// from the persist chokepoints, remote merges, prefs changes, day rollover, and wake-from-sleep.
// The OS fires scheduled requests even when the app has quit; the window just won't roll forward
// until the next launch.

import Foundation
import os
import UserNotifications
#if canImport(AppKit)
    import AppKit
#endif

public extension Notification.Name {
    /// Posted by Settings ▸ Notifications on any pref change → the scheduler resyncs.
    static let notifyPrefsChanged = Notification.Name("cc.notify.prefsChanged")
}

/// Scheduling visibility (Console.app, or: log stream --predicate 'subsystem == "dev.magnifical.calendar"
/// AND category == "notify"'). Failures here are otherwise perfectly silent — the OS just never rings.
let notifyLog = Logger(subsystem: "dev.magnifical.calendar", category: "notify")

/// Authorization state as the Settings UI needs it — mirrors UNAuthorizationStatus without
/// making CalendarUI import UserNotifications.
public enum NotifyAuthStatus: Sendable {
    case unsupported // not running from a .app bundle (tests / bare swift run)
    case notDetermined, denied, authorized
}

@MainActor
public final class NotificationScheduler: NSObject {
    public static let shared = NotificationScheduler()
    private weak var engine: CalendarEngine?
    private var resyncWork: DispatchWorkItem?
    private var started = false

    /// UNUserNotificationCenter aborts outright in a process without a bundle identity (bare SPM
    /// binaries, swift test) — every entry point guards on this.
    public static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Wire up once at engine creation: delegate + the non-data resync triggers. Demo recordings
    /// never touch the user's notification schedule (mirrors the CloudSync/Apple-import guards).
    func start(engine: CalendarEngine) {
        // Adopt the engine only when we don't already track a LIVE one. SwiftUI re-constructs view
        // structs freely, and each construction can build a throwaway CalendarEngine (a @State
        // default value) that is immediately discarded — letting it clobber the weak ref here
        // would leave `self.engine` nil and every resync silently dead.
        if self.engine == nil {
            self.engine = engine
        }
        guard Self.isSupported, !CalendarEngine.isDemoMode, !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = self
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestResync() } // roll the 14-day window forward
        }
        nc.addObserver(forName: .notifyPrefsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestResync() }
        }
        #if canImport(AppKit)
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.requestResync() } // sleep can straddle a day boundary
            }
        #endif
        requestResync()
    }

    /// Debounced full resync — cheap to over-call (the persist path already debounces edits 0.5s;
    /// this adds its own 1s so a burst of saves reconciles once).
    public func requestResync() {
        guard Self.isSupported, !CalendarEngine.isDemoMode else { return }
        resyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.resyncNow() }
        }
        resyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // Reentrancy guard: with the plan computed off-main, resyncNow suspends mid-flight — a second
    // entry could otherwise interleave its stale-removal with the first's adds. One runs at a
    // time; a request that lands mid-flight queues exactly one follow-up pass.
    private var resyncInFlight = false
    private var resyncQueued = false

    private func resyncNow() async {
        if resyncInFlight {
            resyncQueued = true
            return
        }
        resyncInFlight = true
        defer {
            resyncInFlight = false
            if resyncQueued {
                resyncQueued = false
                Task { @MainActor in await self.resyncNow() }
            }
        }
        // The tracked engine can still die (window teardown) — fall back to the app's main one.
        let live = engine ?? CalendarEngine.mainInstance
        guard let engine = live else {
            notifyLog.error("resync SKIPPED: no live engine (data source lost)")
            return
        }
        self.engine = engine
        let center = UNUserNotificationCenter.current()
        let prefs = NotifyPrefs.load()
        let status = await center.notificationSettings().authorizationStatus
        notifyLog.notice("resync begin (enabled=\(prefs.enabled), auth=\(status.rawValue))")
        if prefs.enabled, status == .notDetermined {
            // Self-heal: the master toggle is on but the system was never asked — the enable flip
            // can predate the first authorized-capable launch (e.g. it happened in an unsigned dev
            // bundle, where registration fails). Prompt now; the grant re-enters resync.
            notifyLog.notice("enabled but authorization never determined — prompting")
            _ = await requestAuthorization()
            return
        }
        let authorized = status == .authorized || status == .provisional
        let ours = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(NotifyPlanner.idPrefix) }
        guard prefs.enabled, authorized else {
            // Master off / permission revoked → withdraw everything we ever scheduled.
            notifyLog
                .notice("resync idle (enabled=\(prefs.enabled), status=\(status.rawValue)) — withdrew \(ours.count)")
            if !ours.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ours)
            }
            return
        }
        // Plan OFF the main thread: the pure pass walks every event/band/deadline + todo scan —
        // measured 3.4-6.7ms on the real store and 10-20ms on the dense payload, i.e. a dropped
        // frame (or two) landing 1s after every edit while it ran synchronously here on main.
        // CalendarItems is a Sendable value snapshot, so the detached compute sees a consistent
        // copy; only the UNUserNotificationCenter reconcile below stays on the main actor.
        let itemsSnapshot = engine.items
        let mainTz = engine.mainTz
        let now = Date()
        let plan = await Task.detached(priority: .utility) {
            NotifyPlanner.plan(items: itemsSnapshot, mainTz: mainTz, prefs: prefs, now: now)
        }.value
        let desired = Dictionary(plan.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pending = Set(ours)
        let stale = pending.subtracting(desired.keys)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }
        var added = 0
        for (id, p) in desired where !pending.contains(id) {
            let content = UNMutableNotificationContent()
            content.title = p.title
            content.body = p.body
            content.sound = .default
            content.userInfo = ["itemId": p.itemId]
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: p.fireDate
            )
            do {
                try await center.add(UNNotificationRequest(
                    identifier: id, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                ))
                added += 1
                notifyLog
                    .notice(
                        "➕ \(Self.fireFmt.string(from: p.fireDate), privacy: .public)  \(p.title, privacy: .public) — \(p.body, privacy: .public)  [\(id, privacy: .public)]"
                    )
            } catch {
                notifyLog
                    .error("add FAILED for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        for id in stale {
            notifyLog.notice("➖ withdrew \(id, privacy: .public)")
        }
        notifyLog
            .notice(
                "resync: \(desired.count) desired, \(added) newly scheduled, \(stale.count) withdrawn, \(pending.count) were pending"
            )
    }

    /// "MM-dd HH:mm" for log lines — glanceable fire times.
    static let fireFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    /// Dump the OS's ACTUAL pending list (the ground truth of what will ring) to the unified log —
    /// wired to Settings ▸ Developer. Sorted by next fire time.
    public func dumpPending() {
        guard Self.isSupported else {
            notifyLog.notice("dump: unsupported (not running from a .app bundle)")
            return
        }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            let ours = await center.pendingNotificationRequests()
                .filter { $0.identifier.hasPrefix(NotifyPlanner.idPrefix) }
                .map { r in (r, (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture) }
                .sorted { $0.1 < $1.1 }
            notifyLog.notice("―― pending with macOS: \(ours.count) (auth status \(status.rawValue)) ――")
            for (r, fire) in ours {
                notifyLog
                    .notice(
                        "🕰 \(Self.fireFmt.string(from: fire), privacy: .public)  \(r.content.title, privacy: .public) — \(r.content.body, privacy: .public)  [\(r.identifier, privacy: .public)]"
                    )
            }
        }
    }

    // ── Settings UI surface ─────────────────────────────────────────────────────────────────

    /// The system permission prompt (shows at most once, ever) — called when the user flips the
    /// master toggle on. Returns whether notifications are now allowed.
    public func requestAuthorization() async -> Bool {
        guard Self.isSupported else { return false }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            notifyLog.notice("authorization request → granted=\(granted)")
            requestResync()
            return granted
        } catch {
            // The classic cause here is an unsigned bundle (usernoted refuses registration).
            notifyLog.error("authorization request FAILED: \(error.localizedDescription, privacy: .public)")
            requestResync()
            return false
        }
    }

    public func authStatus() async -> NotifyAuthStatus {
        guard Self.isSupported else { return .unsupported }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional: return .authorized
        default: return .denied
        }
    }
}

/// Delivery callbacks arrive on an arbitrary queue → nonisolated, hopping to main for app state.
extension NotificationScheduler: UNUserNotificationCenterDelegate {
    /// Show banners even while MagnifiCal is frontmost (the system default suppresses them).
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Click-through: activate the app and jump the calendar to the item (same path as a search hit).
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let itemId = response.notification.request.content.userInfo["itemId"] as? String
        Task { @MainActor in
            #if canImport(AppKit)
                NSApp.activate(ignoringOtherApps: true)
            #endif
            if let itemId, !itemId.isEmpty, !itemId.hasPrefix("todo-") {
                CalendarEngine.mainInstance?.revealAndSelect(id: itemId)
            }
            completionHandler()
        }
    }
}
