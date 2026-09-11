// Now-line edge indicator: when "now" is scrolled out of the week/day timeline, buildToday
// must emit the .nowEdge line hugging the edge + the .nowLabelEdge mini "now" tag — and keep
// both at opacity 0 while the now-line is on-screen (mutually exclusive with now-w/nl-w).

@testable import CalendarGeometry
import CoreGraphics
import XCTest

final class NowEdgeTests: XCTestCase {
    let vp = Viewport(w: 1280, h: 840)

    /// Week view over the month containing `now` (local calendar), with a given timeline scroll.
    private func input(now: Date, tlScroll: CGFloat) -> SceneInput {
        let c = Calendar.current.dateComponents([.year, .month], from: now)
        return SceneInput(z: 2, focus: (c.month ?? 1) - 1, week: 0, vp: vp, scrollY: 0,
                          tlScroll: tlScroll, now: now, year: c.year ?? 2026)
    }

    /// A `now` on a day early in its month (so week 0 shows it), at 04:00 local.
    private func earlyMorningNow() -> Date {
        var c = Calendar.current.dateComponents([.year, .month], from: Date())
        c.day = 2; c.hour = 4; c.minute = 0
        return Calendar.current.date(from: c)!
    }

    private func item(_ g: SceneInput, _ key: String) -> Item? {
        buildScene(g).items.first { $0.key == key }
    }

    func testVisibleNowHasNoEdgeIndicator() throws {
        let g = input(now: earlyMorningNow(), tlScroll: 0) // hours ~0–10 in view → 04:00 visible
        let line = try XCTUnwrap(item(g, "now-w"))
        XCTAssertGreaterThan(line.opacity, 0.5, "the on-screen now-line renders")
        XCTAssertEqual(item(g, "now-w-edge")?.opacity ?? 0, 0, "no edge line while on-screen")
        XCTAssertEqual(item(g, "now-w-edgetag")?.opacity ?? 0, 0, "no edge tag while on-screen")
    }

    func testNowLabelMorphsContinuouslyIntoMiniTag() throws {
        // The big CURRENT TIME pill must shrink CONTINUOUSLY toward the mini tag as the line
        // nears the edge, and be geometrically identical to the pinned mini at the crossing.
        let now = earlyMorningNow()
        let g0 = input(now: now, tlScroll: 0)
        let f = frameFor(g0.focus, g0)
        let tlTop = f.bandY + 4 * f.trackH + 18
        let m = hourMetrics(tlTop, Layout.tlBottomY(vp.h), g0.z, 0, g0.weekHourH)
        let nowFrac: CGFloat = 4 // earlyMorningNow is 04:00
        let T = Layout.edgeLabelMorph

        // Midpoint: line T/2 above the edge → half-morphed size, still centered on the line.
        let gMid = input(now: now, tlScroll: nowFrac * m.hourH - T / 2)
        let mid = try XCTUnwrap(item(gMid, "nl-w"))
        XCTAssertEqual(mid.morph, 0.5, accuracy: 0.01)
        XCTAssertEqual(mid.w, lerp(88, 44, 0.5), accuracy: 0.1)
        XCTAssertEqual(mid.h, lerp(36, 17, 0.5), accuracy: 0.1)

        // Just inside the edge: the shrunken big pill ≈ the pinned mini tag (seamless handoff).
        let gEdge = input(now: now, tlScroll: nowFrac * m.hourH - 0.25)
        let big = try XCTUnwrap(item(gEdge, "nl-w"))
        XCTAssertGreaterThan(big.opacity, 0.5, "still the big item — line is (just) on-screen")
        XCTAssertEqual(big.morph, 1, accuracy: 0.02)
        // The pinned mini tag it will hand off to, one scroll-tick later:
        let gOut = input(now: now, tlScroll: nowFrac * m.hourH + 2)
        let mini = try XCTUnwrap(item(gOut, "now-w-edgetag"))
        XCTAssertEqual(big.w, mini.w, accuracy: 0.5, "same width at the crossing")
        XCTAssertEqual(big.h, mini.h, accuracy: 0.5, "same height at the crossing")
        XCTAssertEqual(big.x, mini.x, accuracy: 0.5, "same anchor at the crossing")
        XCTAssertEqual(big.rect.midY, mini.rect.midY, accuracy: 1.5, "same center at the crossing")
    }

    func testDeadlineLabelMorphMatchesMiniAtBoundary() throws {
        // Same continuity for deadline labels: at the viewport edge the morphed full pill's
        // rect coincides with deadlineEdgeLabel's pinned mini rect.
        let g0 = input(now: earlyMorningNow(), tlScroll: 0)
        let f = frameFor(g0.focus, g0)
        let tlTop = f.bandY + 4 * f.trackH + 18
        let tlBottom = Layout.tlBottomY(vp.h)
        let m = hourMetrics(tlTop, tlBottom, g0.z, 0, g0.weekHourH)
        let d = Deadline(id: "d", year: g0.year, month: g0.focus, day: 2, hour: 4,
                         title: "A fairly long deadline title", color: "red")
        // Line 0.02px inside the top edge → morph ≈ 1 (a long title sheds ~5px of width per
        // remaining morph percent, so probe right at the crossing).
        let g = input(now: earlyMorningNow(), tlScroll: 4 * m.hourH - 0.02)
        let pos = try XCTUnwrap(deadlinePos(d, g))
        let info = deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, g)
        let (rect, p) = deadlineLabelMorphRect(info: info, onLeft: info.defaultOnLeft,
                                               tlTop: tlTop, tlBottom: tlBottom)
        XCTAssertEqual(p, 1, accuracy: 0.02)
        // One tick later the line is out; the pinned mini must sit where the morph ended.
        let gOut = input(now: earlyMorningNow(), tlScroll: 4 * m.hourH + 2)
        let mini = try XCTUnwrap(deadlineEdgeLabel(d, gOut))
        XCTAssertEqual(rect.width, mini.rect.width, accuracy: 0.5)
        XCTAssertEqual(rect.height, mini.rect.height, accuracy: 0.5)
        XCTAssertEqual(rect.minX, mini.rect.minX, accuracy: 0.5)
        XCTAssertEqual(rect.midY, mini.rect.midY, accuracy: 1.5)
    }

    func testDeadlineMiniHonorsTheFullLabelsSide() throws {
        // The mini pill must sit on the SAME side as the full label's base side (the offline
        // deadlineSides assignment) — falling back to the default geometric rule made the tag
        // jump sides at the big↔mini handoff when the solver had picked the other side.
        let g = input(now: earlyMorningNow(), tlScroll: 700) // hour-4 deadline out the top
        let d = Deadline(id: "d", year: g.year, month: g.focus, day: 2, hour: 4,
                         title: "Ship", color: "red")
        let byDefault = try XCTUnwrap(deadlineEdgeLabel(d, g))
        let overridden = try XCTUnwrap(deadlineEdgeLabel(d, g, onLeft: !byDefault.onLeft))
        XCTAssertEqual(overridden.onLeft, !byDefault.onLeft, "the solver's side wins")
        XCTAssertNotEqual(overridden.rect.minX, byDefault.rect.minX,
                          "the two sides place the pill on opposite sides of the column")
        // And nil (no solver entry) matches the full label's own fallback: the default rule.
        let pos = deadlineRawSanity(d, g)
        XCTAssertEqual(byDefault.onLeft, g.z > 2 || (pos.x + pos.w / 2 >= (Layout.labelW + g.vp.w) / 2))
    }

    /// The column x/w the mini derives from (deadlineEdgePos, ignoring the vertical cull).
    private func deadlineRawSanity(_ d: Deadline, _ g: SceneInput) -> (x: CGFloat, w: CGFloat) {
        let ep = deadlineEdgePos(d, g)!
        return (ep.x, ep.w)
    }

    func testScrolledOutNowClampsToTopEdge() throws {
        let g = input(now: earlyMorningNow(), tlScroll: 700) // late window → 04:00 exits the TOP
        XCTAssertEqual(item(g, "now-w")?.opacity ?? 0, 0, "the real now-line is off-screen")
        let edge = try XCTUnwrap(item(g, "now-w-edge"))
        XCTAssertGreaterThan(edge.opacity, 0.5, "edge line shows when now is scrolled out")
        let f = frameFor(g.focus, g)
        let tlTop = f.bandY + 4 * f.trackH + 18
        XCTAssertEqual(edge.y, tlTop + 1, accuracy: 0.01, "line hugs just inside the top edge")
        let tag = try XCTUnwrap(item(g, "now-w-edgetag"))
        XCTAssertGreaterThan(tag.opacity, 0.5)
        XCTAssertEqual(tag.text, "now", "the mini tag says just \"now\"")
        XCTAssertEqual(tag.h, 17, accuracy: 0.01, "fixed mini size, not the CURRENT TIME pill")
    }
}
