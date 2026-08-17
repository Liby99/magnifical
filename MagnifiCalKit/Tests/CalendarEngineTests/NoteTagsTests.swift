// Tags are markdown (2026-08): #tokens in the note are the source of truth, rich.tags is a
// cache. Under test: the whole-note parser (headers/fences/links excluded), the setNotes
// cache sync, the UI-era tags→markdown migration, and the imported "imported" tag preserve.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

@MainActor
final class NoteTagsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        redirectStoreToTemp()
    }

    override func tearDown() {
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    func testNoteTagsGrammar() {
        XCTAssertEqual(TodoIndex.noteTags("plan #work then #life-stuff and #a_b2"),
                       ["work", "life-stuff", "a_b2"])
        XCTAssertEqual(TodoIndex.noteTags("# Heading with space\n#realtag"), ["realtag"],
                       "a space after # makes a heading, not a tag")
        XCTAssertEqual(TodoIndex.noteTags("see https://x.com/#frag and [l](https://y.com/#a)"), [],
                       "link fragments never tokenize")
        XCTAssertEqual(TodoIndex.noteTags("```\n#include <x>\n```\n#code"), ["code"],
                       "fenced code doesn't tokenize")
        XCTAssertEqual(TodoIndex.noteTags("#Work again #work"), ["Work"],
                       "case-insensitive dedupe keeps first-seen casing")
        XCTAssertEqual(TodoIndex.noteTags("- [ ] ship it #apollo due:2026-09-01"), ["apollo"],
                       "todo-line tags count too — one grammar everywhere")
    }

    func testSetNotesSyncsTagCache() {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: e.year, month: 5, day: 10, startHour: 9, endHour: 10,
                                    title: "T", color: "blue")
        e.setNotes(id, "prep #alpha and #beta")
        e.flushTagCacheSync() // typing is debounced — the cache settles after the burst
        XCTAssertEqual(e.richTags(id), ["alpha", "beta"])
        e.setNotes(id, "prep #beta only") // removing a token removes the tag
        e.flushTagCacheSync()
        XCTAssertEqual(e.richTags(id), ["beta"])
    }

    func testLegacyTagsMigrateIntoNotes() {
        let e = CalendarEngine()
        let id = e.createTimedEvent(year: e.year, month: 5, day: 11, startHour: 9, endHour: 10,
                                    title: "Legacy", color: "blue")
        // Simulate a UI-era store: tags in the field, not in the note (incl. an illegal-char tag).
        e.items.richById[id] = RichFields(notes: "old note", tags: ["work", "My Tag"])
        e.persistNow()
        e.restoreItemsFromStore() // load runs the migration
        let notes = e.notes(id)
        XCTAssertTrue(notes.contains("#work"), "UI-era tag lands in the note as a token")
        XCTAssertTrue(notes.contains("#My-Tag"), "illegal characters collapse to '-'")
        XCTAssertEqual(Set(e.richTags(id)), Set(["work", "My-Tag"]), "cache recomputed from the note")

        e.persistNow()
        e.restoreItemsFromStore() // idempotent: a second load appends nothing
        XCTAssertEqual(e.notes(id), notes)
    }

    func testImportedTagPreservedWithoutPollutingNotes() {
        let e = CalendarEngine()
        let series = "gcal-k9-uid7"
        e.items.richById[series] = RichFields(notes: "<!-- libirabu:import:begin -->\nimported from: Google Calendar feed\n<!-- libirabu:import:end -->",
                                              tags: ["imported"], source: "ical")
        e.migrateTagsIntoNotes()
        XCTAssertFalse(e.items.richById[series]!.notes!.contains("#imported"),
                       "the system tag never becomes note text")
        XCTAssertEqual(e.items.richById[series]!.tags, ["imported"],
                       "…but survives in the cache for the tag filter")
        // A user-typed tag in the postfix joins the cache alongside it.
        var rf = e.items.richById[series]!
        rf.notes = rf.notes! + "\nmy remark #conf"
        e.items.richById[series] = rf
        e.syncTagCache(series)
        XCTAssertEqual(Set(e.items.richById[series]!.tags), Set(["conf", "imported"]))
    }
}
