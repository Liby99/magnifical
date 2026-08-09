@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class ImportExportTests: XCTestCase {

    private func sampleState() -> PersistedState {
        let events = [TimedEvent(
            id: "t1",
            year: 2026,
            month: 6,
            day: 20,
            startHour: 9,
            endHour: 10.5,
            title: "Standup",
            color: "blue",
            anchorTz: "America/New_York"
        )]
        let bands = [BandEvent(
            id: "b1",
            year: 2026,
            month: 6,
            track: 2,
            startDay: 20,
            endDay: 22,
            title: "Conf",
            color: "green"
        )]
        let deadlines = [Deadline(
            id: "d1",
            year: 2026,
            month: 6,
            day: 25,
            hour: 17,
            title: "CFP",
            color: "red",
            originTz: "AOE",
            anchorTz: "AOE"
        )]
        let rich: [String: RichFields] = [
            "t1": RichFields(notes: "hello", tags: ["work"], source: "manual"),
            "b1": RichFields(tags: ["imported"], source: "ical", hidden: true),
        ]
        return PersistedState(events: events, bands: bands, deadlines: deadlines,
                              monthTrackNames: nil, rich: rich, dailyNotes: ["2026-07-20": "note body"])
    }

    /// encode → decode reproduces every calendar item field exactly (the UTC wall-clock date math).
    func testCodecRoundTrip() throws {
        let s = sampleState()
        let files = try MDCBackup.encode(s, exportedAt: Date())
        let back = try MDCBackup.decode(files)

        XCTAssertEqual(back.events, s.events)
        XCTAssertEqual(back.bands, s.bands)
        XCTAssertEqual(back.deadlines, s.deadlines)
        XCTAssertEqual(back.events.first?.anchorTz, "America/New_York") // timezone anchor survives the .mdc round-trip
        XCTAssertEqual(back.deadlines.first?.anchorTz, "AOE")
        XCTAssertEqual(back.dailyNotes, s.dailyNotes)
        XCTAssertEqual(back.rich?["t1"]?.notes, "hello")
        XCTAssertEqual(back.rich?["t1"]?.tags, ["work"])
        XCTAssertEqual(back.rich?["b1"]?.source, "ical")
        XCTAssertEqual(back.rich?["b1"]?.hidden, true)
    }

    /// manifest.json declares the web interchange id, so the web importer accepts a native .mdc.
    func testManifestShape() throws {
        let files = try MDCBackup.encode(sampleState(), exportedAt: Date())
        let m = try JSONSerialization.jsonObject(with: XCTUnwrap(files["manifest.json"])) as? [String: Any]
        XCTAssertEqual(m?["app"] as? String, "libirabu")
        XCTAssertEqual(m?["format"] as? Int, 1)
    }

    /// Full trip through the real zip container (Process → /usr/bin/zip + unzip) and the engine API.
    func testEngineZipRoundTrip() throws {
        let e = CalendarEngine()
        e.replaceAll(sampleState())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).mdc")
        defer { try? FileManager.default.removeItem(at: url) }
        try e.exportMDC(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let e2 = CalendarEngine()
        try e2.importMDC(from: url)
        let out = e2.exportState()
        XCTAssertEqual(Set(out.events.map(\.id)), ["t1"])
        XCTAssertEqual(out.events.first?.startHour, 9)
        XCTAssertEqual(out.events.first?.endHour, 10.5)
        XCTAssertEqual(out.bands.first?.startDay, 20)
        XCTAssertEqual(out.bands.first?.endDay, 22)
        XCTAssertEqual(out.deadlines.first?.hour, 17)
    }

    /// .ics: all-day → band (exclusive DTEND → inclusive last day); timed same-day → timed event.
    func testICSParse() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:a@x
        SUMMARY:Conference
        DTSTART;VALUE=DATE:20260720
        DTEND;VALUE=DATE:20260723
        END:VEVENT
        BEGIN:VEVENT
        UID:b@x
        SUMMARY:Standup
        DTSTART:20260720T090000
        DTEND:20260720T093000
        LOCATION:Room 5
        END:VEVENT
        END:VCALENDAR
        """
        let (events, bands, rich) = ICSImport.items(from: ics, provenance: "test.ics")
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands.first?.startDay, 20)
        XCTAssertEqual(bands.first?.endDay, 22) // DTEND 23 exclusive → 22 inclusive
        XCTAssertEqual(bands.first?.title, "Conference")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.day, 20)
        XCTAssertEqual(events.first?.startHour, 9) // floating (no Z/TZID) → wall clock as-is
        XCTAssertEqual(events.first?.endHour, 9.5)
        // vendor LOCATION lands in the managed-note block.
        XCTAssertEqual(try rich[XCTUnwrap(events.first?.id)]?.notes?.contains("Room 5"), true)
        XCTAssertEqual(try rich[XCTUnwrap(events.first?.id)]?.source, "ical")
    }
}
