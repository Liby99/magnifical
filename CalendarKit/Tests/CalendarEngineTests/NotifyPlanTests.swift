@testable import CalendarEngine
import CalendarGeometry
import XCTest

/// The notification planner (NotifyPlan.swift) — pure desired-set math — and the todo-line
/// scanner it feeds on. No UNUserNotificationCenter here (unbundled test processes can't touch
/// it); the OS reconcile is exercised manually via the app.
final class NotifyPlanTests: XCTestCase {
    private let ET = TimeZone(identifier: "America/New_York")!

    /// A fixed "now": Sunday 2026-07-19 12:00 ET.
    private var now: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ET
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 19, hour: 12))!
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ET
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    private func prefs(enabled: Bool = true,
                       kinds: [NotifyKind: Bool] = NotifyPrefs.defaultKindEnabled,
                       offsets: [NotifyKind: Set<NotifyOffset>] = NotifyPrefs.defaultOffsets,
                       morning: Int = 9) -> NotifyPrefs {
        NotifyPrefs(enabled: enabled, morningHour: morning, kindEnabled: kinds, offsets: offsets)
    }

    private func plan(_ items: CalendarItems, _ p: NotifyPrefs? = nil) -> [PlannedNotification] {
        NotifyPlanner.plan(items: items, mainTz: "America/New_York", prefs: p ?? prefs(), now: now)
    }

    // ── Kinds × default offsets ─────────────────────────────────────────────────────────────

    func testDeadlineDefaultOffsets() {
        var items = CalendarItems()
        items.deadlines.append(Deadline(id: "d1", year: 2026, month: 6, day: 21, hour: 7.983,
                                        title: "CHI paper", color: "red")) // Jul 21, 07:59
        let out = plan(items)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.fireDate), [
            date(2026, 7, 20, 9, 0), // day before, morning hour
            date(2026, 7, 21, 6, 59), // 1h before
            date(2026, 7, 21, 7, 44), // 15m before
        ])
        XCTAssertTrue(out.allSatisfy { $0.title == "CHI paper" })
        XCTAssertTrue(out[0].body.contains("tomorrow"))
    }

    func testTimedEventDefault15MinBefore() {
        var items = CalendarItems()
        items.events.append(TimedEvent(id: "e1", year: 2026, month: 6, day: 20, startHour: 14,
                                       endHour: 15, title: "Standup", color: "blue"))
        let out = plan(items)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].fireDate, date(2026, 7, 20, 13, 45))
        XCTAssertEqual(out[0].itemId, "e1")
    }

    func testBandDayBeforeAndDayOfAtMorningHour() {
        var items = CalendarItems()
        items.bands.append(BandEvent(id: "b1", year: 2026, month: 6, track: 0, startDay: 24,
                                     endDay: 28, title: "OOPSLA", color: "green"))
        let out = plan(items)
        XCTAssertEqual(out.map(\.fireDate), [date(2026, 7, 23, 9, 0), date(2026, 7, 24, 9, 0)])
        XCTAssertTrue(out[1].body.contains("today"))
    }

    /// An event anchored to another zone fires at ITS wall-clock's true instant.
    func testAnchorTimezoneRespected() {
        var items = CalendarItems()
        items.events.append(TimedEvent(id: "e1", year: 2026, month: 6, day: 20, startHour: 14,
                                       endHour: 15, title: "Tokyo call", color: "blue",
                                       anchorTz: "Asia/Tokyo")) // 14:00 JST = 01:00 ET
        let out = plan(items)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].fireDate, date(2026, 7, 20, 0, 45)) // 15m before 01:00 ET
    }

    // ── Window / master switch / tags ──────────────────────────────────────────────────────

    func testMasterSwitchOffPlansNothing() {
        var items = CalendarItems()
        items.deadlines.append(Deadline(id: "d1", year: 2026, month: 6, day: 21, hour: 8,
                                        title: "X", color: "red"))
        XCTAssertTrue(plan(items, prefs(enabled: false)).isEmpty)
    }

    func testPastAndBeyondWindowExcluded() {
        var items = CalendarItems()
        items.events.append(TimedEvent(id: "past", year: 2026, month: 6, day: 18, startHour: 10,
                                       endHour: 11, title: "Yesterday", color: "blue"))
        items.events.append(TimedEvent(id: "far", year: 2026, month: 8, day: 20, startHour: 10,
                                       endHour: 11, title: "Sept", color: "blue"))
        XCTAssertTrue(plan(items).isEmpty)
    }

    func testSilentTagMutes() {
        var items = CalendarItems()
        items.deadlines.append(Deadline(id: "d1", year: 2026, month: 6, day: 21, hour: 8,
                                        title: "X", color: "red"))
        items.richById["d1"] = RichFields(tags: [" Silent "]) // trim+lowercase like the tag filter
        XCTAssertTrue(plan(items).isEmpty)
    }

    func testNotifyTagOverridesDisabledKind() {
        var items = CalendarItems()
        items.events.append(TimedEvent(id: "e1", year: 2026, month: 6, day: 20, startHour: 14,
                                       endHour: 15, title: "Opt-in", color: "blue"))
        items.richById["e1"] = RichFields(tags: ["notify"])
        var kinds = NotifyPrefs.defaultKindEnabled
        kinds[.timed] = false
        let out = plan(items, prefs(kinds: kinds))
        XCTAssertEqual(out.count, 1)
    }

    // ── Recurrence ─────────────────────────────────────────────────────────────────────────

    func testWeeklyRecurrenceOccurrencesInWindow() {
        var items = CalendarItems()
        // Base Monday Jul 6 (already past), weekly → Jul 20 + Jul 27 land inside the 14-day window.
        items.events.append(TimedEvent(id: "e1", year: 2026, month: 6, day: 6, startHour: 10,
                                       endHour: 11, title: "Weekly sync", color: "blue"))
        items.richById["e1"] = RichFields(repeatJSON: #"{"kind":"weekly"}"#)
        let out = plan(items)
        XCTAssertEqual(out.map(\.fireDate), [date(2026, 7, 20, 9, 45), date(2026, 7, 27, 9, 45)])
        XCTAssertEqual(out[0].itemId, "e1@2026-6-20") // ghost box id → revealAndSelect target
    }

    func testExdateSkipsOccurrence() {
        var items = CalendarItems()
        items.events.append(TimedEvent(id: "e1", year: 2026, month: 6, day: 6, startHour: 10,
                                       endHour: 11, title: "Weekly sync", color: "blue"))
        items.richById["e1"] = RichFields(repeatJSON: #"{"kind":"weekly","exdates":["2026-07-20"]}"#)
        let out = plan(items)
        XCTAssertEqual(out.map(\.fireDate), [date(2026, 7, 27, 9, 45)])
    }

    // ── Todos ──────────────────────────────────────────────────────────────────────────────

    func testTodoScanDueDateTimeAndTags() {
        let t = TodoScan.scan("- [ ] Ship the draft due:2026-07-21T17:00 #notify #urgent",
                              today: YMD(2026, 6, 19))
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].due, YMD(2026, 6, 21))
        XCTAssertEqual(t[0].dueHour, 17)
        XCTAssertEqual(t[0].tags, ["notify", "urgent"])
        XCTAssertEqual(t[0].title, "Ship the draft")
        XCTAssertFalse(t[0].done)
    }

    func testTodoScanRelativeAndTimeOnlyDues() {
        let today = YMD(2026, 6, 19)
        XCTAssertEqual(TodoScan.scan("- [ ] soon due:3d", today: today)[0].due, YMD(2026, 6, 22))
        let five = TodoScan.scan("- [ ] call due:5pm", today: today)[0]
        XCTAssertEqual(five.due, today)
        XCTAssertEqual(five.dueHour, 17)
        XCTAssertEqual(TodoScan.scan("- [ ] tmrw due:tomorrow", today: today)[0].due, YMD(2026, 6, 20))
    }

    func testTodoDoneAndCheckedNeverNotify() {
        let today = YMD(2026, 6, 19)
        XCTAssertTrue(TodoScan.scan("- [x] finished due:2026-07-21", today: today)[0].done)
        XCTAssertTrue(TodoScan.scan("- [ ] stamped due:2026-07-21 done:2026-07-18", today: today)[0].done)
    }

    // TODO: kind is OFF by default: only #notify todos plan, and a dateless one stays silent.
    func testTodoPlanningDefaultOffWithNotifyOptIn() {
        var items = CalendarItems()
        items.dailyNotes["2026-07-19"] = """
        - [ ] silent by default due:2026-07-20T10:00
        - [ ] opted in due:2026-07-20T10:00 #notify
        - [ ] dateless #notify
        """
        let out = plan(items)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].title, "opted in")
        XCTAssertEqual(out[0].fireDate, date(2026, 7, 20, 9, 45)) // default todo offset: 15m before
    }

    /// An event-note todo inherits the event's date; date-only → anchors at the morning hour.
    func testEventNoteTodoInheritsEventDate() {
        var items = CalendarItems()
        items.events.append(TimedEvent(id: "e1", year: 2026, month: 6, day: 22, startHour: 14,
                                       endHour: 15, title: "Grant review", color: "blue"))
        items.richById["e1"] = RichFields(notes: "- [ ] prep slides #notify")
        var kinds = NotifyPrefs.defaultKindEnabled
        kinds[.timed] = false // isolate the todo
        let out = plan(items, prefs(kinds: kinds))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].title, "prep slides")
        XCTAssertEqual(out[0].fireDate, date(2026, 7, 22, 8, 45)) // 15m before the 9:00 morning anchor
        XCTAssertEqual(out[0].itemId, "e1") // click-through reveals the event
    }

    /// Same line in two notes → two distinct ids (source key is part of the identifier).
    func testTodoIdsDistinctAcrossSources() {
        var items = CalendarItems()
        items.dailyNotes["2026-07-19"] = "- [ ] pay rent due:2026-07-20T10:00 #notify"
        items.dailyNotes["2026-07-20"] = "- [ ] pay rent due:2026-07-20T10:00 #notify"
        let out = plan(items)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.id)).count, 2)
    }

    // ── Ids ────────────────────────────────────────────────────────────────────────────────

    /// Moving an item in time must change the id (the reconcile treats the old one as stale).
    func testIdEncodesFireTime() {
        var items = CalendarItems()
        items.events.append(TimedEvent(id: "e1", year: 2026, month: 6, day: 20, startHour: 14,
                                       endHour: 15, title: "Standup", color: "blue"))
        let before = plan(items)[0].id
        items.events[0].startHour = 15
        let after = plan(items)[0].id
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(before.hasPrefix("cc.ntf|timed|e1|m15|"))
    }

    /// Renaming must also change the id — the pending request carries the banner TEXT, so a
    /// same-id reconcile would keep ringing with the old title.
    func testIdEncodesTitle() {
        var items = CalendarItems()
        items.events.append(TimedEvent(id: "e1", year: 2026, month: 6, day: 20, startHour: 14,
                                       endHour: 15, title: "New event", color: "blue"))
        let before = plan(items)[0].id
        items.events[0].title = "Wash Clothes"
        let after = plan(items)[0]
        XCTAssertNotEqual(before, after.id)
        XCTAssertEqual(after.title, "Wash Clothes")
    }
}
