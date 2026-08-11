// Grouped engine constants, Layout/Theme-style — tuning values in one place instead of
// scattered instance `let`s on the engine.

import CalendarGeometry
import CoreGraphics
import Foundation

/// Animation timing + gesture-feel constants: every duration, overscroll threshold, and
/// sensitivity the navigation choreography uses. Durations are seconds.
enum Motion {
    /// Render loop: sleep this long after the last activity (covers SwiftUI fades).
    static let idleSleep: TimeInterval = 0.4

    // ── Zoom / pinch ──
    static let zoomDur: TimeInterval = 0.52 // default z-level tween
    static let tlScrollDur: TimeInterval = 0.25 // timeline scroll-to (keyboard nav / editing reveal)
    static let dashPinDur: TimeInterval = 0.3 // ⌘B/⌘E/⌘J dashboard pin slide
    static let weekDashSettleDur: TimeInterval = 0.28 // weekly-dashboard carousel settle
    static let pinchSens: CGFloat = 1.6 // trackpad magnification → z units

    // ── jumpToDay choreography (fly out → travel → fly in) ──
    static let flyOutDur: TimeInterval = 0.58 // zoom out to year before travelling
    static let flyInFarDur: TimeInterval = 1.05 // year → day after a cross-year scroll
    static let flyInMidDur: TimeInterval = 0.9 // year → day, same year
    static let flyInNearDur: TimeInterval = 0.7 // week/day-level hop, then zoom to day
    static let yearGlideDur: TimeInterval = 0.5 // year-view scroll glide before the fly-in
    static let weekGlideDur: TimeInterval = 0.32 // week hop glide (same-month target)
    /// Day-view day↔day glide: base + per-day-of-distance, capped.
    static let dayGlideBase: TimeInterval = 0.2
    static let dayGlidePerDay: TimeInterval = 0.035
    static let dayGlideMax: TimeInterval = 0.7
    // Month-view month↕month glide (jumpToMonth): scales with distance, like the day glide.
    static let monthGlideBase: TimeInterval = 0.35
    static let monthGlidePerPage: TimeInterval = 0.12
    static let monthGlideMax: TimeInterval = 1.1

    // ── Snaps / keyboard glides ──
    static let weekSnapDur: TimeInterval = 0.2 // settle a fractional week position
    static let keyScrollPace: TimeInterval = 0.3 // year-view keyboard scroll: seconds per month band
    static let keyScrollMin: TimeInterval = 0.12 // floor for very short keyboard glides

    // ── Boundary flips (overscroll past an edge) ──
    static let yearFlipDur: TimeInterval = 1.0 // year-flip: scroll out + fade, swap, scroll in
    static let yearFadeSwapDur: TimeInterval = 0.5 // selectYear cross-fade (out → swap → in), no scroll motion
    static let monthFlipDur: TimeInterval = 0.8
    static let weekFlipDur: TimeInterval = 0.5
    static let weekFlipOver: CGFloat = 34 // on-screen overscroll (px) that arms a week flip
    static let weekOverMul: CGFloat = 1.9 // amplify the rubber-band travel past a month edge
    static let dayFlipDur: TimeInterval = 0.42
    static let dayFlipOver: CGFloat = 40 // on-screen overscroll (px) that arms a day flip
    static let dayOverMul: CGFloat = 1.4 // maps rubber-band px → day-page progress (preview)

    /// ── Drawer ──
    static let drawerShiftDur: TimeInterval = 0.28 // canvas slide when the detail drawer opens/closes

    /// ── Gutter hide (narrow window + pinned week/month dashboard) ──
    /// Minimum width the calendar band region (section B) keeps beside the pinned dashboard;
    /// below it, the month-name/track gutter (section A) slides off-screen left.
    static let gutterHideMinW: CGFloat = 800
}

/// View-behavior thresholds that aren't layout (Layout) or timing (Motion).
enum ViewConst {
    /// Deadlines/timed events are hittable once the day-detail timeline is revealed (month-detail
    /// and deeper), not just week/day — so a deadline can be interacted with in the monthly view too.
    /// (The geometry layer owns the value — see Layout.detailZ.)
    static let detailZ: CGFloat = Layout.detailZ
    /// How close (px, either side of the timeline's left border) the cursor must be to reveal
    /// the scale bar.
    static let tlEdgeRevealDist: CGFloat = 80
}

/// UserDefaults keys for the view/import preferences shared between the engine, the Settings
/// window, and the app's menus. The STRING VALUES are persisted user state — never change them.
public enum PrefKeys {
    /// The "View ▸ Show Hidden Imported Events" toggle.
    public static let showHiddenImported = "cc.view.showHiddenImported"
    /// View ▸ Filter by Tags — the [String] of HIDDEN tag keys (trimmed+lowercased; may include the
    /// untagged sentinel). Empty/absent = no filtering. Persisted across launches (unlike the web app).
    public static let hiddenTags = "cc.view.hiddenTags"
    public static let dashPinned = "cc.dashPinned" // pinned weekly/monthly dashboard (⌘B)
    public static let dashWeekFrac = "cc.dashWeekFrac" // pinned panel width at WEEK (fraction of content)
    public static let dashMonthFrac = "cc.dashMonthFrac" // pinned panel width at MONTH
    /// View ▸ Current Timezone — the main tz for deadline origin-time labels. "auto" = device zone.
    public static let mainTz = "cc.view.mainTz"
    /// View ▸ Alternative Timezone — the second hour column on the timeline. "none" = off.
    public static let altTz = "cc.view.altTz"
    /// The timeline scale-bar's per-hour height (week/day views). Persisted across launches.
    public static let weekHourH = "cc.view.weekHourH"
    /// Apple Calendar import (see +AppleImport). Each MagnifiCal calendar subscribes to its OWN external
    /// calendars, so the enabled-state + selected ids are keyed per calendar id via these helpers.
    public static func appleEnabled(_ calendarId: String) -> String {
        "cc.appleCal.enabled.\(calendarId)"
    }

    public static func appleCalendars(_ calendarId: String) -> String {
        "cc.appleCal.ids.\(calendarId)"
    }

    /// The PRE-multi-calendar global Apple keys — read only by the one-time migration into "Main".
    public static let legacyAppleEnabled = "cc.appleCal.enabled"
    public static let legacyAppleCalendars = "cc.appleCal.ids"
    /// Multiple calendars ("documents"): the active calendar id + the per-device recently-opened list.
    /// The calendar LIST itself lives in calendars.json (see CalendarRegistry), not UserDefaults.
    public static let calActiveId = "cc.cal.activeId"
    public static let calRecents = "cc.cal.recents"
    /// The default "Main" calendar's fixed id (see CalendarRegistry.mainId) — public so the
    /// engine-less Settings window can key legacy migrations (e.g. the pre-per-calendar feed list).
    public static let mainCalendarId = "main"
    /// An ICS feed's display name (its X-WR-CALNAME, captured on fetch) — keyed by the feed's
    /// short key, NOT the secret URL (the name isn't a secret; the URL never leaves the Keychain).
    public static func icsFeedName(_ feedKey: String) -> String {
        "cc.icsfeed.name.\(feedKey)"
    }

    /// The feed's DEFAULT event color (a palette key): every imported item without a per-item
    /// override displays in this color, and changing it re-colors those items. Assigned by
    /// cycling the palette when a feed is subscribed (see ICSFeedColors).
    public static func icsFeedColor(_ feedKey: String) -> String {
        "cc.icsfeed.color.\(feedKey)"
    }

    /// The palette-cycling cursor for new-subscription default colors.
    public static let icsFeedColorCursor = "cc.icsfeed.colorCursor"
    /// The active calendar id as seen from UserDefaults — for the separate Settings window, which has no
    /// engine reference. The engine itself uses `registry.activeId` (authoritative); both resolve equal.
    public static var currentCalendarId: String {
        UserDefaults.standard.string(forKey: calActiveId) ?? ""
    }

    /// Settings ▸ Notifications (see NotifyPlan.swift for semantics + defaults). Master switch, the
    /// morning hour for day-granular pings, and per-kind enabled/offsets keyed by NotifyKind.rawValue.
    public static let notifyEnabled = "cc.notify.enabled"
    public static let notifyMorningHour = "cc.notify.morningHour"
    public static func notifyKindEnabled(_ kind: String) -> String {
        "cc.notify.\(kind).enabled"
    }

    public static func notifyKindOffsets(_ kind: String) -> String {
        "cc.notify.\(kind).offsets"
    }
}
