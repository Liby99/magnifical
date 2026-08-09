// Bench payload staging: wipe a throwaway store dir and drop the fixture at <dir>/data.json —
// the same root-file contract bench-year.sh stages on the Mac, which the store's legacy
// single-file migration picks up on load. The phone app calls this in init() BEFORE the
// engine is constructed (staging after the store loads would be too late).

import Foundation

public enum BenchStaging {
    public static func stage(fixture: URL, into dir: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: fixture, to: dir.appendingPathComponent("data.json"))
    }
}
