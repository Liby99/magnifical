// Note attachments, P0 (docs/attachments-design.md): a GLOBAL content-addressed blob store —
// files/blobs/<xx>/<sha256>.<ext> under the CalendarKit data root, deduplicated by SHA-256,
// shared by every calendar — plus files/index.json (the metadata "small database") and the
// ccfile token grammar the editor writes and the preview parses. Reference counting is
// deliberately DERIVED from the notes themselves (never stored); the P3 sweep reclaims blobs.

import CryptoKit
import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

/// A preview card's size class — written into the token's NAME part as a trailing
/// ` size:small|sm|medium|md|big|bg` (todo-token style). Absent = medium; medium is never
/// written (the default stays invisible in the source).
public enum AttachmentSize: String, Sendable, CaseIterable {
    case small, medium, big

    /// Parse any accepted spelling; nil for unknown words (they stay part of the name).
    public static func parse(_ word: String) -> AttachmentSize? {
        switch word.lowercased() {
        case "small", "sm": .small
        case "medium", "md": .medium
        case "big", "bg": .big
        default: nil
        }
    }

    /// Ordered for the drag-resize stepping (down = bigger).
    public var index: Int {
        switch self {
        case .small: 0
        case .medium: 1
        case .big: 2
        }
    }

    public static func at(index: Int) -> AttachmentSize {
        index <= 0 ? .small : index == 1 ? .medium : .big
    }
}

/// One `![@kind:name](ccfile:id)` token. `kind` is a display hint assigned at import; behavior
/// (card family, Quick Look) always follows the real UTI from the index, and an UNKNOWN kind
/// word must be treated as `.file` (the set will grow; old builds read newer notes).
public struct AttachmentToken: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case image, pdf, code, data, doc, file
    }

    public var kind: Kind
    public var name: String // display name — the user may rename it in the token text
    public var id: String // 16+ hex chars of the blob's SHA-256
    public var size: AttachmentSize // card size class (see AttachmentSize; default medium)

    public init(kind: Kind, name: String, id: String, size: AttachmentSize = .medium) {
        self.kind = kind; self.name = name; self.id = id; self.size = size
    }

    /// The markdown source form. Non-default sizes ride in the name: `name size:big`.
    public var markdown: String {
        let sizeSuffix = size == .medium ? "" : " size:\(size.rawValue)"
        return "![@\(kind.rawValue):\(sanitizedName)\(sizeSuffix)](ccfile:\(id))"
    }

    public func with(size newSize: AttachmentSize) -> AttachmentToken {
        AttachmentToken(kind: kind, name: name, id: id, size: newSize)
    }

    /// Token names live inside `[...]` — `]` (and newlines) would break the grammar.
    private var sanitizedName: String {
        name.replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// The token grammar shared by the editor highlighter, the preview parser, and the importer.
public enum AttachmentTokens {
    /// `![@kind:name](ccfile:hex16+)` — kind word intentionally open-ended (see Kind note).
    public static let pattern = #"!\[@([A-Za-z]+):([^\]]*)\]\(ccfile:([0-9a-f]{16,64})\)"#
    private static let re = try! NSRegularExpression(pattern: pattern)

    private static let sizeSuffix = try! NSRegularExpression(
        pattern: #"\s+size:(small|sm|medium|md|big|bg)\s*$"#, options: [.caseInsensitive]
    )

    /// All tokens in `text`, with their UTF-16 ranges. A trailing ` size:xxx` in the name
    /// parses OUT of the display name and into `token.size`.
    public static func matches(in text: String) -> [(range: NSRange, token: AttachmentToken)] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let kind = AttachmentToken.Kind(rawValue: ns.substring(with: m.range(at: 1))) ?? .file
            var name = ns.substring(with: m.range(at: 2))
            var size = AttachmentSize.medium
            let nameNS = name as NSString
            if let s = sizeSuffix.firstMatch(in: name,
                                             range: NSRange(location: 0, length: nameNS.length)) {
                size = AttachmentSize.parse(nameNS.substring(with: s.range(at: 1))) ?? .medium
                name = nameNS.substring(to: s.range.location)
            }
            return (m.range, AttachmentToken(kind: kind, name: name,
                                             id: ns.substring(with: m.range(at: 3)), size: size))
        }
    }

    /// The single token occupying the WHOLE (trimmed) line — the block-card form. nil if the
    /// line holds anything else.
    public static func blockToken(line: String) -> AttachmentToken? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let hits = matches(in: t)
        guard hits.count == 1, hits[0].range == NSRange(location: 0, length: (t as NSString).length)
        else { return nil }
        return hits[0].token
    }

    /// Every attachment id referenced anywhere in `text` (the derived-refcount primitive).
    public static func ids(in text: String) -> Set<String> {
        Set(matches(in: text).map(\.token.id))
    }
}

public enum AttachmentError: Error, LocalizedError {
    case tooLarge(bytes: Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case let .tooLarge(bytes):
            "That file is \(bytes / 1_000_000) MB — attachments are capped at \(AttachmentStore.maxBytes / 1_000_000) MB."
        case .unreadable: "That file could not be read."
        }
    }
}

/// One index row (files/index.json). Timestamps are ISO minutes, the app's house format.
public struct AttachmentMeta: Codable, Sendable, Equatable {
    public var name: String // original filename at first import
    public var uti: String // UTType identifier — the AUTHORITATIVE kind
    public var bytes: Int
    public var addedAt: String
    public var lastReferencedAt: String // the P3 sweep's grace-period clock
}

/// The content-addressed store. @MainActor and engine-owned (`engine.attachments`), like the
/// item store; instantiable with an explicit base dir for tests.
@MainActor public final class AttachmentStore {
    // nonisolated: read from LocalizedError descriptions (nonisolated contexts).
    public nonisolated static let maxBytes = 200_000_000 // hard refuse; UI warns at 50 MB first

    private let filesDir: URL
    private let blobsDir: URL
    public let thumbsDir: URL // disposable render cache (cards); cleared with its blob
    private let indexURL: URL
    private var index: [String: AttachmentMeta] // full sha256 → meta
    private var loaded = false
    /// Bumped whenever a blob ARRIVES (local import or a synced NoteFile adopting) — previews
    /// key their rebuild on it, so a "waiting for iCloud" card turns into content the moment
    /// the asset lands, with no note edit involved.
    public private(set) var generation = 0

    public init(baseDir: URL? = nil) {
        let root = baseDir ?? calendarKitBaseDir()
        filesDir = root.appendingPathComponent("files", isDirectory: true)
        blobsDir = filesDir.appendingPathComponent("blobs", isDirectory: true)
        thumbsDir = filesDir.appendingPathComponent("thumbs", isDirectory: true)
        indexURL = filesDir.appendingPathComponent("index.json")
        index = [:]
    }

    // ── Import ────────────────────────────────────────────────────────────────────────

    /// Import raw bytes (paste path). Dedup by SHA-256: the same content imported anywhere,
    /// any number of times, is one blob. Returns the ready-to-insert token.
    public func importData(_ raw: Data, suggestedName: String) throws -> AttachmentToken {
        ensureLoaded()
        guard !raw.isEmpty else { throw AttachmentError.unreadable }
        // Pasted screenshots arrive as TIFF; normalize to PNG BEFORE hashing so the same
        // screenshot pasted twice dedups. Other formats (png/jpg/gif/…) are never transcoded.
        var data = raw
        var name = suggestedName
        if utiFor(name: suggestedName, data: raw) == "public.tiff", let png = Self.tiffToPNG(raw) {
            data = png
            name = (suggestedName as NSString).deletingPathExtension + ".png"
        }
        guard data.count <= Self.maxBytes else { throw AttachmentError.tooLarge(bytes: data.count) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let uti = utiFor(name: name, data: data)
        if index[hash] == nil {
            try writeBlob(data, hash: hash, name: name, uti: uti)
        } else {
            index[hash]!.lastReferencedAt = Self.nowStamp()
            saveIndex()
        }
        return AttachmentToken(kind: Self.kind(forUTI: uti, name: name), name: name, id: shortId(hash))
    }

    /// Adopt a SYNCED blob (a fetched NoteFile's CKAsset): hash-verify the payload against the
    /// record's declared sha256 — a mismatched asset is dropped and logged, never stored —
    /// then land it in the CAS under the record's declared name/uti. True = the blob is
    /// available locally after the call (freshly adopted OR already present).
    public func adoptRemote(fileURL: URL, declaredHash: String, name: String, uti: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else {
            storeLog.error("attachment adopt FAILED (unreadable): \(name, privacy: .public)")
            return false
        }
        return adoptData(data, declaredHash: declaredHash, name: name, uti: uti)
    }

    /// Adopt raw bytes under a declared hash (the `.mgc` backup import path shares the sync
    /// path's verify-then-land contract): a payload that doesn't hash to its declaration is
    /// dropped and logged, never stored.
    public func adoptData(_ data: Data, declaredHash: String, name: String, uti: String) -> Bool {
        ensureLoaded()
        if index[declaredHash] != nil {
            return true // dedup: some other note/calendar already brought it in
        }
        guard !data.isEmpty, data.count <= Self.maxBytes else {
            storeLog.error("attachment adopt FAILED (empty/oversize): \(name, privacy: .public)")
            return false
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == declaredHash else {
            storeLog.error("attachment adopt REJECTED (hash mismatch): \(name, privacy: .public)")
            return false
        }
        do {
            try writeBlob(data, hash: hash, name: name, uti: uti)
            return true
        } catch {
            storeLog.error("attachment adopt write FAILED: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Resolve a token id (hash prefix) to the FULL sha256 — the sync layer's record names
    /// are `file-<full hash>`. nil = unknown here (blob not present, nothing to upload).
    public func resolveHash(forId id: String) -> String? {
        ensureLoaded()
        return fullHash(forId: id)
    }

    /// The whole index (hash → meta) — the inventory browser's join source.
    public func allEntries() -> [String: AttachmentMeta] {
        ensureLoaded()
        return index
    }

    /// Refresh the grace-period clock on a batch of sighted-as-referenced blobs (one index
    /// write). `at` is injectable so tests can BACKDATE a row into sweep range.
    public func touch(hashes: Set<String>, at date: Date = Date()) {
        ensureLoaded()
        let stamp = Self.stamp(date)
        var changed = false
        for h in hashes where index[h] != nil && index[h]?.lastReferencedAt != stamp {
            index[h]!.lastReferencedAt = stamp
            changed = true
        }
        if changed {
            saveIndex()
        }
    }

    /// A rendered page thumb (or its declined-sentinel) landed in thumbsDir: previews key
    /// their rebuild on `generation`, so without this bump a doc card would show
    /// "rendering preview…" forever while the finished page sat on disk.
    public func thumbsDidChange() {
        generation &+= 1
    }

    /// Test hook (internal): wreck a row's stamp so the sweep's parse-failure fail-safe
    /// ("unparseable = young, never delete") can be exercised.
    func corruptStampForTesting(hash: String) {
        ensureLoaded()
        index[hash]?.lastReferencedAt = "not-a-stamp"
    }

    /// Delete a blob outright — the browser's "remove unreferenced" action. Removes the blob,
    /// its export hardlinks, and the index entry. The CALLER owns the referenced-by-nothing
    /// check (references live in the notes, never here — see AttachmentInventory).
    public func remove(hash: String) {
        ensureLoaded()
        guard let meta = index[hash] else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: blobURL(hash: hash, name: meta.name))
        // Export handles are minted under token ids (hash PREFIXES, possibly several lengths
        // over the blob's lifetime) — sweep every export dir whose name prefixes this hash.
        let exportRoot = filesDir.appendingPathComponent("export", isDirectory: true)
        for dir in (try? fm.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: nil)) ?? []
            where hash.hasPrefix(dir.lastPathComponent) {
            try? fm.removeItem(at: dir)
        }
        // Rendered page thumbs (`thumbs/<hash>@<width>.png` + `.noThumb` sentinels) go too.
        for f in (try? fm.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil)) ?? []
            where f.lastPathComponent.hasPrefix(hash) {
            try? fm.removeItem(at: f)
        }
        index[hash] = nil
        saveIndex()
        generation &+= 1 // any card still pointing here repaints into its "missing" state
    }

    private func writeBlob(_ data: Data, hash: String, name: String, uti: String) throws {
        let dest = blobURL(hash: hash, name: name)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("tmp-\(UUID().uuidString.prefix(6))")
        try data.write(to: tmp)
        // A concurrent import of the same content may have landed the blob already.
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        index[hash] = AttachmentMeta(name: name, uti: uti, bytes: data.count,
                                     addedAt: Self.nowStamp(), lastReferencedAt: Self.nowStamp())
        saveIndex()
        generation &+= 1
    }

    /// Import a file from disk (drag path). Reads the bytes inside the caller's access window.
    public func importFile(_ url: URL) throws -> AttachmentToken {
        guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable }
        return try importData(data, suggestedName: url.lastPathComponent)
    }

    // ── Lookup ────────────────────────────────────────────────────────────────────────

    /// Resolve a token id (a hash PREFIX, ≥16 hex) to the blob's file URL. nil = missing
    /// (deleted, or not yet synced — P2's "downloading…" state).
    public func url(forId id: String) -> URL? {
        ensureLoaded()
        guard let hash = fullHash(forId: id), let meta = index[hash] else { return nil }
        let u = blobURL(hash: hash, name: meta.name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public func meta(forId id: String) -> AttachmentMeta? {
        ensureLoaded()
        return fullHash(forId: id).flatMap { index[$0] }
    }

    /// A DISPLAY-NAMED handle on the blob — `files/export/<id>/<original name>`, hardlinked
    /// (copy fallback) — so ⌘C→Finder-paste, Quick Look's title bar, and "open with default
    /// app" all show "proposal.pdf", never a hash. Disposable, recreated on demand.
    public func displayURL(forId id: String) -> URL? {
        guard let blob = url(forId: id), let meta = meta(forId: id) else { return nil }
        let dir = filesDir.appendingPathComponent("export", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let dest = dir.appendingPathComponent(meta.name)
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try FileManager.default.linkItem(at: blob, to: dest)
            } catch {
                try FileManager.default.copyItem(at: blob, to: dest) // cross-volume fallback
            }
            return dest
        } catch {
            storeLog.error("attachment export link FAILED: \(error.localizedDescription, privacy: .public)")
            return blob // worst case: the hash-named blob still previews
        }
    }

    /// A short unique id for the token: 16 hex chars, extended only on a prefix collision
    /// (astronomically unlikely; the index always holds the full hash).
    private func shortId(_ hash: String) -> String {
        var len = 16
        while len < 64 {
            let p = String(hash.prefix(len))
            if index.keys.filter({ $0.hasPrefix(p) }).count <= 1 {
                return p
            }
            len += 4
        }
        return hash
    }

    private func fullHash(forId id: String) -> String? {
        if index[id] != nil {
            return id
        } // full-hash id
        let hits = index.keys.filter { $0.hasPrefix(id) }
        return hits.count == 1 ? hits[0] : nil
    }

    private func blobURL(hash: String, name: String) -> URL {
        let ext = (name as NSString).pathExtension.lowercased()
        let leaf = ext.isEmpty ? hash : "\(hash).\(ext)"
        return blobsDir.appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(leaf)
    }

    // ── Kind / UTI classification ─────────────────────────────────────────────────────

    static let codeExts: Set<String> = ["md", "js", "ts", "jsx", "tsx", "c", "h", "cpp", "hpp",
                                        "rs", "go", "py", "jl", "swift", "java", "kt", "rb",
                                        "sh", "sql", "tex", "css", "toml", "html", "htm"]
    static let dataExts: Set<String> = ["json", "csv", "tsv", "xml", "txt", "yaml", "yml"]
    static let docExts: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf",
                                       "pages", "numbers", "key"]

    /// The token's display kind, from the authoritative UTI (+ extension for the text family,
    /// which UTIs lump together as plain text).
    public static func kind(forUTI uti: String, name: String = "") -> AttachmentToken.Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        #if canImport(UniformTypeIdentifiers)
            if let t = UTType(uti) {
                if t.conforms(to: .image) {
                    return .image
                }
                if t.conforms(to: .pdf) {
                    return .pdf
                }
            }
        #endif
        if codeExts.contains(ext) {
            return .code
        }
        if dataExts.contains(ext) {
            return .data
        }
        if docExts.contains(ext) {
            return .doc
        }
        return .file
    }

    private func utiFor(name: String, data: Data) -> String {
        #if canImport(UniformTypeIdentifiers)
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, let t = UTType(filenameExtension: ext) {
                return t.identifier
            }
        #endif
        // Extension-less: sniff the handful of magic numbers we care about.
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "public.png"
        }
        if data.starts(with: [0xFF, 0xD8]) {
            return "public.jpeg"
        }
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "com.adobe.pdf"
        }
        if data.starts(with: [0x4D, 0x4D]) || data.starts(with: [0x49, 0x49]) {
            return "public.tiff"
        }
        return "public.data"
    }

    private func kindFor(name: String, uti: String) -> AttachmentToken.Kind {
        Self.kind(forUTI: uti, name: name)
    }

    // ── Index persistence ─────────────────────────────────────────────────────────────

    private struct IndexFile: Codable {
        var version: Int
        var files: [String: AttachmentMeta]
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: indexURL),
           let f = try? JSONDecoder().decode(IndexFile.self, from: data) {
            index = f.files
        }
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(IndexFile(version: 1, files: index))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            storeLog.error("attachment index write FAILED: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func nowStamp() -> String {
        stamp(Date())
    }

    /// The index's timestamp form: "YYYY-MM-DDTHH:MM", local wall clock.
    static func stamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d",
                      c.year ?? 0, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
    }

    /// Parse an index stamp back to a Date (the sweep's grace-age check). nil on anything
    /// malformed — callers treat unparseable as "young" so a bad stamp can never cause a delete.
    static func date(fromStamp s: String) -> Date? {
        let halves = s.split(separator: "T")
        guard halves.count == 2 else { return nil }
        let d = halves[0].split(separator: "-").compactMap { Int($0) }
        let t = halves[1].split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2 else { return nil }
        var c = DateComponents()
        c.year = d[0]; c.month = d[1]; c.day = d[2]; c.hour = t[0]; c.minute = t[1]
        return Calendar.current.date(from: c)
    }

    /// TIFF → PNG via ImageIO (cross-platform; no AppKit in the engine).
    private static func tiffToPNG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
