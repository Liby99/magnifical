// Attachment space reclamation (design §7): derived references + a 7-DAY GRACE PERIOD, and
// deletion only at their intersection — an index row nobody references whose last sighting is
// old. The grace window is what makes "remove the token, then ⌘Z tomorrow" and "delete on the
// Mac while the laptop's note edit is still syncing" safe; immediate-delete is explicitly
// rejected (the browser's Remove Unreferenced button is the user-invoked exception). The
// automatic pass runs shortly after launch, at most once per calendar day.

import CalendarGeometry // isoDayString
import Foundation

public struct AttachmentSweepResult: Sendable, Equatable {
    public var swept = 0 // deleted: unreferenced AND past grace
    public var sweptBytes = 0
    public var inGrace = 0 // unreferenced but sighted too recently to delete
    public var referenced = 0
}

public extension CalendarEngine {
    /// The grace period before an unreferenced blob is reclaimed. 7 days; overridable for
    /// field testing with CC_ATTACH_GRACE_MIN=<minutes> (same spirit as the CC_* bench envs).
    static var attachmentSweepGrace: TimeInterval {
        if let m = ProcessInfo.processInfo.environment["CC_ATTACH_GRACE_MIN"], let v = Double(m) {
            return v * 60
        }
        return 7 * 24 * 3600
    }

    /// One sweep pass over the whole store, references counted across ALL calendars (the same
    /// scan the browser shows, so the sweep can never disagree with it): referenced rows get
    /// their grace clock refreshed; unreferenced rows older than the grace period are deleted
    /// (blob + export links + index row). The per-calendar NoteFile sync deletes are NOT the
    /// sweep's job — the delta layer emitted them when the last reference left the note.
    /// `now` is injectable for tests.
    @discardableResult
    func sweepAttachments(now: Date = Date()) -> AttachmentSweepResult {
        var r = AttachmentSweepResult()
        var sighted: Set<String> = []
        for row in attachmentInventory() {
            guard let meta = row.meta else { continue } // ghost: no local blob, nothing to sweep
            if !row.refs.isEmpty {
                sighted.insert(row.id)
                r.referenced += 1
            } else if let last = AttachmentStore.date(fromStamp: meta.lastReferencedAt),
                      now.timeIntervalSince(last) > Self.attachmentSweepGrace {
                attachments.remove(hash: row.id)
                r.swept += 1
                r.sweptBytes += meta.bytes
            } else {
                r.inGrace += 1 // young — or an unparseable stamp, which must never delete
            }
        }
        attachments.touch(hashes: sighted, at: now) // sightings restart the grace clock
        storeLog.notice("""
        attachment sweep: \(r.swept) deleted (\(r.sweptBytes) bytes), \
        \(r.inGrace) in grace, \(r.referenced) referenced
        """)
        return r
    }

    /// The automatic form: kicked from engine init, runs one sweep ~30s after launch (idle by
    /// then), at most once per calendar day. Inert in demo recordings and under tests (both
    /// redirect the store), and only the LIVE engine sweeps — SwiftUI's throwaway engines don't.
    func scheduleAttachmentSweep() {
        guard !Self.isDemoMode,
              ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, Self.mainInstance === self else { return }
            let key = "cc.attachments.lastSweepDay"
            let today = isoDayString()
            guard UserDefaults.standard.string(forKey: key) != today else { return }
            UserDefaults.standard.set(today, forKey: key)
            self.sweepAttachments()
        }
    }
}
