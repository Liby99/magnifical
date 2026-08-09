@testable import CalendarEngine
import CalendarGeometry
import XCTest

/// The iPhone viewer's read-only cloud seam: `CalendarEngine(cloudReadOnly: true)` must never
/// wire the outbound push path. The CKSyncEngine itself can't run headless in tests (no
/// entitlement/account), so these assert the engine-side contract; the hard server-side block
/// (nextRecordZoneChangeBatch → nil) is enforced in CloudSync/RegistrySync by the same flag.
@MainActor
final class ReadOnlySyncTests: XCTestCase {
    override func setUp() {
        super.setUp()
        redirectStoreToTemp()
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    func testDefaultIsReadWrite() {
        XCTAssertFalse(CalendarEngine().cloudReadOnly)
    }

    func testReadOnlyEngineStillMutatesLocally() {
        let e = CalendarEngine(cloudReadOnly: true)
        XCTAssertTrue(e.cloudReadOnly)
        let id = e.createTimedEvent(year: e.year, month: 5, day: 10,
                                    startHour: 9, endHour: 10, title: "local", color: "blue")
        XCTAssertTrue(e.items.events.contains { $0.id == id }, "local mutations still work (stay on-device)")
        // No cloud in tests at all — but the outbound hook must certainly be unwired.
        XCTAssertNil(e.onLocalChange)
        e.syncNow() // must be a harmless no-op without a live cloud
    }
}
