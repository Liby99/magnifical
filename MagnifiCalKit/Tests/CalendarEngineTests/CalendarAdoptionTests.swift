@testable import CalendarEngine
import Foundation
import XCTest

/// Virgin-device calendar adoption: a fresh install boots on the bootstrap default ("Main",
/// empty) whose zone doesn't exist in the cloud — when the registry fetch delivers real
/// calendars, the device must ADOPT one as active instead of rendering an empty calendar
/// forever (the 2026-08 phone bring-up bug).
@MainActor
final class CalendarAdoptionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        redirectStoreToTemp()
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    private func meta(_ id: String, _ name: String, order: Int) -> CalendarMeta {
        CalendarMeta(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1000), order: order)
    }

    func testVirginDeviceAdoptsPrimaryCloudCalendar() {
        let e = CalendarEngine(cloudReadOnly: true)
        XCTAssertEqual(e.activeCalendar?.id, CalendarRegistry.mainId)
        e.applyRemoteCalendars(upserts: [meta("cal-bbb", "Research", order: 1),
                                         meta("cal-aaa", "Personal", order: 0)],
                               deletes: [])
        XCTAssertEqual(e.activeCalendar?.id, "cal-aaa", "adopts the lowest-order cloud calendar")
        // Read-only device: the dead bootstrap default is dropped from the switcher.
        XCTAssertFalse(e.allCalendars.contains { $0.id == CalendarRegistry.mainId })
        XCTAssertEqual(Set(e.allCalendars.map(\.id)), ["cal-aaa", "cal-bbb"])
    }

    func testWritableVirginDeviceAdoptsButKeepsDefault() {
        let e = CalendarEngine()
        e.applyRemoteCalendars(upserts: [meta("cal-xyz", "Work", order: 0)], deletes: [])
        XCTAssertEqual(e.activeCalendar?.id, "cal-xyz")
        // Writable device: the default stays (its first-run push may have offered it upstream).
        XCTAssertTrue(e.allCalendars.contains { $0.id == CalendarRegistry.mainId })
    }

    func testDeviceWithLocalDataNeverAdopts() {
        let e = CalendarEngine(cloudReadOnly: true)
        _ = e.createTimedEvent(year: e.year, month: 5, day: 10,
                               startHour: 9, endHour: 10, title: "mine", color: "blue")
        e.applyRemoteCalendars(upserts: [meta("cal-zzz", "Other", order: 0)], deletes: [])
        XCTAssertEqual(e.activeCalendar?.id, CalendarRegistry.mainId,
                       "a device with local edits keeps its active calendar")
    }

    func testEstablishedMultiCalendarDeviceNeverAdopts() {
        let e = CalendarEngine()
        let extra = e.registry.create(name: "Second")
        _ = extra
        e.applyRemoteCalendars(upserts: [meta("cal-www", "Cloud", order: 0)], deletes: [])
        XCTAssertEqual(e.activeCalendar?.id, CalendarRegistry.mainId,
                       "knowing more than the bootstrap default disqualifies adoption")
    }
}
