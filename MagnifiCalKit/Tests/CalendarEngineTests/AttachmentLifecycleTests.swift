// Attachment lifecycle (P3, design §7–8): the sweep deletes only at the intersection of
// UNREFERENCED and PAST THE 7-DAY GRACE (sightings refresh the clock; a young orphan and an
// unparseable stamp both survive), and the `.mgc` backup carries the referenced blobs both
// ways — export packs `files/<sha256>.<ext>` + `attachment` rows, import hash-verifies each
// payload back into the CAS, and a legacy backup without `files/` still imports cleanly.

@testable import CalendarEngine
import CryptoKit
import XCTest

@MainActor
final class AttachmentLifecycleTests: XCTestCase {
    override func setUp() { super.setUp(); redirectStoreToTemp() }
    override func tearDown() { unsetenv("CC_DEMO_DATADIR"); super.tearDown() }

    // ── The sweep ─────────────────────────────────────────────────────────────────────

    func testSweepReclaimsOldOrphansAndRefreshesSightings() throws {
        let e = CalendarEngine()
        let kept = try e.attachments.importData(Data("kept".utf8), suggestedName: "kept.txt")
        let orphan = try e.attachments.importData(Data("orphan".utf8), suggestedName: "orphan.txt")
        e.setDailyNote("2026-06-02", kept.markdown)
        let keptHash = try XCTUnwrap(e.attachments.resolveHash(forId: kept.id))
        let orphanHash = try XCTUnwrap(e.attachments.resolveHash(forId: orphan.id))
        // Backdate BOTH past the grace window; only the unreferenced one may die.
        let old = Date().addingTimeInterval(-8 * 24 * 3600)
        e.attachments.touch(hashes: [keptHash, orphanHash], at: old)

        let now = Date()
        let r = e.sweepAttachments(now: now)
        XCTAssertEqual(r, AttachmentSweepResult(swept: 1, sweptBytes: 6, inGrace: 0, referenced: 1))
        XCTAssertNil(e.attachments.url(forId: orphan.id), "old orphan reclaimed")
        XCTAssertNotNil(e.attachments.url(forId: kept.id), "referenced blob survives any age")
        XCTAssertEqual(e.attachments.meta(forId: kept.id)?.lastReferencedAt,
                       AttachmentStore.stamp(now), "a sighting restarts the grace clock")
    }

    func testSweepSparesYoungOrphans() throws {
        let e = CalendarEngine()
        let orphan = try e.attachments.importData(Data("young".utf8), suggestedName: "young.txt")
        let r = e.sweepAttachments() // imported seconds ago → inside grace
        XCTAssertEqual(r.swept, 0)
        XCTAssertEqual(r.inGrace, 1)
        XCTAssertNotNil(e.attachments.url(forId: orphan.id))
    }

    func testSweepIgnoresGhostsAndBadStamps() throws {
        let e = CalendarEngine()
        // A ghost (token, no local blob) must never crash or count as sweepable.
        e.setDailyNote("2026-06-03", "![@pdf:ghost.pdf](ccfile:00ff00ff00ff00ff)")
        // An orphan whose stamp got corrupted: parse fails → treated as young, NEVER deleted.
        let odd = try e.attachments.importData(Data("odd".utf8), suggestedName: "odd.txt")
        let hash = try XCTUnwrap(e.attachments.resolveHash(forId: odd.id))
        e.attachments.corruptStampForTesting(hash: hash)
        let r = e.sweepAttachments(now: Date().addingTimeInterval(365 * 24 * 3600))
        XCTAssertEqual(r.swept, 0, "unparseable stamp must fail safe")
        XCTAssertEqual(r.inGrace, 1)
        XCTAssertNotNil(e.attachments.url(forId: odd.id))
    }

    // ── Backup round-trip ─────────────────────────────────────────────────────────────

    func testBackupCarriesAttachmentsBothWays() throws {
        let e = CalendarEngine()
        let token = try e.attachments.importData(Data("precious bytes".utf8),
                                                 suggestedName: "precious.txt")
        let hash = try XCTUnwrap(e.attachments.resolveHash(forId: token.id))
        e.setDailyNote("2026-06-02", "keep:\n\(token.markdown)")
        let evId = e.createTimedEvent(year: e.year, month: 6, day: 2, startHour: 9, endHour: 10,
                                      title: "Standup", color: "blue")
        e.setNotes(evId, token.markdown)
        // An orphan does NOT ride along — backups carry what the notes reference.
        _ = try e.attachments.importData(Data("orphan".utf8), suggestedName: "orphan.txt")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bk-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        try e.exportMDC(to: url)

        // The zip layout matches the web contract: one files/ entry + one attachment row.
        let files = try Zipper.read(url)
        let ext = (token.name as NSString).pathExtension
        XCTAssertNotNil(files["files/\(hash).\(ext)"], "\(files.keys.sorted())")
        let db = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: XCTUnwrap(files["database.json"])) as? [String: Any])
        let rows = try XCTUnwrap(db["attachment"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1, "referenced blob only — the orphan stays home")
        XCTAssertEqual(rows.first?["sha256"] as? String, hash)
        XCTAssertEqual(rows.first?["filename"] as? String, "precious.txt")

        // Wipe the blob locally, then restore: the note AND the payload come back verified.
        e.attachments.remove(hash: hash)
        XCTAssertNil(e.attachments.url(forId: token.id))
        try e.importMDC(from: url)
        XCTAssertNotNil(e.attachments.url(forId: token.id), "payload landed back in the CAS")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(e.attachments.url(forId: token.id))),
                       Data("precious bytes".utf8))
        XCTAssertTrue(e.items.dailyNotes["2026-06-02"]?.contains(token.markdown) == true)
    }

    func testLegacyBackupWithoutFilesImportsCleanly() throws {
        let e = CalendarEngine()
        e.setDailyNote("2026-06-02", "plain old note")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        // encode() with no attachments = exactly the pre-P3 layout (files: 0, empty table).
        try Zipper.write(MDCBackup.encode(e.exportState(), exportedAt: Date()), to: url)
        try e.importMDC(from: url)
        XCTAssertEqual(e.items.dailyNotes["2026-06-02"], "plain old note")
        XCTAssertTrue(MDCBackup.decodeAttachments(try Zipper.read(url)).isEmpty)
    }

    func testTamperedBackupPayloadIsRejected() throws {
        let e = CalendarEngine()
        XCTAssertFalse(e.attachments.adoptData(Data("not the bytes".utf8),
                                               declaredHash: String(repeating: "ab", count: 32),
                                               name: "evil.txt", uti: "public.plain-text"),
                       "a payload that doesn't hash to its declaration never enters the CAS")
        XCTAssertTrue(e.attachments.allEntries().isEmpty)
    }

    // ── Sweep: boundaries and reference surfaces ─────────────────────────────────────

    func testSweepGraceBoundaryIsExact() throws {
        let e = CalendarEngine()
        let young = try e.attachments.importData(Data("young".utf8), suggestedName: "y.txt")
        let old = try e.attachments.importData(Data("old".utf8), suggestedName: "o.txt")
        let grace = CalendarEngine.attachmentSweepGrace
        let now = Date()
        // Two minutes INSIDE the window vs two minutes past it (the stamp has minute
        // precision, so a ±2min margin is the tightest honest boundary probe).
        e.attachments.touch(hashes: [e.attachments.resolveHash(forId: young.id)!],
                            at: now.addingTimeInterval(-grace + 120))
        e.attachments.touch(hashes: [e.attachments.resolveHash(forId: old.id)!],
                            at: now.addingTimeInterval(-grace - 120))
        let r = e.sweepAttachments(now: now)
        XCTAssertEqual(r.swept, 1)
        XCTAssertEqual(r.inGrace, 1)
        XCTAssertNotNil(e.attachments.url(forId: young.id), "inside grace survives")
        XCTAssertNil(e.attachments.url(forId: old.id), "past grace is reclaimed")
    }

    func testEveryNoteSurfaceProtectsFromTheSweep() throws {
        // One blob per reference surface: base event note, occurrence note, weekly note,
        // monthly note — each alone must count as a sighting.
        let e = CalendarEngine()
        let evId = e.createTimedEvent(year: e.year, month: 6, day: 2, startHour: 9, endHour: 10,
                                      title: "Recurring", color: "blue")
        var hashes: [String] = []
        let surfaces: [(String, (AttachmentToken) -> Void)] = [
            ("base.txt", { e.setNotes(evId, $0.markdown) }),
            ("occ.txt", { e.setOccNote(evId, "2026-07-01", $0.markdown) }),
            ("week.txt", { e.setDailyNote("week:2026-06-28", $0.markdown) }),
            ("month.txt", { e.setDailyNote("month:2026-06", $0.markdown) }),
        ]
        for (name, place) in surfaces {
            let t = try e.attachments.importData(Data(name.utf8), suggestedName: name)
            place(t)
            hashes.append(e.attachments.resolveHash(forId: t.id)!)
        }
        e.attachments.touch(hashes: Set(hashes), at: Date().addingTimeInterval(-30 * 24 * 3600))
        let now = Date()
        let r = e.sweepAttachments(now: now)
        XCTAssertEqual(r, AttachmentSweepResult(swept: 0, sweptBytes: 0, inGrace: 0,
                                                referenced: 4))
        for h in hashes {
            XCTAssertEqual(e.attachments.meta(forId: h)?.lastReferencedAt,
                           AttachmentStore.stamp(now), "every surface refreshes the clock")
        }
    }

    func testReferenceInAnotherCalendarProtectsFromTheSweep() throws {
        // The sweep must see ALL calendars — a blob only the non-active calendar's notes
        // reference is NOT an orphan. (Registry active-id/recents live in real defaults;
        // snapshot and restore them so the test never moves the user's active calendar.)
        let d = UserDefaults.standard
        let savedActive = d.object(forKey: PrefKeys.calActiveId)
        let savedRecents = d.object(forKey: PrefKeys.calRecents)
        defer {
            d.set(savedActive, forKey: PrefKeys.calActiveId)
            d.set(savedRecents, forKey: PrefKeys.calRecents)
        }
        let e = CalendarEngine()
        let mainId = e.registry.activeId
        let t = try e.attachments.importData(Data("cross-cal".utf8), suggestedName: "x.txt")
        let hash = try XCTUnwrap(e.attachments.resolveHash(forId: t.id))
        e.createCalendar(named: "Side") // switches into it
        e.setDailyNote("2026-06-02", t.markdown)
        e.switchCalendar(to: mainId) // persists Side's data.json on the way out
        XCTAssertTrue(e.items.dailyNotes.isEmpty, "back on Main, which has no notes")

        e.attachments.touch(hashes: [hash], at: Date().addingTimeInterval(-30 * 24 * 3600))
        let r = e.sweepAttachments()
        XCTAssertEqual(r.referenced, 1, "the Side calendar's note is a sighting")
        XCTAssertEqual(r.swept, 0)
        XCTAssertNotNil(e.attachments.url(forId: t.id))
    }

    func testAdoptedGhostJoinsTheSweepAccounting() throws {
        // A note references a token whose blob hasn't synced: the ghost is invisible to the
        // sweep. The blob adopting later turns it referenced — never sweepable in between.
        let e = CalendarEngine()
        let payload = Data("late arrival".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        e.setDailyNote("2026-06-02", "![@file:late.bin](ccfile:\(hash.prefix(16)))")

        var r = e.sweepAttachments(now: Date().addingTimeInterval(400 * 24 * 3600))
        XCTAssertEqual(r.swept + r.inGrace + r.referenced, 0, "a ghost is nothing to sweep")

        XCTAssertTrue(e.attachments.adoptData(payload, declaredHash: hash,
                                              name: "late.bin", uti: "public.data"))
        e.attachments.touch(hashes: [hash], at: Date().addingTimeInterval(-30 * 24 * 3600))
        r = e.sweepAttachments()
        XCTAssertEqual(r.referenced, 1, "adopted + referenced → sighted, clock refreshed")
        XCTAssertNotNil(e.attachments.url(forId: String(hash.prefix(16))))
    }

    func testSweepAccountingIsExhaustive() throws {
        let e = CalendarEngine()
        let ref = try e.attachments.importData(Data("ref".utf8), suggestedName: "r.txt")
        e.setDailyNote("2026-06-02", ref.markdown)
        let oldOrphan = try e.attachments.importData(Data("old".utf8), suggestedName: "o.txt")
        e.attachments.touch(hashes: [e.attachments.resolveHash(forId: oldOrphan.id)!],
                            at: Date().addingTimeInterval(-9 * 24 * 3600))
        _ = try e.attachments.importData(Data("new".utf8), suggestedName: "n.txt")
        e.setDailyNote("2026-06-03", "![@pdf:ghost.pdf](ccfile:00ff00ff00ff00ff)")

        let stored = e.attachments.allEntries().count
        let r = e.sweepAttachments()
        XCTAssertEqual(r.swept + r.inGrace + r.referenced, stored,
                       "every stored row lands in exactly one bucket (ghosts in none)")
        XCTAssertEqual(r, AttachmentSweepResult(swept: 1, sweptBytes: 3, inGrace: 1,
                                                referenced: 1))
    }

    // ── Backup: breadth, corruption, web interop ─────────────────────────────────────

    func testBackupRoundTripAcrossFamiliesAndSurfaces() throws {
        let e = CalendarEngine()
        let img = try e.attachments.importData(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]),
                                               suggestedName: "pic.png")
        let code = try e.attachments.importData(Data("fn main() {}".utf8),
                                                suggestedName: "main.rs")
        let sheet = try e.attachments.importData(Data("a,b\n1,2".utf8),
                                                 suggestedName: "t.csv")
        let evId = e.createTimedEvent(year: e.year, month: 6, day: 2, startHour: 9, endHour: 10,
                                      title: "Standup", color: "blue")
        e.setNotes(evId, img.markdown)
        e.setOccNote(evId, "2026-07-01", code.markdown)
        e.setDailyNote("week:2026-06-28", sheet.markdown)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bk-fam-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        try e.exportMDC(to: url)
        let files = try Zipper.read(url)
        XCTAssertEqual(files.keys.filter { $0.hasPrefix("files/") }.count, 3,
                       "every surface's reference rides along: \(files.keys.sorted())")

        for t in [img, code, sheet] {
            e.attachments.remove(hash: e.attachments.resolveHash(forId: t.id)!)
        }
        try e.importMDC(from: url)
        for (t, body) in [(img, Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])),
                          (code, Data("fn main() {}".utf8)), (sheet, Data("a,b\n1,2".utf8))] {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(e.attachments.url(forId: t.id))), body)
        }
        // Importing the same backup AGAIN is idempotent — dedup adopts, nothing doubles.
        try e.importMDC(from: url)
        XCTAssertEqual(e.attachments.allEntries().count, 3)
    }

    func testOneTamperedZipEntryDropsOnlyThatBlob() throws {
        let e = CalendarEngine()
        let good = try e.attachments.importData(Data("good bytes".utf8), suggestedName: "good.txt")
        let bad = try e.attachments.importData(Data("soon corrupted".utf8), suggestedName: "bad.txt")
        e.setDailyNote("2026-06-02", "\(good.markdown)\n\(bad.markdown)")
        let badHash = try XCTUnwrap(e.attachments.resolveHash(forId: bad.id))

        var files = try MDCBackup.encode(e.exportState(), exportedAt: Date(), attachments: [
            MDCBackup.FileEntry(hash: e.attachments.resolveHash(forId: good.id)!,
                                name: "good.txt", uti: "public.plain-text",
                                data: Data("good bytes".utf8)),
            MDCBackup.FileEntry(hash: badHash, name: "bad.txt", uti: "public.plain-text",
                                data: Data("soon corrupted".utf8)),
        ])
        files["files/\(badHash).txt"] = Data("TAMPERED".utf8) // the in-flight corruption
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bk-evil-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        try Zipper.write(files, to: url)

        for t in [good, bad] {
            e.attachments.remove(hash: e.attachments.resolveHash(forId: t.id)!)
        }
        try e.importMDC(from: url) // must not throw
        XCTAssertNotNil(e.attachments.url(forId: good.id), "the intact sibling still lands")
        XCTAssertNil(e.attachments.url(forId: bad.id),
                     "the tampered payload is dropped — its token shows the waiting card")
        XCTAssertTrue(e.items.dailyNotes["2026-06-02"]?.contains(bad.markdown) == true,
                      "the note itself is untouched; the reference can heal from the cloud")
    }

    func testWebStyleAttachmentRowsDecode() throws {
        // The web app's export has no `uti` — identity comes from `mime` (+ filename).
        let payload = Data("web export bytes".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let db: [String: Any] = ["attachment": [[
            "id": hash, "filename": "pic.png", "mime": "image/png", "bytes": payload.count,
            "sha256": hash, "storagePath": "\(hash).png",
            "createdAt": ["__bk": "date", "v": "2026-01-01T00:00:00.000Z"],
        ] as [String: Any]]]
        let files: [String: Data] = [
            "database.json": try JSONSerialization.data(withJSONObject: db),
            "files/\(hash).png": payload,
        ]
        let entries = MDCBackup.decodeAttachments(files)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.uti, "public.png", "mime maps to the UTI")
        XCTAssertEqual(entries.first?.name, "pic.png")
        let e = CalendarEngine()
        XCTAssertTrue(e.attachments.adoptData(entries[0].data, declaredHash: entries[0].hash,
                                              name: entries[0].name, uti: entries[0].uti))
    }

    func testExportSkipsGhostsAndRowsMissingPayloadsAreSkippedOnImport() throws {
        let e = CalendarEngine()
        // A ghost reference (blob never arrived) exports token-only — no files/ entry.
        e.setDailyNote("2026-06-02", "![@pdf:ghost.pdf](ccfile:00ff00ff00ff00ff)")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bk-ghost-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        try e.exportMDC(to: url)
        let files = try Zipper.read(url)
        XCTAssertTrue(files.keys.filter { $0.hasPrefix("files/") }.isEmpty)
        XCTAssertTrue(MDCBackup.decodeAttachments(files).isEmpty)

        // An attachment ROW whose files/ entry vanished: skipped, never a crash.
        var mutilated = files
        let db: [String: Any] = ["attachment": [[
            "id": "aa", "filename": "gone.bin", "mime": "application/octet-stream",
            "sha256": String(repeating: "aa", count: 32),
            "storagePath": "missing.bin",
        ] as [String: Any]]]
        mutilated["database.json"] = try JSONSerialization.data(withJSONObject: db)
        XCTAssertTrue(MDCBackup.decodeAttachments(mutilated).isEmpty)
    }
}
