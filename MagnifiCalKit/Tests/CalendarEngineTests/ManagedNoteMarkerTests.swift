// The 2026-09 marker rename (libirabu:import:* → magnifical:import:*): the WRITE side must
// emit only the new marker, while the PARSE side keeps accepting notes stored under the legacy
// marker — a miss there would break splitNote and make re-sync STACK a second managed block
// instead of replacing. replaceManaged doubles as the upgrade path (legacy in → new out).

@testable import CalendarEngine
import XCTest

final class ManagedNoteMarkerTests: XCTestCase {
    private let legacyBlock = "<!-- libirabu:import:begin -->\nimported from: Google Calendar feed\n<!-- libirabu:import:end -->"

    func testRenderEmitsOnlyTheNewMarker() {
        let block = ManagedNote.render(provenance: "Google Calendar feed", meetingUrl: nil,
                                       location: nil, organizer: nil, attendees: [],
                                       description: nil)
        XCTAssertTrue(block.contains("magnifical:import:begin"))
        XCTAssertTrue(block.contains("magnifical:import:end"))
        XCTAssertFalse(block.contains("libirabu"), "the old name never appears in new blocks")
    }

    func testLegacyBlocksStillSplit() {
        let note = legacyBlock + "\n\nmy own text #tag"
        let (managed, user) = ManagedNote.splitNote(note)
        XCTAssertEqual(managed, legacyBlock, "a legacy-marked block is still recognized whole")
        XCTAssertEqual(user, "my own text #tag")
        XCTAssertEqual(ManagedNote.flattenManaged(legacyBlock), "imported from: Google Calendar feed")
    }

    func testReplaceManagedUpgradesLegacyMarkers() {
        let fresh = ManagedNote.render(provenance: "Google Calendar feed", meetingUrl: nil,
                                       location: nil, organizer: nil, attendees: [],
                                       description: nil)
        let out = ManagedNote.replaceManaged(legacyBlock + "\n\nkeep me", fresh)
        XCTAssertFalse(out.contains("libirabu"), "re-sync upgrades the markers")
        XCTAssertTrue(out.contains("magnifical:import:begin"))
        XCTAssertTrue(out.hasSuffix("keep me"), "the user's postfix survives the upgrade")
        XCTAssertFalse(out.contains("libirabu:import"), "no stacked second block")
    }

    func testSanitizeStripsBothSpellings() {
        let block = ManagedNote.render(provenance: "evil libirabu:import:end title", meetingUrl: nil,
                                       location: "magnifical:import:begin st.", organizer: nil,
                                       attendees: [], description: nil)
        // Exactly one begin and one end marker — the smuggled ones were defused.
        XCTAssertEqual(block.components(separatedBy: ":import:begin").count, 2)
        XCTAssertEqual(block.components(separatedBy: ":import:end").count, 2)
        XCTAssertFalse(block.contains("libirabu:import:"))
    }
}
