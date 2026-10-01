// Drop-handler verification, driven by the 2026-09-17 field report (drops accepted but
// nothing lands): a stub NSDraggingInfo with a REAL pasteboard exercises each destination's
// draggingEntered/performDragOperation directly — if these pass, the handlers are sound and
// any remaining failure lives in AppKit's routing (who receives the drag), not in our code.

@testable import CalendarEngine
@testable import CalendarUI
import AppKit
import XCTest

/// Minimal NSDraggingInfo: a private-named pasteboard holding real file URLs. Sequence
/// numbers are unique per stub, like real sessions (the router caches pasteboard facts
/// per sequence number — a constant here would leak one drag's verdict into the next).
private final class DragStub: NSObject, NSDraggingInfo {
    let pb: NSPasteboard
    var point = NSPoint(x: 10, y: 10)
    private static var nextSequence = 0
    private let sequence: Int

    init(urls: [URL]) {
        pb = NSPasteboard(name: NSPasteboard.Name("attach-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        Self.nextSequence += 1
        sequence = Self.nextSequence
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
    var draggingSequenceNumber: Int { sequence }
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
        host?.contentView = nil
        host = nil
        super.tearDown()
    }

    /// The drop guards refuse windowless/invisible views (the parked-panel steal fix) —
    /// give each view a real offscreen window so it counts as visible.
    private var host: NSWindow?
    private func hosted<V: NSView>(_ v: V) -> V {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                         styleMask: .borderless, backing: .buffered, defer: true)
        w.contentView = v
        host = w
        return v
    }

    func testPreviewDrop() {
        let tv = hosted(PreviewTextView())
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
        let tv = hosted(NativeNoteEditor.EditorTextView())
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

    func testMidLineDropNeverSplitsTheLine() throws {
        // The field bug: a drop landing MID-token-line cut the existing token in half,
        // producing degenerate half-links. A mid-line drop must snap below the line.
        let existing = try store.importData(Data("existing pdf-ish".utf8), suggestedName: "main.pdf")
        let tv = hosted(NativeNoteEditor.EditorTextView())
        tv.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        tv.isRichText = false
        tv.string = existing.markdown // one token line, no trailing newline
        tv.attachmentStore = { [store] in store }
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let drag = DragStub(urls: [fileURL]) // draggingLocation (10,10) = INSIDE line 1
        XCTAssertTrue(tv.performDragOperation(drag))
        let lines = tv.string.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2, "no split halves: \(tv.string)")
        XCTAssertEqual(AttachmentTokens.blockToken(line: lines[0])?.id, existing.id,
                       "the existing token line is INTACT")
        XCTAssertNotNil(AttachmentTokens.blockToken(line: lines[1]),
                        "the dropped token landed whole on its own line below")
    }

    func testHiddenEditorRefusesDrops() {
        // Parked dashboard panels hide their AppKit note views (NativePanelHost.live →
        // NativeNotePanel.active → isHidden) — and a hidden view must refuse the drag, so an
        // invisible neighbor day can never swallow a drop meant for the visible note.
        let tv = hosted(NativeNoteEditor.EditorTextView())
        tv.attachmentStore = { [store] in store }
        tv.isHidden = true
        XCTAssertEqual(tv.draggingEntered(DragStub(urls: [fileURL])), [],
                       "hidden (parked) editors never accept drops")
    }

    func testMarginScrollDrop() {
        let scroll = hosted(NativeNoteEditor.MarginDropScrollView())
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        scroll.installMarginDrop()
        scroll.store = { [store] in store }
        var dropped: [AttachmentToken]?
        scroll.onDropTokens = { dropped = $0 }
        let drag = DragStub(urls: [fileURL])
        XCTAssertEqual(scroll.draggingEntered(drag), .copy, "margin accepts the file drag")
        XCTAssertTrue(scroll.prepareForDragOperation(drag), "margin prepares (overlay up)")
        XCTAssertTrue(scroll.performDragOperation(drag), "margin claims the drop")
        XCTAssertEqual(dropped?.count, 1, "the margin drop delivers imported tokens now")
        XCTAssertEqual(dropped?.first?.name, fileURL.lastPathComponent)
    }

    func testRouterRoutesToParticipantAndDelivers() throws {
        // The router is the ONE window-wide destination; participants are reached through
        // its per-move routing, not AppKit's sticky session (the year-view blackhole fix).
        let scroll = hosted(NativeNoteEditor.MarginDropScrollView())
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        scroll.installMarginDrop()
        scroll.store = { [store] in store }
        var delivered: [AttachmentToken]?
        scroll.onDropTokens = { delivered = $0 }
        // viewDidMoveToWindow installed the router into the window's content view.
        let router = try XCTUnwrap(
            host?.contentView?.subviews.compactMap { $0 as? AttachmentDropRouter }.first
                ?? (host?.contentView as? AttachmentDropRouter))
        let drag = DragStub(urls: [fileURL])
        XCTAssertEqual(router.draggingEntered(drag), .copy, "router routes to the margin")
        XCTAssertEqual(router.draggingUpdated(drag), .copy, "…and keeps it per-move")
        XCTAssertTrue(router.prepareForDragOperation(drag))
        XCTAssertTrue(router.performDragOperation(drag))
        XCTAssertEqual(delivered?.count, 1, "the participant's own perform ran")
    }

    func testDrawerTiersOutrankPanelsAndCoveredPanelsAreSkipped() throws {
        // The field complaint: drawer open, mouse ON the drawer — the drop went to the
        // weekly note behind it. Tiers say drawer targets always outrank panel targets,
        // and a modally-covered (inert) view is no candidate at all.
        let container = hosted(NSView())
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 500)

        let panelPreview = PreviewTextView(frame: container.bounds) // tier 5 (panel)
        panelPreview.attachmentStore = { [store] in store }
        var appended: String?
        panelPreview.onAppendMarkdown = { appended = $0 }
        container.addSubview(panelPreview)

        let drawerMargin = NativeNoteEditor.MarginDropScrollView(frame: container.bounds)
        drawerMargin.installMarginDrop()
        drawerMargin.inDrawerContext = true // tier 1 (drawer)
        drawerMargin.store = { [store] in store }
        var drawerTokens: [AttachmentToken]?
        drawerMargin.onDropTokens = { drawerTokens = $0 }
        container.addSubview(drawerMargin)

        let router = try XCTUnwrap(
            container.subviews.compactMap { $0 as? AttachmentDropRouter }.first)
        let drag = DragStub(urls: [fileURL])
        XCTAssertEqual(router.draggingEntered(drag), .copy)
        XCTAssertTrue(router.performDragOperation(drag))
        XCTAssertEqual(drawerTokens?.count, 1, "the drawer target wins over the panel")
        XCTAssertNil(appended, "the panel behind never hears the drop")

        // Reverse situation: the drawer target is modally covered (inert) → the panel,
        // being the only interactive candidate, gets the route.
        drawerMargin.inert = true
        let drag2 = DragStub(urls: [fileURL])
        XCTAssertEqual(router.draggingEntered(drag2), .copy)
        XCTAssertTrue(router.performDragOperation(drag2))
        XCTAssertNotNil(appended, "with the drawer inert, the panel is the target")
    }

    func testRouterICSFallbackWhenNoParticipantIsUnder() throws {
        let plain = hosted(NSView()) // a window with no drop participants at all
        plain.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        AttachmentDropRouter.install(in: try XCTUnwrap(host))
        let router = try XCTUnwrap(
            plain.subviews.compactMap { $0 as? AttachmentDropRouter }.first)

        var imported: [URL]?
        AttachmentDropRouter.icsImport = { imported = $0 }
        defer { AttachmentDropRouter.icsImport = nil }

        // A non-.ics file over bare calendar: refused honestly (no ghost acceptance).
        XCTAssertEqual(router.draggingEntered(DragStub(urls: [fileURL])), [])

        // An .ics file: the fallback accepts and imports through the wired closure.
        let ics = dir.appendingPathComponent("cal.ics")
        try Data("BEGIN:VCALENDAR\nEND:VCALENDAR".utf8).write(to: ics)
        let drag = DragStub(urls: [ics])
        XCTAssertEqual(router.draggingEntered(drag), .copy)
        XCTAssertTrue(router.prepareForDragOperation(drag))
        XCTAssertTrue(router.performDragOperation(drag))
        XCTAssertEqual(imported, [ics])
    }

    func testPromiseOnlyDragIsAccepted() throws {
        // A drag from Mail/Outlook/browsers carries NO file URL — only a file PROMISE. The
        // targets must still accept it (the .xlsx-from-an-email case; URL-only acceptance
        // silently refused these). A real NSFilePromiseReceiver can't be fabricated off a
        // real drag session, so this pins the acceptance gate: a pasteboard declaring the
        // promise types (with no URL) must read as importable.
        let pb = NSPasteboard(name: NSPasteboard.Name("cc-test-promise-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.declareTypes(NSFilePromiseReceiver.readableDraggedTypes
            .map { NSPasteboard.PasteboardType($0) }, owner: nil)
        pb.setString("com.microsoft.excel.xlsx", // the promised UTI, as Mail declares it
                     forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
        XCTAssertTrue(AttachmentDropIntake.hasImportableFiles(pb),
                      "a promise-only pasteboard is importable — the drop must be accepted")
        XCTAssertNil(AttachmentDropIntake.fileURLs(pb), "…even though it has no URLs at all")

        // And the registration list every target installs includes the promise types.
        for t in NSFilePromiseReceiver.readableDraggedTypes {
            XCTAssertTrue(AttachmentDropIntake.draggedTypes
                .contains(NSPasteboard.PasteboardType(t)), t)
        }
    }
}
