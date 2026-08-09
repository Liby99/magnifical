@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class ClipboardTests: XCTestCase {
    override func setUp() {
        super.setUp(); redirectStoreToTemp()
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR"); super.tearDown()
    }

    /// Cut is only allowed on a base/source box that isn't imported — not on a ghost occurrence, a
    /// promoted mirror, or a read-only imported event.
    func testCutEligibleRules() {
        let e = CalendarEngine()
        XCTAssertTrue(e.cutEligible("new-abc")) // a plain base box
        XCTAssertFalse(e.cutEligible("new-abc@2026-6-20")) // a recurrence occurrence ghost
        XCTAssertFalse(e.cutEligible("new-abc@2026-6-20~p")) // a promoted mirror
        XCTAssertFalse(e.cutEligible("apple-uid-20260101")) // imported (read-only)
    }

    /// Copy carries only title/color/notes/tags (reduced); cut carries the full move (repeat + promotion).
    func testClipPayloadReducedVsFull() throws {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: e.year, month: 6, day: 20, startHour: 9, endHour: 11,
                                    title: "Standup", color: "blue", notes: "daily", tags: ["work"], promoteTrack: 2)
        e.setRepeat(id, Repeat(kind: "weekly", until: "2026-08-01"))

        let copy = try XCTUnwrap(e.clipPayload(of: id, full: false))
        XCTAssertEqual(copy.title, "Standup"); XCTAssertEqual(copy.color, "blue")
        XCTAssertEqual(copy.notes, "daily"); XCTAssertEqual(copy.tags, ["work"])
        XCTAssertEqual(Double(copy.durationHours), 2, accuracy: 0.001)
        XCTAssertNil(copy.move) // repeat + promotion dropped for a plain copy

        let cut = try XCTUnwrap(e.clipPayload(of: id, full: true))
        XCTAssertEqual(cut.move?.promoteTrack, 2)
        XCTAssertNotNil(cut.move?.repeatJSON)
    }

    /// A plain copy pasted → a single isolated band (no recurrence, no promotion), length preserved.
    func testCopyPasteIsSingleEvent() throws {
        let e = CalendarEngine()
        let id = e.createBand(year: e.year, month: 6, track: 0, startDay: 10, endDay: 12, title: "Conf", color: "green")
        e.setRepeat(id, Repeat(kind: "weekly"))
        let clip = try XCTUnwrap(e.clipPayload(of: id, full: false))
        e.cursor.keyboardActive = true; e.cursor.bandCursorActive = true
        e.cursor.blockMonth = 6; e.cursor.bandCurTrack = 1; e.cursor.blockDay = 20
        let newId = try XCTUnwrap(e.paste(clip))
        let nb = try XCTUnwrap(e.band(newId))
        XCTAssertEqual(nb.endDay - nb.startDay, 2) // length preserved
        XCTAssertNil(e.repeatConfig(newId)) // recurrence dropped
    }

    /// A cut pasted → a full move: recurrence and per-occurrence notes are carried, with their dates
    /// shifted by the move's day offset ("preserving offset").
    func testCutPastePreservesOffset() throws {
        let e = CalendarEngine()
        let id = e.createBand(year: e.year, month: 6, track: 0, startDay: 10, endDay: 12, title: "Conf", color: "green")
        e.setRepeat(id, Repeat(kind: "weekly", until: "2026-08-01"))
        let occKeyOrig = occKey(id, YMD(e.year, 6, 17))
        e.setOccNote(id, occKeyOrig, "note17")

        let clip = try XCTUnwrap(e.clipPayload(of: id, full: true))
        e.cursor.keyboardActive = true; e.cursor.bandCursorActive = true
        e.cursor.blockMonth = 6; e.cursor.bandCurTrack = 1; e.cursor.blockDay = 24
        let newId = try XCTUnwrap(e.paste(clip))
        let nb = try XCTUnwrap(e.band(newId))

        // Whatever the drop resolved to, the recurrence `until` and the occurrence-note date shift by the
        // SAME whole-day delta from the original base.
        let delta = e.dayDiff(e.year, 6, 10, nb.year, nb.month, nb.startDay)
        let u = e.repeatConfig(newId)?.until?.split(separator: "-").compactMap { Int($0) }
        let expUntil = e.addDays(2026, 7, 1, delta) // "2026-08-01" is Aug (0-based month 7)
        XCTAssertEqual(u ?? [], [expUntil.0, expUntil.1 + 1, expUntil.2])
        let od = e.addDays(e.year, 6, 17, delta)
        XCTAssertEqual(e.occNote(newId, "\(newId)@\(od.0)-\(od.1)-\(od.2)"), "note17")
    }

    /// Pasting raw `.ics` text imports it (the ⌘V-as-import path feeds this).
    func testICSTextImport() throws {
        let e = CalendarEngine()
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Pasted Meeting
        DTSTART:20260720T090000
        DTEND:20260720T100000
        END:VEVENT
        END:VCALENDAR
        """
        let n = try e.importICS(text: ics, provenance: "Clipboard")
        XCTAssertEqual(n, 1)
        XCTAssertTrue(e.displayEvents(for: 2026).contains { $0.title == "Pasted Meeting" })
    }
}
