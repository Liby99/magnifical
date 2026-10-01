// Attachment sync (P2, design §6): the delta layer derives NoteFile records from the notes
// themselves — a hash newly referenced by this calendar's notes upserts `file-<sha256>`, the
// last reference leaving deletes it — and inbound assets adopt into the CAS only when their
// payload hash-verifies against the record's declared sha256.

@testable import CalendarEngine
import CryptoKit
import XCTest

@MainActor
final class AttachmentSyncTests: XCTestCase {
    override func setUp() { super.setUp(); redirectStoreToTemp() }
    override func tearDown() { unsetenv("CC_DEMO_DATADIR"); super.tearDown() }

    func testAttachmentIdsScansEveryNoteSurface() throws {
        let t1 = AttachmentToken(kind: .file, name: "a", id: "aaaaaaaaaaaaaaaa")
        let t2 = AttachmentToken(kind: .file, name: "b", id: "bbbbbbbbbbbbbbbb")
        let t3 = AttachmentToken(kind: .file, name: "c", id: "cccccccccccccccc")
        let state = PersistedState(
            events: [], bands: [], deadlines: [],
            rich: ["e1": RichFields(notes: "x\n\(t1.markdown)",
                                    occurrenceNotes: ["2026-07-01": t2.markdown])],
            dailyNotes: ["week:2026-06-28": "y \(t3.markdown) z"]
        )
        XCTAssertEqual(CalendarEngine.attachmentIds(in: state),
                       ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "cccccccccccccccc"])
    }

    func testDeltaEmitsNoteFileUpsertAndDelete() throws {
        let e = CalendarEngine()
        var upserts: [String] = [], deletes: [String] = []
        e.onLocalChange = { up, del in
            upserts += up
            deletes += del
        }
        let token = try e.attachments.importData(Data("sync me".utf8), suggestedName: "s.txt")
        let full = try XCTUnwrap(e.attachments.resolveHash(forId: token.id))

        e.setDailyNote("2026-06-02", "hello\n\(token.markdown)")
        e.persistNow()
        XCTAssertTrue(upserts.contains("file-\(full)"),
                      "first reference in this calendar uploads the blob record")

        e.setDailyNote("2026-06-02", "hello") // last reference gone
        e.persistNow()
        XCTAssertTrue(deletes.contains("file-\(full)"),
                      "last reference leaving deletes this calendar's record")
    }

    func testDeltaKeepsRecordWhileAnotherNoteStillRefers() throws {
        let e = CalendarEngine()
        var deletes: [String] = []
        e.onLocalChange = { _, del in deletes += del }
        let token = try e.attachments.importData(Data("shared".utf8), suggestedName: "sh.txt")
        let full = try XCTUnwrap(e.attachments.resolveHash(forId: token.id))
        e.setDailyNote("2026-06-02", token.markdown)
        e.setDailyNote("2026-06-03", token.markdown)
        e.persistNow()
        e.setDailyNote("2026-06-02", "") // one of two references leaves
        e.persistNow()
        XCTAssertFalse(deletes.contains("file-\(full)"),
                       "still referenced by the other note → record stays")
    }

    func testInventoryJoinsRefsOrphansAndGhosts() throws {
        let e = CalendarEngine()
        // A blob referenced twice (event note + daily note), an orphan blob, a ghost token.
        let used = try e.attachments.importData(Data("used".utf8), suggestedName: "used.txt")
        _ = try e.attachments.importData(Data("orphan".utf8), suggestedName: "orphan.txt")
        let evId = e.createTimedEvent(year: e.year, month: 6, day: 2, startHour: 9, endHour: 10,
                                      title: "Standup", color: "blue")
        e.setNotes(evId, "prep:\n\(used.markdown)")
        e.setDailyNote("2026-06-02", used.markdown)
        e.setDailyNote("2026-06-03", "![@pdf:ghost.pdf](ccfile:00ff00ff00ff00ff)")
        let rows = e.attachmentInventory()

        let usedRow = try XCTUnwrap(rows.first { $0.name == "used.txt" })
        XCTAssertEqual(usedRow.refs.count, 2)
        XCTAssertTrue(usedRow.refs.contains { $0.label == "Event “Standup”" }, "\(usedRow.refs)")
        XCTAssertTrue(usedRow.refs.contains { $0.label == "Daily note 2026-06-02" })
        XCTAssertNotNil(usedRow.meta)
        // Navigation targets: the browser's "show in calendar" jumps run off these.
        XCTAssertTrue(usedRow.refs.contains {
            $0.target == .item(id: evId, occurrence: nil) && $0.inActiveCalendar
        })
        XCTAssertTrue(usedRow.refs.contains { $0.target == .note(key: "2026-06-02") })

        let orphanRow = try XCTUnwrap(rows.first { $0.name == "orphan.txt" })
        XCTAssertTrue(orphanRow.refs.isEmpty, "unreferenced blob surfaces as an orphan")

        let ghostRow = try XCTUnwrap(rows.first { $0.name == "ghost.pdf" })
        XCTAssertNil(ghostRow.meta, "referenced but blob absent → the waiting/ghost row")
        XCTAssertEqual(ghostRow.refs.first?.label, "Daily note 2026-06-03")

        XCTAssertEqual(rows.first?.name, "used.txt", "most-referenced sorts first")
    }

    func testAdoptRemoteVerifiesTheHash() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AttachmentStore(baseDir: dir)
        let payload = Data("remote bytes".utf8)
        let asset = dir.appendingPathComponent("asset.bin")
        try payload.write(to: asset)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let gen0 = store.generation
        XCTAssertTrue(store.adoptRemote(fileURL: asset, declaredHash: hash,
                                        name: "r.txt", uti: "public.plain-text"))
        XCTAssertGreaterThan(store.generation, gen0, "arrival bumps the repaint generation")
        let url = try XCTUnwrap(store.url(forId: String(hash.prefix(16))))
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(store.adoptRemote(fileURL: asset, declaredHash: hash,
                                        name: "r.txt", uti: "public.plain-text"),
                      "re-adopting an already-present blob is a cheap true")

        // A tampered/corrupt payload must never enter the CAS.
        let evil = dir.appendingPathComponent("evil.bin")
        try Data("not the bytes".utf8).write(to: evil)
        XCTAssertFalse(store.adoptRemote(fileURL: evil, declaredHash: hash.replacingOccurrences(of: hash.prefix(4), with: "0000"),
                                         name: "x", uti: "public.data"))
    }
}
