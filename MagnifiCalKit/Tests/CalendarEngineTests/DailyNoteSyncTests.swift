@testable import CalendarEngine
import Foundation
import XCTest

/// Daily/scope notes as DailyNote records — the 2026-09-04 census gap (35 notes on the Mac,
/// structurally 0 on the phone: no record type existed).
@MainActor
final class DailyNoteSyncTests: XCTestCase {
    override func setUp() {
        super.setUp()
        redirectStoreToTemp()
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    func testRecordNameKeyRoundTrip() {
        for key in ["2026-08-19", "week:2026-08-16", "month:2026-08"] {
            let name = CloudSync.dnoteRecordName(forKey: key)
            XCTAssertFalse(name.contains(":"), name)
            XCTAssertEqual(CloudSync.dnoteKey(fromRecordName: name), key)
        }
        XCTAssertNil(CloudSync.dnoteKey(fromRecordName: "tev-abc-1"))
    }

    func testDeltaEmitsNoteUpsertsAndDeletes() {
        let old = PersistedState(events: [], bands: [], deadlines: [],
                                 dailyNotes: ["2026-08-19": "keep", "week:2026-08-16": "clear me"])
        let new = PersistedState(events: [], bands: [], deadlines: [],
                                 dailyNotes: ["2026-08-19": "keep EDITED", "month:2026-08": "brand new"])
        let (up, del) = CalendarEngine.recordDelta(from: old, to: new)
        XCTAssertTrue(up.contains("dnote-2026-08-19"))
        XCTAssertTrue(up.contains("dnote-month_2026-08"))
        XCTAssertTrue(del.contains("dnote-week_2026-08-16"))
        // Unchanged notes emit nothing.
        let (up2, del2) = CalendarEngine.recordDelta(from: new, to: new)
        XCTAssertTrue(up2.isEmpty && del2.isEmpty)
    }

    func testSetDailyNoteEmitsDeltaThroughOnLocalChange() {
        let e = CalendarEngine()
        var upserts: [String] = []
        e.onLocalChange = { up, _ in upserts += up }
        e.setDailyNote("2026-09-04", "- [ ] census the phone")
        e.persistNow()
        XCTAssertTrue(upserts.contains("dnote-2026-09-04"), "\(upserts)")
    }

    func testApplyRemoteMergesAndDeletesNotes() {
        let e = CalendarEngine(cloudReadOnly: true)
        e.setDailyNote("2026-01-01", "local note")
        let gen0 = e.noteEdits.gen
        e.applyRemote(deletedIDs: ["dnote-2026-01-01"],
                      dailyNotes: ["week:2026-08-16": "from the Mac"])
        XCTAssertEqual(e.dailyNote("week:2026-08-16"), "from the Mac")
        XCTAssertEqual(e.dailyNote("2026-01-01"), "")
        XCTAssertGreaterThan(e.noteEdits.gen, gen0, "note views must repaint on remote note apply")
    }
}
