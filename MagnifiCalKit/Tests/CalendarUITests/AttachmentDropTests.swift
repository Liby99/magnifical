// Drop-handler verification, driven by the 2026-09-17 field report (drops accepted but
// nothing lands): a stub NSDraggingInfo with a REAL pasteboard exercises each destination's
// draggingEntered/performDragOperation directly — if these pass, the handlers are sound and
// any remaining failure lives in AppKit's routing (who receives the drag), not in our code.

@testable import CalendarEngine
@testable import CalendarUI
import AppKit
import XCTest

/// Minimal NSDraggingInfo: a private-named pasteboard holding real file URLs.
private final class DragStub: NSObject, NSDraggingInfo {
    let pb: NSPasteboard
    var point = NSPoint(x: 10, y: 10)

    init(urls: [URL]) {
        pb = NSPasteboard(name: NSPasteboard.Name("attach-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        super.init()
    }

    deinit { pb.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }

    var animatesToDestination: Bool {
        get { false }
        set {}
    }

    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set {}
    }

    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options _: NSDraggingItemEnumerationOptions,
                                for _: NSView?, classes _: [AnyClass],
                                searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
                                using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
final class AttachmentDropTests: XCTestCase {
    private var dir: URL!
    private var store: AttachmentStore!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attdrop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AttachmentStore(baseDir: dir)
        fileURL = dir.appendingPathComponent("dropped.txt")
        try? Data("dropped payload".utf8).write(to: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testPreviewDrop() {
        let tv = PreviewTextView()
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        var appended: String?
        tv.attachmentStore = { [store] in store }
        tv.onAppendMarkdown = { appended = $0 }
        let drag = DragStub(urls: [fileURL])
        XCTAssertEqual(tv.draggingEntered(drag), .copy, "preview accepts the file drag")
        XCTAssertTrue(tv.performDragOperation(drag), "preview claims the drop")
        let md = appended ?? ""
        XCTAssertTrue(md.contains("](ccfile:"), "the drop appended a token, got: \(md)")
        XCTAssertNotNil(AttachmentTokens.blockToken(line: md))
    }

    func testEditorTextDrop() {
        let tv = NativeNoteEditor.EditorTextView()
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        tv.isRichText = false
        tv.string = "line one"
        tv.attachmentStore = { [store] in store }
        let drag = DragStub(urls: [fileURL])
        XCTAssertEqual(tv.draggingEntered(drag), .copy, "editor accepts the file drag")
        XCTAssertTrue(tv.performDragOperation(drag), "editor claims the drop")
        XCTAssertTrue(tv.string.contains("](ccfile:"),
                      "the drop inserted a token, got: \(tv.string)")
    }

    func testMarginScrollDrop() {
        let scroll = NativeNoteEditor.MarginDropScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        scroll.installMarginDrop()
        scroll.store = { [store] in store }
        var dropped: [URL]?
        scroll.onDropAtEnd = { dropped = $0 }
        let drag = DragStub(urls: [fileURL])
        XCTAssertEqual(scroll.draggingEntered(drag), .copy, "margin accepts the file drag")
        XCTAssertTrue(scroll.prepareForDragOperation(drag), "margin prepares (overlay up)")
        XCTAssertTrue(scroll.performDragOperation(drag), "margin claims the drop")
        XCTAssertEqual(dropped, [fileURL])
    }
}
