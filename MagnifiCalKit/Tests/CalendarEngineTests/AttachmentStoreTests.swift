// Attachment store P0 (docs/attachments-design.md): the content-addressed import pipeline
// (dedup by SHA-256, extension-preserving blob names, index metadata), the ccfile token
// grammar (render/parse round-trip, block vs inline detection, unknown-kind tolerance), and
// kind classification for the starter families.

@testable import CalendarEngine
import XCTest

@MainActor
final class AttachmentStoreTests: XCTestCase {
    private var dir: URL!
    private var store: AttachmentStore!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("att-\(UUID().uuidString)")
        store = AttachmentStore(baseDir: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testImportDedupsBySHA256() throws {
        let data = Data("hello attachment world".utf8)
        let t1 = try store.importData(data, suggestedName: "a.txt")
        let t2 = try store.importData(data, suggestedName: "b.txt") // same bytes, other name
        XCTAssertEqual(t1.id, t2.id, "same content = same id")
        let blobs = try FileManager.default.subpathsOfDirectory(
            atPath: dir.appendingPathComponent("files/blobs").path
        ).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(blobs.count, 1, "one blob on disk")
        XCTAssertEqual(store.meta(forId: t1.id)?.name, "a.txt", "first import names the blob")
    }

    func testBlobResolvesAndKeepsExtension() throws {
        let t = try store.importData(Data("{\"k\":1}".utf8), suggestedName: "data.json")
        let url = try XCTUnwrap(store.url(forId: t.id))
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertEqual(try Data(contentsOf: url), Data("{\"k\":1}".utf8))
        XCTAssertEqual(t.kind, .data)
        XCTAssertEqual(store.meta(forId: t.id)?.bytes, 7)
    }

    func testIndexPersistsAcrossInstances() throws {
        let t = try store.importData(Data("persist me".utf8), suggestedName: "n.txt")
        let second = AttachmentStore(baseDir: dir)
        XCTAssertNotNil(second.url(forId: t.id), "a fresh instance reads the saved index")
        XCTAssertEqual(second.meta(forId: t.id)?.name, "n.txt")
    }

    func testTooLargeRefused() {
        let big = Data(count: AttachmentStore.maxBytes + 1)
        XCTAssertThrowsError(try store.importData(big, suggestedName: "huge.bin")) {
            guard case AttachmentError.tooLarge = $0 else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    func testTokenRoundTripAndBlockDetection() throws {
        let t = try store.importData(Data("# notes".utf8), suggestedName: "notes.md")
        XCTAssertEqual(t.kind, .code)
        let md = t.markdown
        XCTAssertTrue(md.hasPrefix("![@code:notes.md](ccfile:"), "grammar shape: \(md)")
        XCTAssertEqual(AttachmentTokens.blockToken(line: md)?.id, t.id)
        XCTAssertEqual(AttachmentTokens.blockToken(line: "  \(md)  ")?.id, t.id,
                       "whitespace-trimmed line still blocks")
        XCTAssertNil(AttachmentTokens.blockToken(line: "see \(md)"), "mid-line ≠ block")
        XCTAssertEqual(AttachmentTokens.ids(in: "x\n\(md)\ny \(md) z"), [t.id])
    }

    func testSizeTokenRoundTrip() {
        // size: rides in the NAME part; medium is the invisible default.
        let base = AttachmentToken(kind: .pdf, name: "main.pdf", id: "0123456789abcdef")
        XCTAssertFalse(base.markdown.contains("size:"), "medium is never written")
        let big = base.with(size: .big)
        XCTAssertEqual(big.markdown, "![@pdf:main.pdf size:big](ccfile:0123456789abcdef)")
        let parsed = AttachmentTokens.blockToken(line: big.markdown)
        XCTAssertEqual(parsed?.size, .big)
        XCTAssertEqual(parsed?.name, "main.pdf", "the size token parses OUT of the display name")
        // Aliases + case-insensitivity.
        XCTAssertEqual(AttachmentTokens.blockToken(
            line: "![@image:x.png size:sm](ccfile:0123456789abcdef)")?.size, .small)
        XCTAssertEqual(AttachmentTokens.blockToken(
            line: "![@image:x.png size:BG](ccfile:0123456789abcdef)")?.size, .big)
        XCTAssertEqual(AttachmentTokens.blockToken(
            line: "![@image:x.png size:md](ccfile:0123456789abcdef)")?.size, .medium)
        // An unknown size word stays part of the name (forward compat).
        let odd = AttachmentTokens.blockToken(line: "![@image:x size:huge](ccfile:0123456789abcdef)")
        XCTAssertEqual(odd?.name, "x size:huge")
        XCTAssertEqual(odd?.size, .medium)
        // Round-trip stability: parse(render(t)) == t.
        XCTAssertEqual(AttachmentTokens.blockToken(line: parsed!.markdown), parsed)
    }

    func testUnknownKindWordParsesAsFile() {
        let line = "![@hologram:future.obj](ccfile:0123456789abcdef)"
        let tok = AttachmentTokens.blockToken(line: line)
        XCTAssertEqual(tok?.kind, .file, "unknown kind words must not break old builds")
        XCTAssertEqual(tok?.id, "0123456789abcdef")
    }

    func testNameSanitization() {
        let t = AttachmentToken(kind: .file, name: "we]ird\nname", id: "aabbccddeeff0011")
        XCTAssertNotNil(AttachmentTokens.blockToken(line: t.markdown),
                        "brackets/newlines in names can't corrupt the grammar")
    }

    func testKindClassification() {
        XCTAssertEqual(AttachmentStore.kind(forUTI: "public.png", name: "x.png"), .image)
        XCTAssertEqual(AttachmentStore.kind(forUTI: "com.adobe.pdf", name: "x.pdf"), .pdf)
        XCTAssertEqual(AttachmentStore.kind(forUTI: "public.data", name: "m.rs"), .code)
        XCTAssertEqual(AttachmentStore.kind(forUTI: "public.plain-text", name: "d.csv"), .data)
        XCTAssertEqual(AttachmentStore.kind(forUTI: "public.data", name: "r.docx"), .doc)
        XCTAssertEqual(AttachmentStore.kind(forUTI: "public.data", name: "a.zip"), .file)
    }

    func testRemoveDeletesBlobExportAndIndexEntry() throws {
        let token = try store.importData(Data("doomed".utf8), suggestedName: "doomed.txt")
        let export = try XCTUnwrap(store.displayURL(forId: token.id)) // mint the export handle
        let hash = try XCTUnwrap(store.resolveHash(forId: token.id))
        let gen0 = store.generation

        store.remove(hash: hash)
        XCTAssertNil(store.url(forId: token.id))
        XCTAssertNil(store.meta(forId: token.id))
        XCTAssertTrue(store.allEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path),
                       "the display-named hardlink dir goes with the blob")
        XCTAssertGreaterThan(store.generation, gen0, "cards repaint into the missing state")
        store.remove(hash: hash) // unknown hash → silent no-op
    }

    func testMissingIdResolvesNil() {
        XCTAssertNil(store.url(forId: "deadbeefdeadbeef"))
        XCTAssertNil(store.meta(forId: "deadbeefdeadbeef"))
    }

    func testDisplayURLIsNamedHandleOnTheSameBytes() throws {
        let t = try store.importData(Data("copy me nicely".utf8), suggestedName: "NSF draft.txt")
        let url = try XCTUnwrap(store.displayURL(forId: t.id))
        XCTAssertEqual(url.lastPathComponent, "NSF draft.txt",
                       "⌘C / Quick Look / open see the real name, not the hash")
        XCTAssertEqual(try Data(contentsOf: url), Data("copy me nicely".utf8))
        XCTAssertEqual(store.displayURL(forId: t.id), url, "the handle is reused, not re-made")
        XCTAssertNil(store.displayURL(forId: "deadbeefdeadbeef"), "missing blob → nil")
    }
}
