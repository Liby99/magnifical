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
