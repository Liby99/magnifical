// Attachment IMPORT pipeline, driven by GENERATED payloads — real PNG/TIFF/JPEG rasters,
// a hand-rolled PDF, per-language sources — through every entry door: paste (importData),
// disk (importFile), sync/backup (adoptData). Pins the identity rules (SHA-256 dedup, the
// TIFF→PNG pre-hash normalization, magic-number sniffing for extension-less pastes), the
// token grammar under hostile names, prefix-collision id extension, and the generation
// (repaint) contract: bumps on ARRIVAL and REMOVAL, never on a touch.

import AppKit
@testable import CalendarEngine
import CryptoKit
import XCTest

@MainActor
final class AttachmentImportTests: XCTestCase {
    private var dir: URL!
    private var store: AttachmentStore!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attimp-\(UUID().uuidString)")
        store = AttachmentStore(baseDir: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // ── Payload generators ────────────────────────────────────────────────────────────

    private func raster(w: Int = 60, h: Int = 40) -> NSBitmapImageRep {
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            rect.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 8, dy: 6)).fill()
            return true
        }
        return NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    }

    private func png() -> Data { raster().representation(using: .png, properties: [:])! }
    private func tiff() -> Data { raster().representation(using: .tiff, properties: [:])! }
    private func jpeg() -> Data {
        raster().representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    private func pdf() -> Data {
        Data("""
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] >> endobj
        trailer << /Size 4 /Root 1 0 R >>
        %%EOF
        """.utf8)
    }

    private func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // ── The image family ──────────────────────────────────────────────────────────────

    func testGeneratedImagePayloadsImportWithCorrectIdentity() throws {
        for (data, name, wantUTI) in [(png(), "shot.png", "public.png"),
                                      (jpeg(), "photo.jpg", "public.jpeg")] {
            let t = try store.importData(data, suggestedName: name)
            XCTAssertEqual(t.kind, .image, name)
            XCTAssertEqual(store.meta(forId: t.id)?.uti, wantUTI, name)
            let blob = try XCTUnwrap(store.url(forId: t.id), name)
            XCTAssertEqual(try Data(contentsOf: blob), data, "bytes land verbatim")
            XCTAssertEqual(blob.pathExtension, (name as NSString).pathExtension,
                           "blob leaf keeps the extension (Quick Look needs it)")
        }
    }

    func testTiffNormalizesToPNGBeforeHashing() throws {
        // A pasted screenshot arrives as TIFF; the SAME screenshot pasted twice must be one
        // blob, and the stored form is PNG (name and uti follow).
        let shot = tiff()
        let t1 = try store.importData(shot, suggestedName: "Screenshot.tiff")
        let t2 = try store.importData(shot, suggestedName: "Screenshot.tiff")
        XCTAssertEqual(t1.id, t2.id)
        XCTAssertEqual(t1.name, "Screenshot.png", "name converts with the payload")
        XCTAssertEqual(store.meta(forId: t1.id)?.uti, "public.png")
        XCTAssertEqual(store.allEntries().count, 1)
    }

    func testMagicNumberSniffingForExtensionlessPastes() throws {
        // No extension anywhere — identity must come from the payload's magic numbers.
        let pngTok = try store.importData(png(), suggestedName: "clipboard")
        XCTAssertEqual(pngTok.kind, .image)
        XCTAssertEqual(store.meta(forId: pngTok.id)?.uti, "public.png")

        let jpgTok = try store.importData(jpeg(), suggestedName: "pasteboard")
        XCTAssertEqual(store.meta(forId: jpgTok.id)?.uti, "public.jpeg")

        let pdfTok = try store.importData(pdf(), suggestedName: "dropped")
        XCTAssertEqual(pdfTok.kind, .pdf)
        XCTAssertEqual(store.meta(forId: pdfTok.id)?.uti, "com.adobe.pdf")

        let tiffTok = try store.importData(tiff(), suggestedName: "clipboard")
        XCTAssertEqual(tiffTok.name, "clipboard.png", "sniffed TIFF still normalizes to PNG")

        let blobTok = try store.importData(Data([0x00, 0x01, 0x02, 0x03]), suggestedName: "mystery")
        XCTAssertEqual(blobTok.kind, .file, "unknown magic → opaque file, never a crash")
    }

    // ── Text/doc breadth classification ──────────────────────────────────────────────

    func testEveryFamilyClassifiesFromItsExtension() throws {
        let cases: [(String, String, AttachmentToken.Kind)] = [
            ("fn main() {}", "m.rs", .code), ("package main", "m.go", .code),
            ("def f(): pass", "m.py", .code), ("f(x) = 2x", "m.jl", .code),
            ("let x = 1", "m.swift", .code), ("SELECT 1", "q.sql", .code),
            ("<html></html>", "p.html", .code), ("body { color: red }", "s.css", .code),
            ("\\documentclass{article}", "p.tex", .code),
            ("a,b\n1,2", "t.csv", .data), ("a\tb", "t.tsv", .data),
            ("{\"k\":1}", "c.json", .data), ("k: v", "c.yaml", .data),
            ("<r/>", "d.xml", .data), ("plain", "n.txt", .data),
            ("fake docx bytes", "r.docx", .doc), ("fake rtf", "r.rtf", .doc),
            ("fake keynote", "deck.key", .doc),
            ("PK fake zip", "a.zip", .file),
        ]
        for (body, name, want) in cases {
            let t = try store.importData(Data(body.utf8), suggestedName: name)
            XCTAssertEqual(t.kind, want, name)
        }
        XCTAssertEqual(store.allEntries().count, cases.count, "all distinct bodies stored")
    }

    // ── Entry doors ───────────────────────────────────────────────────────────────────

    func testImportFileFromDiskMatchesImportData() throws {
        let payload = png()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("on-disk.png")
        try payload.write(to: f)
        let fromDisk = try store.importFile(f)
        let fromPaste = try store.importData(payload, suggestedName: "other-name.png")
        XCTAssertEqual(fromDisk.id, fromPaste.id, "one blob no matter the door")
        XCTAssertEqual(fromDisk.name, "on-disk.png", "disk import names from the file")
    }

    func testAdoptDataIsAnEquivalentDoorButVerified() throws {
        let payload = Data("adopted through the side door".utf8)
        let hash = sha256(payload)
        XCTAssertTrue(store.adoptData(payload, declaredHash: hash, name: "side.txt",
                                      uti: "public.plain-text"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.url(forId: String(hash.prefix(16))))),
                       payload)
        // Adopting a hash that's ALREADY here returns true without looking at the bytes —
        // the CAS trusts its own content-addressing, not the caller's payload.
        XCTAssertTrue(store.adoptData(Data("different".utf8), declaredHash: hash,
                                      name: "x", uti: "public.data"))
        XCTAssertEqual(store.allEntries().count, 1)
        // But a NEW hash with lying bytes is refused (and an empty payload always is).
        XCTAssertFalse(store.adoptData(Data("lie".utf8), declaredHash: sha256(Data("truth".utf8)),
                                       name: "x", uti: "public.data"))
        XCTAssertFalse(store.adoptData(Data(), declaredHash: sha256(Data()),
                                       name: "empty", uti: "public.data"))
    }

    func testEmptyPasteThrows() {
        XCTAssertThrowsError(try store.importData(Data(), suggestedName: "nothing.txt"))
    }

    // ── Token grammar under hostile names ────────────────────────────────────────────

    func testHostileNamesSurviveTheMarkdownRoundTrip() throws {
        let names = ["we]ird].png", "par(en)s.pdf", "emoji 🎉 party.png",
                     "spaces  and\ttabs.txt", "很长的中文文件名.md", "trailing.dot.",
                     "mid size:smx name.txt", "a size:big b.rs"]
        for (i, name) in names.enumerated() {
            let t = try store.importData(Data("payload #\(i)".utf8), suggestedName: name)
            let parsed = AttachmentTokens.matches(in: t.markdown)
            XCTAssertEqual(parsed.count, 1, name)
            XCTAssertEqual(parsed.first?.token.id, t.id, name)
            XCTAssertNotNil(AttachmentTokens.blockToken(line: t.markdown),
                            "\(name): a solitary line must read as a block token")
        }
    }

    func testSizeSuffixRoundTripsThroughHostileNames() throws {
        let t = try store.importData(Data("sized".utf8), suggestedName: "report].pdf")
        let big = t.with(size: .big)
        let parsed = try XCTUnwrap(AttachmentTokens.blockToken(line: big.markdown))
        XCTAssertEqual(parsed.size, .big)
        XCTAssertEqual(parsed.id, t.id)
    }

    // ── Identity edge cases ───────────────────────────────────────────────────────────

    func testPrefixCollisionExtendsTheTokenId() throws {
        let payload = Data("collision course".utf8)
        let real = sha256(payload)
        // Plant a fake index row sharing the real hash's 16-hex prefix BEFORE the store
        // loads — the astronomically-unlikely case the id scheme must survive.
        var fake = String(real.prefix(16)) + String(repeating: "0", count: 48)
        if fake == real {
            fake = String(real.prefix(16)) + String(repeating: "1", count: 48)
        }
        let filesDir = dir.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        // The on-disk shape is the versioned IndexFile wrapper (private) — write it raw.
        let planted = """
        {"version":1,"files":{"\(fake)":{"name":"squatter.bin","uti":"public.data","bytes":1,
        "addedAt":"2026-01-01T00:00","lastReferencedAt":"2026-01-01T00:00"}}}
        """
        try Data(planted.utf8).write(to: filesDir.appendingPathComponent("index.json"))

        let s2 = AttachmentStore(baseDir: dir)
        let t = try s2.importData(payload, suggestedName: "real.txt")
        XCTAssertEqual(t.id.count, 20, "16-hex prefix taken → id extends to 20")
        XCTAssertNotNil(s2.url(forId: t.id))
        XCTAssertNil(s2.url(forId: String(real.prefix(16))),
                     "the ambiguous 16-prefix resolves to NOTHING, never to the wrong blob")
    }

    func testReimportAfterRemoveIsAFreshStart() throws {
        let payload = Data("phoenix".utf8)
        let t1 = try store.importData(payload, suggestedName: "p.txt")
        let hash = try XCTUnwrap(store.resolveHash(forId: t1.id))
        store.remove(hash: hash)
        XCTAssertNil(store.url(forId: t1.id))
        let t2 = try store.importData(payload, suggestedName: "p.txt")
        XCTAssertEqual(t2.id, t1.id, "same content, same identity — content-addressing")
        XCTAssertNotNil(store.url(forId: t2.id))
    }

    func testDedupImportRefreshesTheGraceClock() throws {
        let payload = Data("evergreen".utf8)
        let t = try store.importData(payload, suggestedName: "e.txt")
        let hash = try XCTUnwrap(store.resolveHash(forId: t.id))
        store.touch(hashes: [hash], at: Date().addingTimeInterval(-30 * 24 * 3600))
        _ = try store.importData(payload, suggestedName: "again.txt") // dedup path
        let stamp = try XCTUnwrap(store.meta(forId: t.id)?.lastReferencedAt)
        let when = try XCTUnwrap(AttachmentStore.date(fromStamp: stamp))
        XCTAssertLessThan(abs(when.timeIntervalSinceNow), 120,
                          "re-importing referenced content resets the sweep clock")
    }

    func testIndexAndBackdatesPersistAcrossInstances() throws {
        let t = try store.importData(Data("durable".utf8), suggestedName: "d.txt")
        let hash = try XCTUnwrap(store.resolveHash(forId: t.id))
        let old = Date().addingTimeInterval(-9 * 24 * 3600)
        store.touch(hashes: [hash], at: old)
        let s2 = AttachmentStore(baseDir: dir)
        XCTAssertEqual(s2.meta(forId: t.id)?.lastReferencedAt, AttachmentStore.stamp(old),
                       "the grace clock is index state, not memory state")
    }

    func testStampRoundTripsAtMinutePrecision() {
        let d = Date()
        let back = AttachmentStore.date(fromStamp: AttachmentStore.stamp(d))
        XCTAssertNotNil(back)
        XCTAssertLessThan(abs(back!.timeIntervalSince(d)), 61)
        XCTAssertNil(AttachmentStore.date(fromStamp: "not-a-stamp"))
        XCTAssertNil(AttachmentStore.date(fromStamp: ""))
    }

    func testGenerationBumpsOnArrivalAndRemovalNeverOnTouch() throws {
        var gen = store.generation
        let t = try store.importData(Data("gen".utf8), suggestedName: "g.txt")
        XCTAssertGreaterThan(store.generation, gen, "import = arrival → repaint")
        gen = store.generation
        let hash = try XCTUnwrap(store.resolveHash(forId: t.id))
        store.touch(hashes: [hash])
        XCTAssertEqual(store.generation, gen, "a touch changes no pixels → no repaint")
        _ = try store.importData(Data("gen".utf8), suggestedName: "dup.txt")
        XCTAssertEqual(store.generation, gen, "dedup import arrives nothing new")
        store.remove(hash: hash)
        XCTAssertGreaterThan(store.generation, gen, "removal → cards repaint to missing")
    }

    func testDisplayURLRecreatesAfteritsDisposableDirIsDeleted() throws {
        let payload = pdf()
        let t = try store.importData(payload, suggestedName: "proposal.pdf")
        let first = try XCTUnwrap(store.displayURL(forId: t.id))
        XCTAssertEqual(first.lastPathComponent, "proposal.pdf")
        try FileManager.default.removeItem(at: first.deletingLastPathComponent())
        let second = try XCTUnwrap(store.displayURL(forId: t.id))
        XCTAssertEqual(try Data(contentsOf: second), payload, "disposable, recreated on demand")
    }
}
