// Minimal zip read/write for the `.mdc` backup, shelling out to the system `zip`/`unzip` (the app is
// non-sandboxed, so this is allowed and avoids a third-party archive dependency). DEFLATE by default,
// which keeps `.mdc` files readable by the web app's JSZip importer.

import Foundation

enum Zipper {
    /// Write `files` (zip-entry name → bytes) into a fresh DEFLATE zip at `dest`.
    static func write(_ files: [String: Data], to dest: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mdc-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (name, data) in files {
            let fileURL = tmp.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
        }
        try? FileManager.default.removeItem(at: dest) // `zip` APPENDS to an existing archive — start clean
        _ = try run("/usr/bin/zip", ["-r", "-q", "-X", dest.path, "."], cwd: tmp)
    }

    /// Extract a zip → (entry name → bytes). Entry names are relative paths (e.g. "database.json").
    static func read(_ src: URL) throws -> [String: Data] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mdc-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try run("/usr/bin/unzip", ["-q", "-o", src.path, "-d", tmp.path], cwd: nil)
        var out: [String: Data] = [:]
        let basePath = tmp.standardizedFileURL.path
        let base = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard let en = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: [.isRegularFileKey])
        else { return out }
        for case let f as URL in en {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let p = f.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            let rel = String(p.dropFirst(base.count))
            if let data = try? Data(contentsOf: f) {
                out[rel] = data
            }
        }
        return out
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String], cwd: URL?) throws -> String {
        #if os(macOS)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if let cwd {
                p.currentDirectoryURL = cwd
            }
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "Zipper", code: Int(p.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ??
                                  "archive tool failed"])
            }
            return String(data: data, encoding: .utf8) ?? ""
        #else
            // No Process/zip on iOS — .mgc backup import/export is a Mac feature; the phone
            // viewer never reaches this. Kept compiling so the shared engine links on iOS.
            throw NSError(domain: "Zipper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "zip archives are not supported on this platform"])
        #endif
    }
}
