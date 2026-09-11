// PROJ quick-add must NOT shuffle the page: a self-edit splices its fresh rows into the
// FROZEN project order (NativeProjPanel.splicing) instead of refreezing — every project keeps
// its slot, the new row joins its project's membership on top.

@testable import CalendarRender
import XCTest

final class ProjQuickAddOrderTests: XCTestCase {
    private let order: [(key: String, ranked: [String])] = [
        (key: "alpha", ranked: ["a1", "a2"]),
        (key: "beta", ranked: ["b1"]),
        (key: "gamma", ranked: []),
    ]

    func testFreshAnchorPrependsWithoutMovingProjects() {
        let out = NativeProjPanel.splicing(order, project: "beta", anchors: ["b1", "bNEW"])
        XCTAssertEqual(out.map(\.key), ["alpha", "beta", "gamma"], "project slots untouched")
        XCTAssertEqual(out[1].ranked, ["bNEW", "b1"], "the new row joins ITS project, on top")
        XCTAssertEqual(out[0].ranked, ["a1", "a2"], "other projects' membership untouched")
    }

    func testNoFreshAnchorsIsANoOp() {
        let out = NativeProjPanel.splicing(order, project: "alpha", anchors: ["a1", "a2"])
        XCTAssertEqual(out.map(\.ranked), order.map(\.ranked))
    }

    func testUnknownProjectIsANoOp() {
        let out = NativeProjPanel.splicing(order, project: "delta", anchors: ["d1"])
        XCTAssertEqual(out.map(\.key), order.map(\.key))
    }
}
