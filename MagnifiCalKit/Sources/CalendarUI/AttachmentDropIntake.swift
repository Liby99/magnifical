// The shared file-intake for every attachment drop target (editor text, editor margin,
// preview pane). Two shapes arrive off a drag: real file URLs (Finder), and FILE PROMISES
// (Mail, Outlook, browsers, Photos — the source writes the file only after the drop is
// accepted; an .xlsx dragged out of an email is a promise, not a URL). readObjects([NSURL])
// sees nothing on a promise drag, so URL-only targets silently refused those drops. Intake:
// URLs import synchronously; promises are received into a temp dir on a background queue and
// the tokens DELIVER LATER on the main actor — callers capture their insertion point and
// clamp on arrival.

import AppKit
import CalendarEngine
import UniformTypeIdentifiers

@MainActor enum AttachmentDropIntake {
    /// What a drop target must register to hear both shapes.
    nonisolated static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
    }

    /// Acceptance gate for draggingEntered: anything on this pasteboard that can become files.
    static func hasImportableFiles(_ pb: NSPasteboard) -> Bool {
        fileURLs(pb) != nil || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self],
                                                options: nil)
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL]? {
        let urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.isEmpty ? nil : urls
    }

    /// The promise API's required delivery queue (file writes happen here, off-main).
    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Consume a drop: true = handled (imported now, or promised — tokens arrive via
    /// `deliver` on the main actor either way; empty imports beep once, deliver never fires).
    static func receive(_ pb: NSPasteboard, store: AttachmentStore,
                        deliver: @escaping ([AttachmentToken]) -> Void) -> Bool {
        if let urls = fileURLs(pb) {
            finish(importAll(urls, store: store), deliver)
            return true
        }
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver]) ?? []
        guard !receivers.isEmpty else { return false }
        attachLog.notice("drop intake: \(receivers.count) file promise(s) — receiving async")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-promised-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let group = DispatchGroup()
        var landed: [URL] = []
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: dest, options: [:],
                                          operationQueue: promiseQueue) { url, error in
                DispatchQueue.main.async {
                    if let error {
                        attachLog.error("promise receive FAILED \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    } else {
                        landed.append(url)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            // Deterministic order for multi-file drops (promise arrival order is racy).
            let tokens = importAll(landed.sorted { $0.lastPathComponent < $1.lastPathComponent },
                                   store: store)
            try? FileManager.default.removeItem(at: dest) // the CAS owns the bytes now
            finish(tokens, deliver)
        }
        return true
    }

    private static func importAll(_ urls: [URL], store: AttachmentStore) -> [AttachmentToken] {
        var tokens: [AttachmentToken] = []
        for url in urls {
            do { tokens.append(try store.importFile(url)) } catch {
                attachLog.error("drop import FAILED \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        attachLog.notice("drop intake imported: \(tokens.count)/\(urls.count)")
        return tokens
    }

    private static func finish(_ tokens: [AttachmentToken],
                               _ deliver: ([AttachmentToken]) -> Void) {
        if tokens.isEmpty {
            NSSound.beep() // unreadable / over the size cap / every promise failed
        } else {
            deliver(tokens)
        }
    }
}
