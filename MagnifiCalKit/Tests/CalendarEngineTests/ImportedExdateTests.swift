@testable import CalendarEngine
import CalendarGeometry
import XCTest

/// The make-local-copy "exdate": copying an imported occurrence excludes THAT occurrence
/// stickily (userHidden on the full occurrence id), so it stays gone across re-imports even
/// after the local copy is deleted. (The volatile dedup `hidden` flag alone is recomputed per
/// import and used to resurrect the original the moment its shadow copy disappeared.)
@MainActor
final class ImportedExdateTests: XCTestCase {
    private func fetched(_ uid: String, _ title: String, y: Int, m1: Int, d: Int,
                         h: Int) -> FetchedAppleEvent {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: y, month: m1, day: d, hour: h))!
        return FetchedAppleEvent(uid: uid, eventId: nil, title: title, start: start,
                                 end: start.addingTimeInterval(3600), allDay: false,
                                 calendarId: "c", colorHex: "#4a8ee8", notes: nil, location: nil,
                                 url: nil, organizer: nil, attendees: [], sourceTitle: "iCloud",
                                 calendarTitle: "Work")
    }

    /// make local copy → DELETE the copy (the documented way to delete an imported occurrence)
    /// → relaunch re-import: the imported occurrence must NOT come back.
    func testLocalCopyExclusionSurvivesDeleteAndReimport() throws {
        let e = CalendarEngine()
        let y = e.year
        let feed = [fetched("u1", "Standup", y: y, m1: 6, d: 10, h: 9),
                    fetched("u1", "Standup", y: y, m1: 6, d: 17, h: 9)]
        e.mergeAppleEvents(feed)
        let imp = try XCTUnwrap(e.imported.events.first { $0.day == 10 })
        let copyId = try XCTUnwrap(e.makeLocalCopy(imp.id))
        XCTAssertFalse(e.displayEvents(for: y).contains { $0.id == imp.id },
                       "copied original must be hidden immediately")

        // Delete the local copy, then simulate the next launch's re-import.
        e.selectedId = copyId
        e.deleteSelected()
        XCTAssertFalse(e.itemExists(copyId))
        e.mergeAppleEvents(feed)

        XCTAssertFalse(e.displayEvents(for: y).contains { $0.id == imp.id },
                       "deleted occurrence resurrected — the exclusion must survive re-import")
        // The sibling occurrence (Jun 17) is untouched by the per-occurrence exclusion.
        XCTAssertTrue(e.displayEvents(for: y).contains { $0.day == 17 && isImported($0.id, e) })
    }

    /// Unhide on the revealed excluded occurrence clears the per-occurrence flag too.
    func testUnhideClearsOccurrenceExclusion() throws {
        let e = CalendarEngine()
        let y = e.year
        e.mergeAppleEvents([fetched("u2", "1:1", y: y, m1: 6, d: 12, h: 14)])
        let imp = try XCTUnwrap(e.imported.events.first)
        let copyId = try XCTUnwrap(e.makeLocalCopy(imp.id))
        e.selectedId = copyId
        e.deleteSelected()
        XCTAssertTrue(e.isUserHidden(imp.id))
        e.unhideImportedSeries(imp.id)
        XCTAssertFalse(e.isUserHidden(imp.id))
        XCTAssertTrue(e.displayEvents(for: y).contains { $0.id == imp.id },
                      "unhidden occurrence draws again")
    }

    private func isImported(_ id: String, _ e: CalendarEngine) -> Bool {
        e.isImported(id)
    }

    /// The sync delta ships a per-occurrence USER exclusion as an Overlay upsert, while pure
    /// dedup-`hidden` churn on occurrence keys stays local (never synced).
    func testDeltaSyncsOccurrenceExclusionButNotDedupChurn() {
        let occ = "apple-uid1-20260610-0900"
        func state(_ rich: [String: RichFields]) -> PersistedState {
            PersistedState(events: [], bands: [], deadlines: [], monthTrackNames: nil, rich: rich)
        }
        // userHidden appears on the occurrence key → upsert; cleared → delete.
        var d = CalendarEngine.recordDelta(from: state([:]),
                                           to: state([occ: RichFields(userHidden: true)]))
        XCTAssertTrue(d.upserts.contains(occ), "user exclusion must sync")
        d = CalendarEngine.recordDelta(from: state([occ: RichFields(userHidden: true)]),
                                       to: state([:]))
        XCTAssertTrue(d.deletes.contains(occ), "cleared exclusion must sync as a delete")
        // Dedup-only churn (hidden flag, no user data) → neither upsert nor delete.
        d = CalendarEngine.recordDelta(from: state([:]),
                                       to: state([occ: RichFields(hidden: true)]))
        XCTAssertFalse(d.upserts.contains(occ) || d.deletes.contains(occ),
                       "dedup churn stays local")
    }
}
