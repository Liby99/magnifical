// The card context menu: right-click over a preview card replaces NSTextView's stock text
// menu with the card's own actions (and selects the card, Finder-style); right-click over
// plain text keeps the standard menu. "Remove from Note" routes the card's source line to
// the host; "Show in Attachment Browser" posts the focus notification.

@testable import CalendarEngine
@testable import CalendarUI
import AppKit
import XCTest

@MainActor
final class AttachmentMenuTests: XCTestCase {
    private var dir: URL!
    private var store: AttachmentStore!
    private var host: NSWindow?

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attmenu-\(UUID().uuidString)")
        store = AttachmentStore(baseDir: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        host?.contentView = nil
        host = nil
        super.tearDown()
    }

    /// A rendered preview hosted in an offscreen window (menu hit-testing needs real layout
    /// and window-coordinate conversion), plus a right-click event over the FIRST card.
    private func preview(_ text: String) throws -> (tv: PreviewTextView, overCard: NSEvent) {
        let doc = MarkdownDoc.render(text, theme: Theme(dark: false), interactive: true,
                                     attachments: store, cardWidth: 480)
        let tv = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        tv.isEditable = false
        tv.textStorage?.setAttributedString(doc.string)
        tv.attachmentStore = { [store] in store }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                         styleMask: .borderless, backing: .buffered, defer: true)
        w.contentView = tv
        host = w
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        var attIndex: Int?
        doc.string.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0, length: doc.string.length)) { v, r, stop in
            if v is MarkdownDoc.CardAttachment {
                attIndex = r.location
                stop.pointee = true
            }
        }
        let idx = try XCTUnwrap(attIndex, "the token rendered a card")
        let gr = tv.layoutManager!.glyphRange(forCharacterRange: NSRange(location: idx, length: 1),
                                              actualCharacterRange: nil)
        let rect = tv.layoutManager!.boundingRect(forGlyphRange: gr, in: tv.textContainer!)
            .offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
        let inWindow = tv.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let ev = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        return (tv, ev)
    }

    func testRightClickOnACardBuildsTheCardMenuAndSelects() throws {
        let tok = try store.importData(Data("menu payload".utf8), suggestedName: "menu.txt")
        let (tv, ev) = try preview(tok.markdown)
        var removedLine: Int?
        tv.onRemoveLine = { removedLine = $0 }

        let menu = try XCTUnwrap(tv.menu(for: ev))
        let titles = menu.items.map(\.title)
        for want in ["Open", "Quick Look", "Copy File", "Reveal in Finder",
                     "Show in Attachment Browser", "Remove from Note"] {
            XCTAssertTrue(titles.contains(want), "missing \(want) in \(titles)")
        }
        XCTAssertEqual(tv.selectedAtt?.id, tok.id, "right-click selects the card (the ring)")
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled },
                      "blob is local + host wired → every action available")
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || $0.image != nil },
                      "every item carries its icon, like the system menus")

        // "Remove from Note" hands the card's 1-based source line to the host.
        let remove = try XCTUnwrap(menu.items.first { $0.title == "Remove from Note" })
        _ = remove.target?.perform(remove.action)
        XCTAssertEqual(removedLine, 1)

        // "Show in Attachment Browser" posts the focus notification with the token id.
        var focused: String?
        let obs = NotificationCenter.default.addObserver(
            forName: .openAttachmentBrowser, object: nil, queue: nil
        ) { note in
            focused = note.userInfo?[AttachmentBrowser.focusKey] as? String
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        let show = try XCTUnwrap(menu.items.first { $0.title == "Show in Attachment Browser" })
        _ = show.target?.perform(show.action)
        XCTAssertEqual(focused, tok.id)
    }

    func testWaitingCardMenuDisablesFileActionsButKeepsTheNew() throws {
        // A ghost (blob not yet synced): no Open/QL/Copy/Reveal, but you can still find it
        // in the browser or take its token out of the note.
        let (tv, ev) = try preview("![@pdf:ghost.pdf](ccfile:00ff00ff00ff00ff)")
        tv.onRemoveLine = { _ in }
        let menu = try XCTUnwrap(tv.menu(for: ev))
        func item(_ t: String) -> NSMenuItem? { menu.items.first { $0.title == t } }
        for dead in ["Open", "Quick Look", "Copy File", "Reveal in Finder"] {
            XCTAssertFalse(try XCTUnwrap(item(dead)).isEnabled, dead)
        }
        XCTAssertTrue(try XCTUnwrap(item("Show in Attachment Browser")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(item("Remove from Note")).isEnabled)
    }

    func testRightClickOffCardKeepsTheStandardTextMenu() throws {
        let tok = try store.importData(Data("below me is prose".utf8), suggestedName: "p.txt")
        let (tv, ev) = try preview("\(tok.markdown)\n\nplain prose paragraph")
        // A point far below the card, over the prose.
        let low = tv.convert(NSPoint(x: 40, y: tv.bounds.height - 10), to: nil)
        let offEv = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: low, modifierFlags: [], timestamp: 0,
            windowNumber: ev.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = tv.menu(for: offEv)
        XCTAssertFalse(menu?.items.contains { $0.title == "Remove from Note" } ?? false,
                       "off-card right-click keeps NSTextView's own menu")
    }
}
