@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class TimezoneTests: XCTestCase {

    /// Alt-tz off by default → the scene carries no second column.
    func testAltTzOffByDefault() {
        let e = CalendarEngine()
        XCTAssertNil(e.snapshotInput().altDeltaHours)
        XCTAssertNil(e.snapshotInput().altLabel)
    }

    /// Setting an alt tz populates the scene's altDeltaHours/altLabel (which drive the drawn column).
    func testAltTzPopulatesScene() {
        let e = CalendarEngine()
        e.mainTz = "America/New_York"
        e.altTz = "Asia/Tokyo"
        let s = e.snapshotInput()
        XCTAssertNotNil(s.altDeltaHours)
        // NY→Tokyo is +13 (EDT) or +14 (EST) depending on the date.
        XCTAssertTrue(
            [13.0, 14.0].contains(Double(s.altDeltaHours ?? 0)),
            "shift was \(String(describing: s.altDeltaHours))"
        )
        XCTAssertEqual(s.altLabel, DeadlineTZ.shortLabel("Asia/Tokyo", at: e.now))
    }

    /// "none", empty, or same-as-main → no column.
    func testAltTzGuards() {
        let e = CalendarEngine()
        e.mainTz = "America/New_York"
        e.altTz = "none"; XCTAssertNil(e.snapshotInput().altDeltaHours)
        e.altTz = "America/New_York"; XCTAssertNil(e.snapshotInput().altDeltaHours) // == main
    }

    /// Half-hour zones produce a fractional shift (India is +5:30 vs UTC).
    func testFractionalShift() {
        let e = CalendarEngine()
        e.mainTz = "UTC"
        e.altTz = "Asia/Kolkata"
        let d = e.snapshotInput().altDeltaHours ?? 0
        XCTAssertEqual(Double(d), 5.5, accuracy: 0.001)
    }
}

/// Point the calendar store at a throwaway temp dir so tests never read or write the user's real
/// calendar (the engine persists on commit / migration). Set before any CalendarEngine() is created.
func redirectStoreToTemp() {
    let dir = NSTemporaryDirectory() + "cktest-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    setenv("CC_DEMO_DATADIR", dir, 1)
}

@MainActor
final class AnchorTZTests: XCTestCase {
    override func setUp() {
        super.setUp(); redirectStoreToTemp()
    }

    private func setMain(_ tz: String, _ e: CalendarEngine) {
        UserDefaults.standard.set(tz, forKey: PrefKeys.mainTz)
        e.viewPrefsChanged() // re-reads mainTz AND bumps caches.editGen so the display cache re-converts
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PrefKeys.mainTz)
        unsetenv("CC_DEMO_DATADIR") // don't leak the temp-store redirect into other test classes
        super.tearDown()
    }

    /// A drag edit works in the view (main-tz) grid then folds back to the anchor — the round-trip must
    /// preserve the event exactly (date, times, anchor), so editing an event viewed in another zone can't
    /// corrupt it.
    func testWriteBackRoundTripPreservesAnchor() {
        let e = CalendarEngine()
        e.mainTz = "America/Los_Angeles" // viewing in a different zone than the event's anchor
        let ev = TimedEvent(id: "e", year: 2026, month: 6, day: 20, startHour: 14, endHour: 15.5,
                            title: "x", color: "blue", anchorTz: "America/New_York")
        let back = e.anchorEvent(e.displayEvent(ev)) // to-grid then back (what a mouse drag does)
        XCTAssertEqual(back.year, ev.year); XCTAssertEqual(back.month, ev.month); XCTAssertEqual(back.day, ev.day)
        XCTAssertEqual(Double(back.startHour), 14, accuracy: 0.001)
        XCTAssertEqual(Double(back.endHour), 15.5, accuracy: 0.001)
        XCTAssertEqual(back.anchorTz, "America/New_York")
    }

    /// Day-column arithmetic behind day-aware resize/create: whole-day differences across month/year
    /// boundaries (this is what stops the tail-edge resize from collapsing).
    func testDayAwareArithmetic() {
        let e = CalendarEngine()
        XCTAssertEqual(e.dayDiff(2026, 6, 20, 2026, 6, 21), 1)
        XCTAssertEqual(e.dayDiff(2026, 6, 21, 2026, 6, 20), -1)
        XCTAssertEqual(e.dayDiff(2026, 5, 30, 2026, 6, 1), 1) // Jun 30 → Jul 1 (0-based months)
        XCTAssertEqual(e.dayDiff(2025, 11, 31, 2026, 0, 1), 1) // Dec 31 → Jan 1 (year rollover)
        let nd = e.addDays(2026, 5, 30, 1)
        XCTAssertEqual(nd.0, 2026); XCTAssertEqual(nd.1, 6); XCTAssertEqual(nd.2, 1)
    }

    /// A timed event anchored in ET renders 3h earlier when the view switches to PT (same instant), and
    /// its duration is preserved. This is the core "change current timezone → events move" behavior.
    func testTimedEventShiftsWithMainTz() throws {
        let e = CalendarEngine()
        setMain("America/New_York", e)
        let id = e.createTimedEvent(
            year: 2026,
            month: 6,
            day: 20,
            startHour: 12,
            endHour: 14,
            title: "Mtg",
            color: "blue"
        )
        XCTAssertTrue(e.displayEvents(for: 2026).contains { $0.id == id && abs($0.startHour - 12) < 0.001 })
        setMain("America/Los_Angeles", e)
        let disp = e.displayEvents(for: 2026).first { $0.id == id }
        XCTAssertNotNil(disp)
        XCTAssertEqual(try Double(XCTUnwrap(disp?.startHour)), 9, accuracy: 0.001) // 12:00 ET → 09:00 PT
        XCTAssertEqual(try Double(XCTUnwrap(disp?.endHour)), 11, accuracy: 0.001) // duration preserved
    }

    /// A deadline anchored at 23:00 ET shows at 20:00 PT the same day.
    func testDeadlineShiftsWithMainTz() throws {
        let e = CalendarEngine()
        setMain("America/New_York", e)
        let id = e.createDeadline(year: 2026, month: 6, day: 20, hour: 23, title: "CFP", color: "red")
        setMain("America/Los_Angeles", e)
        let d = e.displayDeadlines(for: 2026).first { $0.id == id }
        XCTAssertNotNil(d)
        XCTAssertEqual(try Double(XCTUnwrap(d?.hour)), 20, accuracy: 0.001)
        XCTAssertEqual(d?.day, 20)
    }

    /// Day-crossing: 01:00 ET on Jul 20 is 22:00 PT on Jul 19 — the converted item moves to the previous day.
    func testConversionCrossesMidnight() throws {
        let e = CalendarEngine()
        setMain("America/New_York", e)
        let id = e.createDeadline(year: 2026, month: 6, day: 20, hour: 1, title: "Early", color: "red")
        setMain("America/Los_Angeles", e)
        let d = e.displayDeadlines(for: 2026).first { $0.id == id }
        XCTAssertNotNil(d)
        XCTAssertEqual(try Double(XCTUnwrap(d?.hour)), 22, accuracy: 0.001)
        XCTAssertEqual(d?.day, 19)
    }

    /// Viewing in the anchor zone is the identity (no drift), and a round-trip back restores the time.
    func testRoundTripIdentity() throws {
        let e = CalendarEngine()
        setMain("America/New_York", e)
        let id = e.createTimedEvent(
            year: 2026,
            month: 6,
            day: 20,
            startHour: 8.5,
            endHour: 9.75,
            title: "X",
            color: "blue"
        )
        setMain("Asia/Tokyo", e)
        XCTAssertNotNil(e.displayEvents(for: 2026).first { $0.id == id }) // exists somewhere (maybe next day)
        setMain("America/New_York", e)
        let back = e.displayEvents(for: 2026).first { $0.id == id }
        XCTAssertNotNil(back)
        XCTAssertEqual(try Double(XCTUnwrap(back?.startHour)), 8.5, accuracy: 0.001)
        XCTAssertEqual(try Double(XCTUnwrap(back?.endHour)), 9.75, accuracy: 0.001)
        XCTAssertEqual(back?.day, 20)
    }
}

@MainActor
final class DeadlineCreateTests: XCTestCase {
    override func setUp() {
        super.setUp(); redirectStoreToTemp()
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR"); super.tearDown()
    }

    /// The "+" click path: createDeadline mints an id, selects it, and it shows on the timeline.
    func testCreateDeadline() {
        let e = CalendarEngine()
        let before = e.displayDeadlines(for: 2026).count
        let id = e.createDeadline(year: 2026, month: 6, day: 20, hour: 9, title: "New Deadline", color: "default")
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(e.selectedId, id)
        let ddls = e.displayDeadlines(for: 2026)
        XCTAssertEqual(ddls.count, before + 1)
        XCTAssertTrue(ddls.contains { $0.id == id && $0.hour == 9 && $0.day == 20 && $0.title == "New Deadline" })
    }
}

@MainActor
final class AnchorMigrationTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PrefKeys.mainTz)
        unsetenv("CC_DEMO_DATADIR") // don't leak the temp-store redirect into other test classes
        super.tearDown()
    }

    /// A legacy store (items written before anchoring, so no `anchorTz`) is migrated on load: timed events
    /// are stamped with the resolved main tz (hours untouched), and a deadline that carried a legacy
    /// `originTz` is re-anchored to that origin — preserving its instant — with `originTz` cleared.
    func testMigrationOnLoad() throws {
        let dir = NSTemporaryDirectory() + "mig-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("CC_DEMO_DATADIR", dir, 1)
        UserDefaults.standard.set("America/New_York", forKey: PrefKeys.mainTz)

        // Legacy items: no anchorTz. The deadline's hour (11:00) is the stored main-tz value + an AOE origin.
        let legacy = PersistedState(
            events: [TimedEvent(
                id: "e1",
                year: 2026,
                month: 6,
                day: 20,
                startHour: 9,
                endHour: 10,
                title: "x",
                color: "blue"
            )],
            bands: [],
            deadlines: [Deadline(
                id: "d1",
                year: 2026,
                month: 6,
                day: 20,
                hour: 11,
                title: "cfp",
                color: "red",
                originTz: "AOE"
            )],
            monthTrackNames: nil, rich: nil, dailyNotes: nil
        )
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: dir + "/data.json"))

        let e = CalendarEngine() // init loads the store and runs the anchor migration
        XCTAssertEqual(e.items.events.first?.anchorTz, "America/New_York") // stamped to the main tz
        XCTAssertEqual(Double(e.items.events.first?.startHour ?? -1), 9, accuracy: 0.001) // hour unchanged
        XCTAssertEqual(e.items.deadlines.first?.anchorTz, "AOE") // re-anchored to its origin
        XCTAssertNil(e.items.deadlines.first?.originTz) // legacy field folded in + cleared
    }
}
