// Apple Calendar import via EventKit. The native app is a real macOS app, so it talks to EKEventStore
// directly (no eventkit-bridge subprocess like the web server needs). This is a thin, stateless wrapper:
// request access, enumerate calendars, and fetch events for a window (recurring occurrences already
// expanded by EventKit). Mapping into TimedEvent/BandEvent + provenance lives in CalendarEngine.

import CoreGraphics
import EventKit
import Foundation

public extension Notification.Name {
    /// Posted by the (isolated) Settings window when the Apple Calendar connection changes, so the
    /// running engine re-imports immediately instead of waiting for the next launch/foreground.
    static let appleCalendarSettingsChanged = Notification.Name("cc.appleCal.settingsChanged")
    /// Posted when a View-menu preference (e.g. "Show Hidden Imported Events", stored in UserDefaults)
    /// changes, so the running engine invalidates its display cache and repaints.
    static let calendarViewPrefsChanged = Notification.Name("cc.view.prefsChanged")
    /// Posted by the Help → Keyboard Shortcuts menu command to reveal the ⌘K shortcut-guide overlay
    /// (a latched show; the calendar window observes it — see CalendarView).
    static let showKeyboardShortcuts = Notification.Name("cc.help.showKeyboardShortcuts")
    /// Posted by Help → Tutorial to (re)open the onboarding GIF carousel (see CalendarView).
    static let showTutorial = Notification.Name("cc.help.showTutorial")
    /// File ▸ Print… (⌘P) — CalendarView routes it: year view prints, other levels show a notice.
    static let requestPrint = Notification.Name("cc.print.request")
    /// View ▸ Filter by Tags — toggles the tag-filter popover (anchored to its toolbar button in
    /// CalendarView). Posted by the menu item in both shells (a menu can't host a stay-open checklist).
    static let toggleTagFilter = Notification.Name("cc.view.toggleTagFilter")
    /// View ▸ TODO List (⌘B) / Note Editor (⌘E) / Projects (⌘J) — focus the dashboard's
    /// TODO/NOTE/PROJ tab. The open/flip/retract state machine lives in CalendarView (which
    /// owns the tab state).
    static let focusDashTodo = Notification.Name("cc.view.focusDashTodo")
    static let focusDashNote = Notification.Name("cc.view.focusDashNote")
    static let focusDashProj = Notification.Name("cc.view.focusDashProj")
    /// File ▸ multiple-calendars menu items → CalendarView presents the corresponding dialog (name
    /// prompt / remove confirm). Posted by the menu in both shells.
    static let newCalendar = Notification.Name("cc.cal.new")
    static let removeCalendar = Notification.Name("cc.cal.remove")
    static let renameCalendar = Notification.Name("cc.cal.rename")
}

/// One selectable Apple calendar (an `EKCalendar`) — for the Settings picker.
public struct AppleCalendarInfo: Identifiable, Sendable, Hashable {
    public let id: String // EKCalendar.calendarIdentifier (stable per calendar)
    public let title: String
    public let source: String // EKSource.title — "iCloud", "Google", the account name
    public let colorHex: String
    public init(id: String, title: String, source: String, colorHex: String) {
        self.id = id; self.title = title; self.source = source; self.colorHex = colorHex
    }
}

public struct AppleAttendee: Sendable { public let name: String; public let status: String }

/// A raw event fetched from EventKit. Recurring events arrive already expanded to one entry per
/// occurrence within the window, so there's no RRULE to interpret here.
public struct FetchedAppleEvent: Sendable {
    public let uid: String // calendarItemExternalIdentifier — stable across a series' occurrences
    public let eventId: String? // EKEvent.eventIdentifier — for the `ical://ekevent/…` deep-link back to Calendar.app
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let calendarId: String
    public let colorHex: String
    public let notes: String?
    public let location: String?
    public let url: String?
    public let organizer: String? // display name or email
    public let attendees: [AppleAttendee]
    public let sourceTitle: String // EKSource.title — "iCloud", "Google", the account name
    public let calendarTitle: String
}

@MainActor
public final class AppleCalendarImporter {
    private let store = EKEventStore()
    public init() {}

    public enum Access { case authorized, denied, notDetermined }
    public static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: .authorized
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    public static var isAuthorized: Bool {
        access == .authorized
    }

    /// Trigger the one-time TCC prompt (or return the existing grant). macOS 14+ full read access.
    public func requestAccess() async -> Bool {
        if Self.isAuthorized {
            return true
        }
        return await withCheckedContinuation { cont in
            store.requestFullAccessToEvents { ok, _ in cont.resume(returning: ok) }
        }
    }

    /// Every calendar the user has, for the Settings toggle list. Ask the STORE directly (not the static
    /// `authorizationStatus`, which lags for a beat right after a fresh grant) — it returns [] if the app
    /// truly lacks access, and the real list once granted, even before the status catches up.
    public func calendars() -> [AppleCalendarInfo] {
        store.calendars(for: .event).map {
            AppleCalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                              source: $0.source.title, colorHex: Self.hex($0.cgColor))
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Events in `[from, to)` for the SELECTED calendars. An empty selection imports NOTHING (the user
    /// unchecked everything) — not "all". Occurrences pre-expanded.
    public func fetch(from: Date, to: Date, calendarIds: [String]) -> [FetchedAppleEvent] {
        guard !calendarIds.isEmpty else { return [] }
        // A long-lived EKEventStore can serve a stale snapshot for events other apps (Calendar.app) added
        // since it was created — so a manual "Sync Now" would miss them. reset() drops that cache and forces
        // this fetch to read the current store; the access grant survives it.
        store.reset()
        let sel = store.calendars(for: .event).filter { calendarIds.contains($0.calendarIdentifier) }
        guard !sel.isEmpty else { return [] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: sel)
        return store.events(matching: pred).map { e in
            FetchedAppleEvent(
                uid: e.calendarItemExternalIdentifier ?? e.calendarItemIdentifier,
                eventId: e.eventIdentifier,
                title: e.title ?? "(untitled)",
                start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                calendarId: e.calendar.calendarIdentifier,
                colorHex: Self.hex(e.calendar.cgColor),
                notes: e.notes, location: e.location, url: e.url?.absoluteString,
                organizer: Self.participant(e.organizer),
                attendees: (e.attendees ?? []).map { AppleAttendee(
                    name: Self.participant($0) ?? "",
                    status: Self.statusString($0.participantStatus)
                ) },
                sourceTitle: e.calendar.source.title, calendarTitle: e.calendar.title
            )
        }
    }

    /// Display label for a participant: name, else the mailto-stripped email.
    static func participant(_ p: EKParticipant?) -> String? {
        guard let p else { return nil }
        if let name = p.name, !name.isEmpty {
            return name
        }
        let email = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return email.isEmpty ? nil : email
    }

    static func statusString(_ s: EKParticipantStatus) -> String {
        switch s {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "needs-action"
        default: "unknown"
        }
    }

    static func hex(_ cg: CGColor?) -> String {
        guard let c = cg?.components, c.count >= 3 else { return "" }
        return String(format: "#%02X%02X%02X",
                      Int((c[0] * 255).rounded()), Int((c[1] * 255).rounded()), Int((c[2] * 255).rounded()))
    }
}
