@testable import CalendarEngine
import CalendarGeometry // sourceId(of:)
import XCTest

/// View ▸ Filter by Tags — web-parity "If Any" semantics over the display caches.
@MainActor
final class TagFilterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("CC_DEMO_DATADIR", NSTemporaryDirectory() + "cc-tagfilter-tests-" + UUID().uuidString, 1)
        UserDefaults.standard.removeObject(forKey: PrefKeys.hiddenTags)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PrefKeys.hiddenTags)
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    /// Set the hidden-tag keys the way the menu does (defaults + cache invalidation).
    private func hide(_ keys: [String], _ e: CalendarEngine) {
        UserDefaults.standard.set(keys, forKey: PrefKeys.hiddenTags)
        e.viewPrefsChanged()
    }

    private func makeEngine() -> (e: CalendarEngine, work: String, both: String, untagged: String, band: String) {
        let e = CalendarEngine()
        let y = e.year
        let work = e.createTimedEvent(year: y, month: 5, day: 10, startHour: 9, endHour: 10, title: "W", color: "blue")
        let both = e.createTimedEvent(year: y, month: 5, day: 11, startHour: 9, endHour: 10, title: "WF", color: "blue")
        let untagged = e.createTimedEvent(
            year: y,
            month: 5,
            day: 12,
            startHour: 9,
            endHour: 10,
            title: "U",
            color: "blue"
        )
        let band = e.demoAddBand(month: 5, track: 0, startDay: 3, endDay: 6, title: "B", color: "green")
        e.setTags(work, ["Work"]) // stored with original casing — filter must match lowercased
        e.setTags(both, ["work", "fun"])
        e.setTags(band, ["work"])
        return (e, work, both, untagged, band)
    }

    private func visibleEventIds(_ e: CalendarEngine) -> Set<String> {
        Set(e.displayEvents(for: e.year).map(\.id))
    }

    func testNoFilterShowsEverything() {
        let (e, work, both, untagged, band) = makeEngine()
        XCTAssertTrue(visibleEventIds(e).isSuperset(of: [work, both, untagged]))
        XCTAssertTrue(e.displayBands(for: e.year).contains { $0.id == band })
    }

    func testHideTagIsIfAnyAndCaseInsensitive() {
        let (e, work, both, untagged, band) = makeEngine()
        hide(["work"], e)
        let vis = visibleEventIds(e)
        XCTAssertFalse(vis.contains(work), "only-'Work' event must hide (case-insensitive)")
        XCTAssertTrue(vis.contains(both), "'work'+'fun' stays: at least one tag is still shown (If Any)")
        XCTAssertTrue(vis.contains(untagged), "untagged unaffected unless the Untagged row is hidden")
        XCTAssertFalse(e.displayBands(for: e.year).contains { $0.id == band }, "tagged band hides too")
    }

    func testHideUntaggedSentinel() {
        let (e, work, both, untagged, _) = makeEngine()
        hide([CalendarEngine.untaggedKey], e)
        let vis = visibleEventIds(e)
        XCTAssertFalse(vis.contains(untagged))
        XCTAssertTrue(vis.contains(work))
        XCTAssertTrue(vis.contains(both))
    }

    func testPromotedGhostFollowsSource() {
        let (e, work, _, _, _) = makeEngine()
        e.setPromoteTrack(work, 2)
        XCTAssertTrue(e.displayBands(for: e.year).contains { sourceId(of: $0.id) == work }, "promoted ghost exists")
        hide(["work"], e)
        XCTAssertFalse(e.displayBands(for: e.year).contains { sourceId(of: $0.id) == work },
                       "hiding the tag hides the promoted ghost with its source")
    }

    func testTagUniverseDedupesAndCounts() {
        let (e, _, _, _, _) = makeEngine()
        let uni = e.tagUniverse()
        let workRow = uni.rows.first { $0.key == "work" }
        XCTAssertEqual(workRow?.count, 3, "'Work'/'work' dedupe to one key counted per item")
        XCTAssertEqual(workRow?.label, "Work", "label keeps first-seen casing")
        XCTAssertEqual(uni.rows.first?.key, "work", "count-ordered: 'work'(3) first")
        XCTAssertEqual(uni.untagged, 1)
    }

    /// The tag universe is cached per edit generation (indexed once, reused across popover renders /
    /// search keystrokes) and invalidated by any edit — so the filter never shows a stale tag set.
    func testTagUniverseCachedAndInvalidatedOnEdit() {
        let (e, _, _, _, _) = makeEngine()
        _ = e.tagUniverse()
        XCTAssertNotNil(e.caches.tag, "first call populates the cache")
        XCTAssertEqual(e.caches.tag?.gen, e.caches.editGen, "cache stamped with the current edit generation")

        // A read with no intervening edit doesn't recompute or bump the generation.
        let genBefore = e.caches.editGen
        _ = e.tagUniverse()
        XCTAssertEqual(e.caches.editGen, genBefore, "reading the universe is side-effect free")

        // A tag edit leaves the cache stale until the next read, which recomputes + re-stamps it.
        let n = e.createTimedEvent(year: e.year, month: 6, day: 1, startHour: 9, endHour: 10, title: "N", color: "blue")
        e.setTags(n, ["work"])
        XCTAssertNotEqual(e.caches.tag?.gen, e.caches.editGen, "edit invalidates the cache (gen no longer matches)")
        let uni = e.tagUniverse()
        XCTAssertEqual(uni.rows.first { $0.key == "work" }?.count, 4, "recomputed to include the new tagged event")
        XCTAssertEqual(e.caches.tag?.gen, e.caches.editGen, "recompute re-stamps the cache to the new generation")
    }
}
