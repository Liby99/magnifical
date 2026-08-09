@testable import CalendarGeometry
import XCTest

final class SourceIdTests: XCTestCase {
    func testStripsOccurrenceSuffix() {
        XCTAssertEqual(sourceId(of: "tev-abc"), "tev-abc") // base box
        XCTAssertEqual(sourceId(of: "tev-abc@2026-6-24"), "tev-abc") // occurrence ghost
        XCTAssertEqual(sourceId(of: "tev-abc@2026-6-24\(PROMOTED_SUFFIX)"), "tev-abc") // promoted bar
        XCTAssertEqual(sourceId(of: "tev-abc@2026-6-24\(SEGMENT_MARKER)1"), "tev-abc") // month-crossing tail
    }

    /// Imported ids bake the vendor uid in; Google/Exchange uids contain `@` — which must NOT truncate the
    /// id (that broke the event drawer, closing it immediately).
    func testPreservesAtInsideImportedIds() {
        let google = "apple-7b7htk5uno2jvrtn35tqre4mkf@google.com-20271220-2100"
        XCTAssertEqual(sourceId(of: google), google)
        let recurringInstance = "apple-6eb2n7e66ancm0bhe52vrdak9j_R20260625T170000@google.com-20270401-1300"
        XCTAssertEqual(sourceId(of: recurringInstance), recurringInstance)
        let rid = "apple-mvotk440tro2d1tq5425spgbvo@google.com/RID=799012800"
        XCTAssertEqual(sourceId(of: rid), rid)
        let exchange = "apple-040000008200E00074C5B7101A82E00800000000B475F03A1816DD01-20260717-1630"
        XCTAssertEqual(sourceId(of: exchange), exchange)
    }
}
