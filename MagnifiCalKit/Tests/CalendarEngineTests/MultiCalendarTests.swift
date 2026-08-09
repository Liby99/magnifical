@testable import CalendarEngine
import CalendarGeometry
import XCTest

/// Multiple calendars ("documents"): each is disjoint, only one is open at a time, and the default is
/// "Main". Store is redirected to a throwaway dir per test (redirectStoreToTemp → CC_DEMO_DATADIR).
@MainActor
final class MultiCalendarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        redirectStoreToTemp()
        UserDefaults.standard.removeObject(forKey: PrefKeys.calActiveId)
        UserDefaults.standard.removeObject(forKey: PrefKeys.calRecents)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PrefKeys.calActiveId)
        UserDefaults.standard.removeObject(forKey: PrefKeys.calRecents)
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    private func addEvent(_ e: CalendarEngine, _ title: String) -> String {
        e.createTimedEvent(year: e.year, month: 5, day: 10, startHour: 9, endHour: 10, title: title, color: "blue")
    }

    func testDefaultCalendarIsMain() {
        let e = CalendarEngine()
        XCTAssertEqual(e.activeCalendarName, "Main")
        XCTAssertEqual(e.allCalendars.count, 1)
        XCTAssertFalse(e.canRemoveCalendar, "the only calendar can't be removed")
    }

    func testCreateSwitchIsolation() throws {
        let e = CalendarEngine()
        let a = addEvent(e, "A")
        XCTAssertTrue(e.items.events.contains { $0.id == a })

        // New calendar → empty, active, and now removable (two exist).
        e.createCalendar(named: "Debug")
        XCTAssertEqual(e.activeCalendarName, "Debug")
        XCTAssertTrue(e.items.events.isEmpty, "a new calendar starts empty")
        XCTAssertTrue(e.canRemoveCalendar)
        let b = addEvent(e, "B")
        XCTAssertEqual(e.items.events.count, 1)

        // Switch back to Main → only A; Debug's event never bleeds in.
        let mainId = try XCTUnwrap(e.allCalendars.first { $0.name == "Main" }?.id)
        e.switchCalendar(to: mainId)
        XCTAssertTrue(e.items.events.contains { $0.id == a })
        XCTAssertFalse(e.items.events.contains { $0.id == b })
    }

    func testActiveCalendarPersistsAcrossReload() {
        let e = CalendarEngine()
        _ = addEvent(e, "A") // in Main
        e.createCalendar(named: "Two") // switches to Two (Main persisted on the way out)
        _ = addEvent(e, "B") // in Two
        e.persistNow()

        // A fresh engine (relaunch) reopens the active calendar from UserDefaults.
        let e2 = CalendarEngine()
        XCTAssertEqual(e2.activeCalendarName, "Two")
        XCTAssertEqual(e2.items.events.count, 1, "reload sees only Two's data")
        XCTAssertEqual(e2.items.events.first?.title, "B")
    }

    func testRemoveFallsBackToAnother() {
        let e = CalendarEngine()
        let mainId = e.registry.activeId
        e.createCalendar(named: "Temp")
        let tempId = e.registry.activeId
        XCTAssertNotEqual(mainId, tempId)

        e.removeCurrentCalendar()
        XCTAssertEqual(e.allCalendars.count, 1)
        XCTAssertEqual(e.registry.activeId, mainId, "removing Temp falls back to Main")
        XCTAssertFalse(e.allCalendars.contains { $0.id == tempId })
    }

    /// Main is the anchor calendar (fixed id, shared iCloud zone) — it can never be removed,
    /// even when other calendars exist. The menu's Remove item disables via canRemoveCalendar.
    func testMainCannotBeRemoved() throws {
        let e = CalendarEngine()
        e.createCalendar(named: "Other")
        XCTAssertTrue(e.canRemoveCalendar, "a non-Main calendar can be removed")

        let mainId = try XCTUnwrap(e.allCalendars.first { $0.name == "Main" }?.id)
        e.switchCalendar(to: mainId)
        XCTAssertFalse(e.canRemoveCalendar, "on Main, Remove is disabled even with others around")
        e.removeCurrentCalendar() // belt-and-braces: a direct call must no-op too
        XCTAssertEqual(e.allCalendars.count, 2)
        XCTAssertEqual(e.activeCalendarName, "Main")
    }

    func testRemoveLastIsNoOp() {
        let e = CalendarEngine()
        e.removeCurrentCalendar() // only Main exists → no-op
        XCTAssertEqual(e.allCalendars.count, 1)
        XCTAssertEqual(e.activeCalendarName, "Main")
    }

    func testRename() {
        let e = CalendarEngine()
        e.renameCurrentCalendar("Personal")
        XCTAssertEqual(e.activeCalendarName, "Personal")
        XCTAssertEqual(e.allCalendars.count, 1, "rename doesn't add a calendar")
    }

    func testDataIsDisjointAcrossCalendars() throws {
        // Ids are globally-unique UUIDs and each calendar is a separate file, so there's no cross-calendar
        // collision and no bleed: each calendar sees only its own event.
        let e = CalendarEngine()
        let a = addEvent(e, "A")
        e.createCalendar(named: "Other")
        let b = addEvent(e, "B")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(e.items.events.map(\.id), [b], "Other holds only B")
        let mainId = try XCTUnwrap(e.allCalendars.first { $0.name == "Main" }?.id)
        e.switchCalendar(to: mainId)
        XCTAssertEqual(e.items.events.map(\.id), [a], "Main holds only A")
    }

    func testAppleSelectionIsPerCalendar() throws {
        let e = CalendarEngine()
        e.appleSyncEnabled = true
        e.appleCalendarIds = ["work-cal"]

        e.createCalendar(named: "Other")
        XCTAssertFalse(e.appleSyncEnabled, "a new calendar has its own (empty) Apple subscription")
        XCTAssertTrue(e.appleCalendarIds.isEmpty)

        let mainId = try XCTUnwrap(e.allCalendars.first { $0.name == "Main" }?.id)
        e.switchCalendar(to: mainId)
        XCTAssertTrue(e.appleSyncEnabled, "Main's selection is preserved")
        XCTAssertEqual(e.appleCalendarIds, ["work-cal"])
    }

    func testLegacyStoreMigratesToMain() throws {
        // Pre-multi-calendar layout: a single data.json at the CalendarKit root.
        let base = calendarKitBaseDir()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let legacy = PersistedState(
            events: [TimedEvent(id: "new-1", year: 2026, month: 5, day: 10, startHour: 9, endHour: 10,
                                title: "Legacy", color: "blue", anchorTz: "America/New_York")],
            bands: [], deadlines: []
        )
        try JSONEncoder().encode(legacy).write(to: base.appendingPathComponent("data.json"))

        // Booting the engine migrates it into Main.
        let e = CalendarEngine()
        XCTAssertEqual(e.activeCalendarName, "Main")
        XCTAssertTrue(e.items.events.contains { $0.title == "Legacy" }, "legacy data loads into Main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("data.json").path),
                       "the legacy root data.json was moved into Main's dir")
    }

    /// The hot-switch regression (2026-08): the parsed TODO/PROJ feeds are cached per
    /// (editGen, noteGen) — switching calendars reset the counters to 0 while KEEPING the old
    /// calendar's caches, so on a fresh calendar (counters back at the cached values) the OTHER
    /// calendar's todos/projects/note items kept showing as current. The dashboards must show
    /// only the active calendar's feed the moment the switch lands.
    func testFeedsDoNotBleedAcrossSwitch() throws {
        let today = "2026-06-01"
        let e = CalendarEngine()
        e.setDailyNote(today, "- [ ] main-only todo due:today\n- [ ] kickoff @project:alpha")
        XCTAssertFalse(e.todoFeed(today: today).isEmpty, "Main's note todos feed the dashboard")
        XCTAssertFalse(e.projFeed(today: today).isEmpty, "…and its PROJ index")

        // A brand-new empty calendar: no todos, no projects — immediately, not after a refresh.
        e.createCalendar(named: "Empty")
        XCTAssertTrue(e.todoFeed(today: today).isEmpty,
                      "a fresh calendar must not show another calendar's todos")
        XCTAssertTrue(e.projFeed(today: today).isEmpty,
                      "a fresh calendar must not show another calendar's projects")

        // Switching back restores Main's own feed.
        let mainId = try XCTUnwrap(e.allCalendars.first { $0.name == "Main" }?.id)
        e.switchCalendar(to: mainId)
        XCTAssertFalse(e.todoFeed(today: today).isEmpty, "Main's todos return on switch-back")
    }

    /// The File ▸ Calendars submenu rows: EVERY calendar (including the open one), the open one
    /// flagged active (the tick), each with its item count — "Main: 325 events"-style labels.
    func testCalendarMenuRows() throws {
        let e = CalendarEngine()
        _ = addEvent(e, "A"); _ = addEvent(e, "B")
        e.createCalendar(named: "Demo")
        _ = addEvent(e, "C")

        let rows = e.calendarMenuRows()
        XCTAssertEqual(rows.count, 2, "every calendar is listed, including the open one")
        let main = try XCTUnwrap(rows.first { $0.name == "Main" })
        let demo = try XCTUnwrap(rows.first { $0.name == "Demo" })
        XCTAssertTrue(demo.active, "the open calendar carries the tick")
        XCTAssertFalse(main.active)
        XCTAssertEqual(demo.count, 1, "the open calendar counts its LIVE items")
        XCTAssertEqual(main.count, 2, "closed calendars count from their persisted store")
        XCTAssertEqual(main.label, "Main: 2 events")
        XCTAssertEqual(demo.label, "Demo: 1 event", "singular form for one item")

        // Switch back: the tick flips and the counts follow the stores.
        e.switchCalendar(to: main.id)
        let back = e.calendarMenuRows()
        XCTAssertTrue(try XCTUnwrap(back.first { $0.name == "Main" }).active)
        XCTAssertFalse(try XCTUnwrap(back.first { $0.name == "Demo" }).active)
        XCTAssertEqual(try XCTUnwrap(back.first { $0.name == "Demo" }).count, 1,
                       "the switched-away calendar's count is cached on the way out")
    }
}
