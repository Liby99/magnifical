// Notification PLANNING — the pure half of the notification system. Given the calendar data,
// the user's notification preferences, and "now", compute the exact set of notifications that
// should be pending with the OS for the next two weeks. No UserNotifications import here: the
// planner is deterministic and unit-testable; NotificationScheduler owns the OS reconcile.
//
// Semantics (Settings ▸ Notifications):
//   • Per kind (timed / band / deadline / todo): an enable toggle + a set of delivery offsets.
//   • Day-granular offsets ("morning of", "day before") fire at the configurable morning hour.
//   • Tag overrides: an item tagged `silent` never notifies; `notify` opts an item in even when
//     its kind is globally off. Todos use inline `#notify`/`#silent`; items use drawer tags.
//   • Todos anchor to their resolved `due:`; an event-note todo inherits the event's next
//     occurrence date; a dateless todo stays silent. Date-only dues anchor at the morning hour.

import CalendarGeometry
import CoreGraphics
import Foundation

public enum NotifyKind: String, CaseIterable, Sendable {
    case timed, band, deadline, todo
}

/// A delivery offset relative to the item's moment. Raw values are persisted in UserDefaults
/// (comma-joined per kind) — never change them.
public enum NotifyOffset: String, CaseIterable, Sendable {
    case atTime // at the start / due moment
    case m15 // 15 minutes before
    case h1 // 1 hour before
    case dayOf // the morning of the day it happens (morning hour)
    case dayBefore // the morning of the previous day (morning hour)
}

/// The Settings ▸ Notifications state, loaded from UserDefaults with the product defaults.
public struct NotifyPrefs: Sendable, Equatable {
    public var enabled: Bool // master switch (off until the user opts in + authorizes)
    public var morningHour: Int // fire hour for day-granular offsets (default 9 = 9:00 AM)
    public var kindEnabled: [NotifyKind: Bool]
    public var offsets: [NotifyKind: Set<NotifyOffset>]

    public static let defaultKindEnabled: [NotifyKind: Bool] = [
        .timed: true, .band: true, .deadline: true, .todo: false,
    ]
    public static let defaultOffsets: [NotifyKind: Set<NotifyOffset>] = [
        .timed: [.m15],
        .band: [.dayBefore, .dayOf],
        .deadline: [.dayBefore, .h1, .m15],
        .todo: [.m15],
    ]

    public static func load(_ d: UserDefaults = .standard) -> NotifyPrefs {
        var kindEnabled: [NotifyKind: Bool] = [:]
        var offsets: [NotifyKind: Set<NotifyOffset>] = [:]
        for k in NotifyKind.allCases {
            let ek = PrefKeys.notifyKindEnabled(k.rawValue)
            kindEnabled[k] = d.object(forKey: ek) == nil ? defaultKindEnabled[k]! : d.bool(forKey: ek)
            if let s = d.string(forKey: PrefKeys.notifyKindOffsets(k.rawValue)) {
                offsets[k] = Set(s.split(separator: ",").compactMap { NotifyOffset(rawValue: String($0)) })
            } else {
                offsets[k] = defaultOffsets[k]!
            }
        }
        let mh = d.object(forKey: PrefKeys.notifyMorningHour) == nil ? 9 : d.integer(forKey: PrefKeys.notifyMorningHour)
        return NotifyPrefs(enabled: d.bool(forKey: PrefKeys.notifyEnabled),
                           morningHour: min(23, max(0, mh)), kindEnabled: kindEnabled, offsets: offsets)
    }
}

/// One notification the OS should have pending. The id encodes the fire minute, so an item
/// moving in time yields a DIFFERENT id — the old request reconciles away as stale and the new
/// one is added, with no separate change-detection needed.
public struct PlannedNotification: Sendable, Equatable {
    public var id: String
    public var fireDate: Date
    public var title: String
    public var body: String
    public var itemId: String // box id for click-through revealAndSelect; "" = just open the app
}

public enum NotifyPlanner {
    public static let windowDays = 14 // rolling scheduling window
    public static let maxPending = 60 // safety cap (iOS keeps 64; macOS is lenient but bounded is bounded)
    static let idPrefix = "cc.ntf|" // marks OUR requests among the app's pending set

    /// The full desired set: every notification that should fire in (now, now + windowDays].
    static func plan(items: CalendarItems, mainTz: String, prefs: NotifyPrefs, now: Date) -> [PlannedNotification] {
        guard prefs.enabled else { return [] }
        let ctx = Ctx(prefs: prefs, mainZone: zone(mainTz), now: now,
                      windowEnd: now.addingTimeInterval(Double(windowDays) * 86400))
        var out: [PlannedNotification] = []

        for e in items.events {
            let rf = items.richById[e.id]
            guard include(.timed, tags: rf?.tags ?? [], rf: rf, prefs: prefs) else { continue }
            let tz = zone(e.anchorTz ?? mainTz)
            for occ in occurrences(YMD(e.year, e.month, e.day), rf, ctx) {
                emit(&out, .timed, boxId: boxId(e.id, base: YMD(e.year, e.month, e.day), occ: occ),
                     title: e.title, day: occ, hour: e.startHour, tz: tz, ctx: ctx)
            }
        }
        for b in items.bands {
            let rf = items.richById[b.id]
            guard include(.band, tags: rf?.tags ?? [], rf: rf, prefs: prefs) else { continue }
            for occ in occurrences(YMD(b.year, b.month, b.startDay), rf, ctx) {
                emit(&out, .band, boxId: boxId(b.id, base: YMD(b.year, b.month, b.startDay), occ: occ),
                     title: b.title, day: occ, hour: nil, tz: ctx.mainZone, ctx: ctx)
            }
        }
        for d in items.deadlines {
            let rf = items.richById[d.id]
            guard include(.deadline, tags: rf?.tags ?? [], rf: rf, prefs: prefs) else { continue }
            let tz = zone(d.anchorTz ?? mainTz)
            for occ in occurrences(YMD(d.year, d.month, d.day), rf, ctx) {
                emit(&out, .deadline, boxId: boxId(d.id, base: YMD(d.year, d.month, d.day), occ: occ),
                     title: d.title, day: occ, hour: d.hour, tz: tz, ctx: ctx)
            }
        }
        planTodos(&out, items: items, mainTz: mainTz, ctx: ctx)

        // Soonest-first, capped, deduped (a recurring item's dayBefore can collide with dayOf math).
        var seen = Set<String>()
        return Array(out.sorted { $0.fireDate < $1.fireDate }
            .filter { seen.insert($0.id).inserted }
            .prefix(maxPending))
    }

    /// ── Todos: daily notes + item notes + per-occurrence notes ──────────────────────────────
    private static func planTodos(_ out: inout [PlannedNotification], items: CalendarItems,
                                  mainTz: String, ctx: Ctx) {
        let today = ctx.today
        // Daily notes: no inherited date — only an explicit/relative `due:` anchors (dateless = silent).
        for (dateStr, note) in items.dailyNotes {
            for t in TodoScan.scan(note, today: today) {
                emitTodo(&out, t, source: "daily-\(dateStr)", inherited: nil, itemId: "", ctx: ctx)
            }
        }
        // Item notes inherit the item's NEXT upcoming occurrence date; per-occurrence notes inherit
        // the occurrence date baked into their box-id key ("id@Y-M-D").
        for (id, rf) in items.richById where userItemIds(items).contains(id) {
            let base = itemBaseDay(items, id)
            if let note = rf.notes, let base {
                let inherited = nextOccurrence(base, rf, ctx)
                for t in TodoScan.scan(note, today: today) {
                    emitTodo(&out, t, source: id, inherited: inherited, itemId: id, ctx: ctx)
                }
            }
            for (boxId, note) in rf.occurrenceNotes ?? [:] {
                let occ = occFromKey(boxId)
                for t in TodoScan.scan(note, today: today) {
                    emitTodo(&out, t, source: boxId, inherited: occ, itemId: boxId, ctx: ctx)
                }
            }
        }
    }

    private static func emitTodo(_ out: inout [PlannedNotification], _ t: ScannedTodo,
                                 source: String, inherited: YMD?, itemId: String, ctx: Ctx) {
        guard !t.done, !t.tags.contains("silent"),
              (ctx.prefs.kindEnabled[.todo] ?? false) || t.tags.contains("notify"),
              let day = t.due ?? inherited, !t.title.isEmpty else { return }
        let tz = t.tz.map { zone($0) } ?? ctx.mainZone
        // Source key + content hash: the same line in two notes stays two distinct notifications.
        emit(&out, .todo, boxId: "todo-\(TodoScan.fnv1a(source))-\(t.lineKey)", title: t.title,
             day: day, hour: t.dueHour, tz: tz, ctx: ctx, todoItemId: itemId)
    }

    /// ── Shared emit: one occurrence × the kind's offsets ────────────────────────────────────
    private static func emit(_ out: inout [PlannedNotification], _ kind: NotifyKind, boxId: String,
                             title: String, day: YMD, hour: CGFloat?, tz: TimeZone, ctx: Ctx,
                             todoItemId: String? = nil) {
        let moment = hour.flatMap { instant(day, $0, tz) } // nil for day-granular items (bands, date-only todos)
        for off in ctx.prefs.offsets[kind] ?? [] {
            let fire: Date? = switch off {
            case .atTime: moment ?? morning(day, 0, ctx)
            case .m15: (moment ?? morning(day, 0, ctx))?.addingTimeInterval(-15 * 60)
            case .h1: (moment ?? morning(day, 0, ctx))?.addingTimeInterval(-3600)
            case .dayOf: morning(day, 0, ctx)
            case .dayBefore: morning(day, -1, ctx)
            }
            guard let fire, fire > ctx.now, fire <= ctx.windowEnd else { continue }
            // The title rides in the id (hashed): a rename must mint a new id, or the reconcile
            // would keep the pending request — and thus the banner text — from before the rename.
            out.append(PlannedNotification(
                id: "\(idPrefix)\(kind.rawValue)|\(boxId)|\(off.rawValue)|\(Int(fire.timeIntervalSince1970 / 60))|\(TodoScan.fnv1a(title))",
                fireDate: fire,
                title: title.isEmpty ? "(untitled)" : title,
                body: body(kind, off, moment: moment, ctx: ctx),
                itemId: todoItemId ?? boxId
            ))
        }
    }

    /// Banner body: what + when, in the main timezone's clock.
    private static func body(_ kind: NotifyKind, _ off: NotifyOffset, moment: Date?, ctx: Ctx) -> String {
        let verb = switch kind {
        case .timed: "Starts"
        case .band: "Starts"
        case .deadline: "Due"
        case .todo: "Due"
        }
        let clock = moment.map { " at \(ctx.timeFmt.string(from: $0))" } ?? ""
        switch off {
        case .dayBefore: return "\(verb) tomorrow\(clock)"
        case .dayOf: return "\(verb) today\(clock)"
        case .atTime: return moment == nil ? "\(verb) today" : "\(verb) now"
        case .m15: return "\(verb) in 15 minutes"
        case .h1: return "\(verb) in 1 hour"
        }
    }

    // ── Occurrence + date helpers ───────────────────────────────────────────────────────────

    /// Base date (unless hidden) + expanded recurrence, over every year the window touches.
    private static func occurrences(_ base: YMD, _ rf: RichFields?, _ ctx: Ctx) -> [YMD] {
        let rep = Repeat.parse(rf?.repeatJSON)
        var occs: [YMD] = baseHidden(occDate(base), rep) ? [] : [base]
        for y in ctx.years {
            occs += occurrenceDates(base, rep, y)
        }
        return occs
    }

    private static func nextOccurrence(_ base: YMD, _ rf: RichFields?, _ ctx: Ctx) -> YMD? {
        occurrences(base, rf, ctx)
            .filter { occDate($0) >= occDate(ctx.today) }
            .min { occDate($0) < occDate($1) }
    }

    /// Ghost occurrences carry the `id@Y-M-D` box id (what revealAndSelect expects); the base
    /// occurrence is the plain id.
    private static func boxId(_ id: String, base: YMD, occ: YMD) -> String {
        occ == base ? id : occKey(id, occ)
    }

    private static func occFromKey(_ boxId: String) -> YMD? {
        guard let m = boxId.range(of: #"@(\d+)-(\d+)-(\d+)"#, options: .regularExpression) else { return nil }
        let p = boxId[m].dropFirst().split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return YMD(p[0], p[1], p[2]) // occKey months are already 0-based
    }

    private static func userItemIds(_ items: CalendarItems) -> Set<String> {
        Set(items.events.map(\.id) + items.bands.map(\.id) + items.deadlines.map(\.id))
    }

    private static func itemBaseDay(_ items: CalendarItems, _ id: String) -> YMD? {
        if let e = items.events.first(where: { $0.id == id }) {
            return YMD(e.year, e.month, e.day)
        }
        if let b = items.bands.first(where: { $0.id == id }) {
            return YMD(b.year, b.month, b.startDay)
        }
        if let d = items.deadlines.first(where: { $0.id == id }) {
            return YMD(d.year, d.month, d.day)
        }
        return nil
    }

    /// silent kills; notify resurrects a globally-off kind; imported-hidden never notifies.
    private static func include(_ kind: NotifyKind, tags: [String], rf: RichFields?, prefs: NotifyPrefs) -> Bool {
        let t = Set(tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        if t.contains("silent") || rf?.hidden == true || rf?.userHidden == true {
            return false
        }
        return (prefs.kindEnabled[kind] ?? false) || t.contains("notify")
    }

    /// A wall-clock (day + fractional hour) in `tz` as the true absolute instant. DateComponents
    /// normalizes hour ≥ 24 (a cross-midnight end) into the next day.
    static func instant(_ day: YMD, _ hour: CGFloat, _ tz: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let h = Int(hour), mi = Int(((hour - CGFloat(h)) * 60).rounded())
        return cal.date(from: DateComponents(year: day.year, month: day.month + 1, day: day.day,
                                             hour: h, minute: mi))
    }

    /// The morning-hour instant of `day + dayDelta`, in the MAIN zone (morning pings are "your
    /// morning" regardless of the item's anchor zone).
    private static func morning(_ day: YMD, _ dayDelta: Int, _ ctx: Ctx) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ctx.mainZone
        guard let base = cal.date(from: DateComponents(year: day.year, month: day.month + 1, day: day.day,
                                                       hour: ctx.prefs.morningHour)) else { return nil }
        return dayDelta == 0 ? base : cal.date(byAdding: .day, value: dayDelta, to: base)
    }

    private static func zone(_ tz: String) -> TimeZone {
        TimeZone(identifier: DeadlineTZ.iana(tz)) ?? .current
    }

    /// Per-plan context: prefs + window bounds + derived calendar bits, computed once.
    private struct Ctx {
        let prefs: NotifyPrefs
        let mainZone: TimeZone
        let now: Date
        let windowEnd: Date
        var years: [Int] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = mainZone
            let a = cal.component(.year, from: now), b = cal.component(.year, from: windowEnd)
            return a == b ? [a] : [a, b]
        }

        var today: YMD {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = mainZone
            let c = cal.dateComponents([.year, .month, .day], from: now)
            return YMD(c.year ?? 0, (c.month ?? 1) - 1, c.day ?? 1)
        }

        var timeFmt: DateFormatter {
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            f.timeZone = mainZone
            return f
        }
    }
}
