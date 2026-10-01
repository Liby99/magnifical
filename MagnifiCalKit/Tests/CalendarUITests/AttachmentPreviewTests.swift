// Attachment preview P0: MarkdownDoc renders ccfile tokens as attachment-glyph CARDS — a
// solitary token as one card, consecutive tokens as one wrapping grid paragraph, a mid-line
// token as the 📎 chip — with lineMap entries pointing each card at its source line.

@testable import CalendarEngine
@testable import CalendarUI
import AppKit
import XCTest

@MainActor
final class AttachmentPreviewTests: XCTestCase {
    private var dir: URL!
    private var store: AttachmentStore!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attui-\(UUID().uuidString)")
        store = AttachmentStore(baseDir: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func pngFixture(w: Int = 120, h: Int = 80) -> Data {
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 18, dy: 12)).fill()
            return true
        }
        let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        return rep.representation(using: .png, properties: [:])!
    }

    private func attachmentCount(_ s: NSAttributedString) -> Int {
        var n = 0
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if v is NSTextAttachment {
                n += 1
            }
        }
        return n
    }

    func testCardsGridAndChip() throws {
        let img = try store.importData(pngFixture(), suggestedName: "shot.png")
        let txt = try store.importData(Data("hello card\nline 2".utf8), suggestedName: "notes.txt")
        let json = try store.importData(Data("{\"a\":[1,2,3]}".utf8), suggestedName: "cfg.json")
        XCTAssertEqual(img.kind, .image)

        let text = """
        # Files
        \(img.markdown)

        \(txt.markdown)
        \(json.markdown)

        And inline \(txt.markdown) reference.
        """
        let doc = MarkdownDoc.render(text, theme: Theme(dark: false), interactive: true,
                                     attachments: store, cardWidth: 480)
        let s = doc.string.string
        // 1 solitary card + 2 grid cells (the todo checkbox path is off — no todos here);
        // the inline token became a chip, not an attachment.
        XCTAssertEqual(attachmentCount(doc.string), 3)
        XCTAssertTrue(s.contains("📎 notes.txt"), "mid-line token renders as the chip")
        XCTAssertFalse(s.contains("ccfile:"), "raw plumbing never reaches the preview")
        // Each card's lineMap row points at its own source line (2 / 4 / 5).
        let cardLines = doc.lineMap.filter { r in
            doc.string.attribute(.link, at: r.range.location, effectiveRange: nil)
                .map { "\($0)".hasPrefix("ccsel://") } ?? false
        }.map(\.line)
        XCTAssertEqual(Set(cardLines), [2, 4, 5])

        // Grid cells sit on ONE paragraph (glue, no newline between them).
        let gridRanges = doc.lineMap.filter { [4, 5].contains($0.line) }.map(\.range)
        let between = NSRange(location: gridRanges[0].upperBound,
                              length: gridRanges[1].location - gridRanges[0].upperBound)
        XCTAssertFalse((s as NSString).substring(with: between).contains("\n"),
                       "consecutive tokens share a wrapping grid paragraph")
    }

    func testMissingBlobStillRendersACard() {
        let text = "![@image:gone.png](ccfile:00112233445566ff)"
        let doc = MarkdownDoc.render(text, theme: Theme(dark: true), interactive: false,
                                     attachments: store, cardWidth: 480)
        XCTAssertEqual(attachmentCount(doc.string), 1, "missing blob → the metadata card")
    }

    func testNoStoreLeavesTextIntactAsChips() {
        let text = "![@pdf:doc.pdf](ccfile:0123456789abcdef)"
        let doc = MarkdownDoc.render(text, theme: Theme(dark: false), interactive: false)
        XCTAssertEqual(attachmentCount(doc.string), 0)
        XCTAssertTrue(doc.string.string.contains("📎 doc.pdf"),
                      "no store (phone-ish path) → chip text, never raw plumbing")
    }

    /// P4 exit criterion: a `.rs` file renders a CONTENT card (QL can't thumbnail bare
    /// source at all — §5.5 probe — so self-rendering is the only path), and csv gets the
    /// table card. Both stand taller than the 70pt metadata card they used to fall back to.
    func testFullBreadthTextAndTableCards() throws {
        let theme = Theme(dark: false)
        let rust = try store.importData(Data("fn main() {\n    println!(\"hi\");\n}".utf8),
                                        suggestedName: "main.rs")
        XCTAssertEqual(rust.kind, .code)
        let rustCard = AttachmentCards.card(for: rust, store: store, width: 480,
                                            compact: false, theme: theme)
        XCTAssertGreaterThan(rustCard.size.height, AttachmentCards.metaH,
                             ".rs self-renders a content card, never just an icon")

        let csv = try store.importData(Data("name,score\nalice,10\nbob,7".utf8),
                                       suggestedName: "table.csv")
        let csvCard = AttachmentCards.card(for: csv, store: store, width: 480,
                                           compact: false, theme: theme)
        XCTAssertGreaterThan(csvCard.size.height, AttachmentCards.metaH,
                             "csv renders the table card")

        // Unknown-but-readable text still gets a content card (plain mono, §5.3).
        let ini = try store.importData(Data("[core]\n\teditor = vim".utf8),
                                       suggestedName: "config.ini")
        let iniCard = AttachmentCards.card(for: ini, store: store, width: 480,
                                           compact: false, theme: theme)
        XCTAssertGreaterThan(iniCard.size.height, AttachmentCards.metaH)
    }

    func testNewLanguagesProduceColoredRuns() {
        for (code, lang) in [("func greet() -> String { return \"hi\" } // done", "swift"),
                             ("SELECT id FROM users -- all", "sql"),
                             ("package main // entry", "go"),
                             ("key: true # flag", "yaml")] {
            let s = CodeHighlight.highlight(code, lang: lang, base: .textColor,
                                            font: .systemFont(ofSize: 11))
            var colors: Set<NSColor> = []
            s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) { v, _, _ in
                if let c = v as? NSColor {
                    colors.insert(c)
                }
            }
            XCTAssertGreaterThan(colors.count, 1, "\(lang) gets keyword/comment coloring")
        }
    }

    /// The doc family's ASYNC page card, end to end with a real (textutil-made) docx:
    /// first sight is the "rendering preview…" placeholder; the QL raster lands on disk,
    /// BUMPS THE STORE GENERATION (the preview's rebuild key — without the bump the
    /// placeholder showed forever, the .xlsx field report), and the recompose is the page.
    func testDocCardRendersItsFirstPageAsync() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let txt = dir.appendingPathComponent("probe.txt")
        try Data("document body text".utf8).write(to: txt)
        let docx = dir.appendingPathComponent("probe.docx")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "docx", txt.path, "-output", docx.path]
        try p.run()
        p.waitUntilExit()

        let tok = try store.importFile(docx)
        XCTAssertEqual(tok.kind, .doc)
        let theme = Theme(dark: false)
        let gen0 = store.generation
        let first = AttachmentCards.card(for: tok, store: store, width: 480,
                                         compact: false, theme: theme)
        XCTAssertEqual(first.size.height, AttachmentCards.metaH,
                       "first sight: the placeholder while QL renders")

        let deadline = Date().addingTimeInterval(15)
        while store.generation == gen0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(store.generation, gen0,
                             "thumb arrival must bump the repaint key — the stuck-card bug")
        let second = AttachmentCards.card(for: tok, store: store, width: 480,
                                          compact: false, theme: theme)
        XCTAssertGreaterThan(second.size.height, AttachmentCards.metaH,
                             "recompose returns the rendered page card")
        let thumbs = (try? FileManager.default.contentsOfDirectory(atPath: store.thumbsDir.path)) ?? []
        XCTAssertTrue(thumbs.contains { $0.hasSuffix(".png") }, "the page raster is disk-cached")
    }

    /// Not an assertion — renders the composed document to a PNG artifact for eyeballing.
    func testDumpRenderArtifact() throws {
        let img = try store.importData(pngFixture(w: 400, h: 210), suggestedName: "screenshot.png")
        let code = try store.importData(Data("""
        function greet(name) {
          return `hello ${name}`;
        }
        module.exports = { greet };
        """.utf8), suggestedName: "greet.js")
        let txt = try store.importData(Data("plain text attachment\nsecond line".utf8),
                                       suggestedName: "readme.txt")
        let text = "# Attached\n\(img.markdown)\n\n\(code.markdown)\n\(txt.markdown)\n\ndone."
        let doc = MarkdownDoc.render(text, theme: Theme(dark: false), interactive: false,
                                     attachments: store, cardWidth: 480)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 10))
        tv.textStorage?.setAttributedString(doc.string)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let size = tv.layoutManager!.usedRect(for: tv.textContainer!).size
        tv.frame = NSRect(origin: .zero, size: NSSize(width: 520, height: ceil(size.height) + 20))
        let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
        tv.cacheDisplay(in: tv.bounds, to: rep)
        let out = ProcessInfo.processInfo.environment["ATT_ARTIFACT"]
        if let out {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: out))
        }
        XCTAssertGreaterThan(size.height, 200, "cards occupy real vertical space")
    }
}
