@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class ICSFeedTests: XCTestCase {
    private let feed = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:standup@google.com
    DTSTART:20260706T090000
    DTEND:20260706T093000
    RRULE:FREQ=WEEKLY;COUNT=4
    EXDATE:20260720T090000
    SUMMARY:Standup
    END:VEVENT
    BEGIN:VEVENT
    UID:offsite@google.com
    DTSTART;VALUE=DATE:20260710
    DTEND;VALUE=DATE:20260712
    SUMMARY:Offsite
    END:VEVENT
    END:VCALENDAR
    """

    /// Weekly COUNT=4 minus one EXDATE → 3 occurrences with stable, per-occurrence ids sharing
    /// one series key; the all-day VEVENT becomes a 2-day band (exclusive DTEND).
    func testFeedExpansionAndStableIds() {
        let a = ICSImport.feedItems(from: feed, feedKey: "abc123", years: 2025 ... 2027)
        XCTAssertEqual(a.events.count, 3, "Jul 6, 13, 27 (20th EXDATEd)")
        let days = a.events.map(\.day).sorted()
        XCTAssertEqual(days, [6, 13, 27])
        XCTAssertTrue(a.events.allSatisfy { $0.month == 6 }, "July, 0-based")
        let series = Set(a.events.map { CalendarEngine.appleSeriesKey($0.id) })
        XCTAssertEqual(series, ["gcal-abc123-standup@google.com"], "occurrence suffix strips to one series")
        XCTAssertEqual(a.bands.count, 1)
        XCTAssertEqual(a.bands[0].startDay, 10)
        XCTAssertEqual(a.bands[0].endDay, 11, "DTEND is exclusive")

        // Refetch → identical ids (stability is what makes hide/color overlays survive refreshes).
        let b = ICSImport.feedItems(from: feed, feedKey: "abc123", years: 2025 ... 2027)
        XCTAssertEqual(Set(a.events.map(\.id)), Set(b.events.map(\.id)))
    }

    /// A feed's vendor details (location / organizer / attendees / description) reach the drawer
    /// as a managed-note block — REFRESHED on every fetch and composed with user edits, exactly
    /// like the Apple import. Regression: the old first-write-wins merge left any series with a
    /// pre-existing overlay (color, promote, an older fetch) permanently without its sections.
    func testFeedManagedNoteRefreshesIntoExistingOverlays() throws {
        redirectStoreToTemp()
        defer { unsetenv("CC_DEMO_DATADIR") }
        let detailed = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:mtg1@google.com
        DTSTART:20260810T100000
        DTEND:20260810T110000
        SUMMARY:Design Review
        LOCATION:Room 42
        ORGANIZER;CN=Alice:mailto:alice@x.com
        DESCRIPTION:Agenda
        END:VEVENT
        END:VCALENDAR
        """
        let parsed = ICSImport.feedItems(from: detailed, feedKey: "k1", years: 2025 ... 2027)
        let series = "gcal-k1-mtg1@google.com"
        let e = CalendarEngine()
        // The series ALREADY has a user overlay (a color + their own note) — the old merge skipped it.
        e.items.richById[series] = RichFields(notes: "my own remark", colorOverride: "blue")
        e.mergeFeed(key: "k1", events: parsed.events, bands: parsed.bands,
                    rich: parsed.rich, uids: parsed.uids)

        let occId = try XCTUnwrap(parsed.events.first?.id)
        let notes = e.notes(occId) // the drawer's accessor (overlayKey → series)
        XCTAssertTrue(notes.contains("location: Room 42"), "vendor sections land despite the overlay")
        XCTAssertTrue(notes.contains("my own remark"), "the user's own note text survives")
        XCTAssertEqual(e.colorOverride(occId), "blue", "user overlays survive the refetch")
    }

    /// X-WR-CALNAME (the calendar's own display name on Google secret feeds) is captured for the
    /// Settings feed rows; absent → nil.
    func testFeedCalendarName() {
        let named = "BEGIN:VCALENDAR\nX-WR-CALNAME:Team Standups\\, etc.\nBEGIN:VEVENT\nEND:VEVENT\nEND:VCALENDAR"
        XCTAssertEqual(ICSImport.feedCalendarName(from: named), "Team Standups, etc.")
        XCTAssertNil(ICSImport.feedCalendarName(from: feed), "no X-WR-CALNAME header → nil")
    }

    /// The parser records each series' RAW UID — the id's uid part is sanitized, and the raw one
    /// is what the Google "Edit original" deep link needs.
    func testFeedCapturesRawUids() {
        let a = ICSImport.feedItems(from: feed, feedKey: "abc123", years: 2025 ... 2027)
        XCTAssertEqual(a.uids["gcal-abc123-standup@google.com"], "standup@google.com")
        XCTAssertEqual(a.uids["gcal-abc123-offsite@google.com"], "offsite@google.com")
    }

    /// Drawer provenance: a gcal box from a Google secret feed labels "Google Calendar" and gets a
    /// constructed Google web deep link (eid = base64url("<uid-local> <calendarId>")); an apple box
    /// stays "Apple Calendar".
    func testImportedProvenance() throws {
        redirectStoreToTemp()
        defer { unsetenv("CC_DEMO_DATADIR") }
        let e = CalendarEngine()
        let feedURL = "https://calendar.google.com/calendar/ical/someone%40gmail.com/private-abc/basic.ics"
        let key = ICSFeedKey.feedKey(feedURL)
        e.icsFeedByKey[key] = feedURL
        e.imported.gcalUids["gcal-\(key)-standup@google.com"] = "standup@google.com"

        let p = try XCTUnwrap(e.importedProvenance("gcal-\(key)-standup@google.com-20260706-0900"))
        XCTAssertEqual(p.label, "Google Calendar")
        let url = try XCTUnwrap(p.editURL).absoluteString
        let eid = try XCTUnwrap(url.components(separatedBy: "eid=").last)
        XCTAssertTrue(url.hasPrefix("https://calendar.google.com/calendar/event?eid="))
        var b64 = eid.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 {
            b64 += "="
        }
        let decoded = String(data: try XCTUnwrap(Data(base64Encoded: b64)), encoding: .utf8)
        XCTAssertEqual(decoded, "standup someone@gmail.com", "uid local part + decoded calendar id")

        XCTAssertEqual(e.importedProvenance("apple-uid1-20260706-0900")?.label, "Apple Calendar")
        XCTAssertNil(e.importedProvenance("new-123"), "editable items have no imported provenance")

        // An Outlook published feed: labeled as such, but NO Edit-original link (its ICS UIDs
        // aren't derivable into web-app event URLs the way Google's eid is).
        let outlookURL = "https://outlook.live.com/owa/calendar/abc/def/calendar.ics"
        let oKey = ICSFeedKey.feedKey(outlookURL)
        e.icsFeedByKey[oKey] = outlookURL
        e.imported.gcalUids["gcal-\(oKey)-uid9"] = "uid9"
        let op = try XCTUnwrap(e.importedProvenance("gcal-\(oKey)-uid9-20260706-0900"))
        XCTAssertEqual(op.label, "Outlook Calendar")
        XCTAssertNil(op.editURL)
    }

    /// Provider recognition from a feed URL's host — drives banner labels + Settings rows.
    func testFeedProviderLabels() {
        XCTAssertEqual(ICSFeedProvider.label(forURL: "https://calendar.google.com/calendar/ical/a/private-b/basic.ics"),
                       "Google Calendar")
        XCTAssertEqual(ICSFeedProvider.label(forURL: "https://outlook.live.com/owa/calendar/a/b/calendar.ics"),
                       "Outlook Calendar")
        XCTAssertEqual(ICSFeedProvider.label(forURL: "https://outlook.office365.com/owa/calendar/x@t/y/calendar.ics"),
                       "Outlook Calendar")
        XCTAssertEqual(ICSFeedProvider.label(forURL: "https://example.org/team.ics"), "Calendar Feed")
        XCTAssertEqual(ICSFeedProvider.label(forURL: nil), "Calendar Feed")
    }

    /// Feed ids count as imported (read-only) and the series key carries the user overlays.
    func testFeedIdsAreImported() {
        let e = CalendarEngine()
        XCTAssertTrue(e.isImported("gcal-abc123-standup@google.com-20260706-0900"))
        XCTAssertFalse(e.isImported("new-123"))
    }
}
