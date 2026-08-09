// CC_TRACE=1: the interaction-trace profiler — records the USER'S OWN session (not a bench
// scene): every frame eval with animation state (z, dashPin), every input event (scrolls,
// clicks, pinches, hotkeys), and continuous ~100Hz main-thread stack samples (the watchdog's
// suspend + fp-walk machinery, promoted to a sampling profiler). Dumped to a trace file on
// app-resign (⌘-tab away after reproducing lag) and every 60s — the analyzer folds it into
// per-interaction flamegraphs aligned with frame rate.
//
// REMOVABLE BY CONSTRUCTION: everything is gated on the CC_TRACE environment variable (one
// boolean check per hook when absent); no release scheme sets it. Delete this file + the four
// one-line hooks to remove entirely.
//
// Trace format (line-oriented, t = ms since trace start):
//   # header
//   E <t> <label>          input/action event
//   F <t> <z> <pin>        one frame eval, with the animation state it rendered
//   D <t>                  one display-link tick (a frame the DISPLAY actually presented)
//   S <t> <a1> <a2> …      one main-thread sample, leaf-first, hex addresses
//   Y <addr> <symbol>      symbol table (dumped once at the end)

import AppKit
import CalendarEngine
import Darwin
import Foundation

@MainActor
final class CCTrace {
    static let on = ProcessInfo.processInfo.environment["CC_TRACE"] != nil
    static let shared = CCTrace()

    private var started = false
    private var t0 = Date()
    private var lines: [String] = []
    private let sampler = TraceSampler()
    private var lastAutosave = Date()

    // ── Hooks ────────────────────────────────────────────────────────────────────────────────

    static func frame(_ engine: CalendarEngine) {
        guard on else { return }
        shared.recordFrame(engine)
    }

    static func event(_ label: String) {
        guard on else { return }
        shared.ensureStarted()
        shared.lines.append("E \(shared.ts()) \(label)")
    }

    /// Explicit dump (bench scenes flush at scene end — no resign-active in a scripted run).
    static func dumpNow(_ reason: String) {
        guard on else { return }
        shared.dump(reason: reason)
    }

    // ── Recording ────────────────────────────────────────────────────────────────────────────

    private func recordFrame(_ engine: CalendarEngine) {
        ensureStarted()
        if displayLink == nil {
            attachDisplayLinkIfPossible()
        }
        lines.append(String(format: "F %@ %.3f %.3f", ts(), engine.z, engine.dashPin))
        sampler.noteFrame()
        if lines.count > 400_000 {
            lines.removeFirst(100_000)
        } // rolling window
        if Date().timeIntervalSince(lastAutosave) > 60 {
            lastAutosave = Date()
            dump(reason: "autosave")
        }
    }

    private func ensureStarted() {
        guard !started else { return }
        started = true
        t0 = Date()
        sampler.start(mainPort: pthread_mach_thread_np(pthread_self()))
        lines.reserveCapacity(400_000)
        lines.append("# cc-trace v1 start=\(ISO8601DateFormatter().string(from: t0))")
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CCTrace.shared.dump(reason: "resign-active") }
        }
        NotificationCenter.default.addObserver(
            forName: .ccTraceClock, object: nil, queue: .main
        ) { note in
            let awake = (note.object as? Bool) ?? false
            MainActor.assumeIsolated {
                CCTrace.shared.lines.append(
                    "E \(CCTrace.shared.ts()) \(awake ? "clockAwake" : "clockAsleep")"
                )
            }
        }
        attachDisplayLinkIfPossible()
        installCommitTimer()
        print("[cc-trace] recording — reproduce the lag, then ⌘-tab away to flush the trace")
    }

    /// Times Core Animation's main-thread COMMIT phase: two runloop observers bracket CA's
    /// own BeforeWaiting transaction observer (CA registers at order 2,000,000 — a classic
    /// technique), emitting "C <t> <ms>" for any commit over 8ms. Long commits that align
    /// with display-link gaps = the commit contents are the stall; display gaps WITHOUT long
    /// commits = window-server backpressure.
    private var commitBegan: CFAbsoluteTime = 0

    private func installCommitTimer() {
        let before = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999
        ) { _, _ in
            MainActor.assumeIsolated { CCTrace.shared.commitBegan = CFAbsoluteTimeGetCurrent() }
        }
        let after = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001
        ) { _, _ in
            MainActor.assumeIsolated {
                let began = CCTrace.shared.commitBegan
                guard began > 0 else { return }
                CCTrace.shared.commitBegan = 0
                let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
                if ms > 8 {
                    CCTrace.shared.lines.append(
                        "E \(CCTrace.shared.ts()) commit \(String(format: "%.0f", ms))ms"
                    )
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), before, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), after, .commonModes)
    }

    /// DISPLAY-side truth: a CADisplayLink on the main window's content view ticks once per
    /// frame the window is actually offered by the display — comparing its cadence (D lines)
    /// against content evaluations (F lines) separates "SwiftUI evaluated fast" from "the
    /// screen actually updated fast". The first frame eval predates the WINDOW, so this
    /// retries from recordFrame until a window exists.
    private func attachDisplayLinkIfPossible() {
        // Fall back to ANY window: a scene-driven app launched from a script may never become
        // key (cooperative activation), and without the fallback a whole run records zero
        // D lines — which reads as "no display data", not "smooth".
        guard displayLink == nil,
              let win = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let v = win.contentView
        else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: win, queue: .main
        ) { [weak win] _ in
            MainActor.assumeIsolated {
                let vis = win?.occlusionState.contains(.visible) == true
                CCTrace.shared.lines.append("E \(CCTrace.shared.ts()) occlusion \(vis ? "visible" : "hidden")")
            }
        }
        lines.append("E \(ts()) occlusion \(win.occlusionState.contains(.visible) ? "visible" : "hidden") (initial)")
        let link = v.displayLink(target: displayTicker, selector: #selector(DisplayTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let maxFPS = v.window?.screen?.maximumFramesPerSecond ?? -1
        lines.append("E \(ts()) displayLinkStart maxFPS=\(maxFPS)")
        print("[cc-trace] display link attached (screen maxFPS \(maxFPS))")
    }

    private var displayLink: CADisplayLink?
    private var occlusionObserver: Any?
    private let displayTicker = DisplayTicker()

    /// Appends a "D <t>" line per display-link tick (only while frames flowed recently — the
    /// link pauses itself makes no sense to filter here; volume is fine for a 60s trace).
    final class DisplayTicker: NSObject {
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated {
                CCTrace.shared.lines.append("D \(CCTrace.shared.ts())")
            }
        }
    }

    private func ts() -> String {
        String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)
    }

    // ── Dump ─────────────────────────────────────────────────────────────────────────────────

    private func dump(reason: String) {
        let samples = sampler.snapshot()
        var out = lines
        out.reserveCapacity(out.count + samples.count + 4096)
        var uniq = Set<UInt64>()
        for s in samples {
            var line = "S " + String(format: "%.1f", s.t * 1000)
            for a in s.addrs {
                line += " " + String(a, radix: 16)
                uniq.insert(a)
            }
            out.append(line)
        }
        // Symbol table (dladdr once per unique address).
        for a in uniq {
            var info = Dl_info()
            if let p = UnsafeRawPointer(bitPattern: UInt(a)), dladdr(p, &info) != 0,
               let sym = info.dli_sname {
                out.append("Y \(String(a, radix: 16)) \(String(cString: sym))")
            }
        }
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent(
            "cc-trace-\(Int(t0.timeIntervalSince1970)).trace"
        )
        try? out.joined(separator: "\n").appending("\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        print("[cc-trace] \(reason): \(out.count) lines → \(path)")
    }
}

/// Background sampling thread: ~100Hz main-thread stacks while frames are (or recently were)
/// flowing — captures both healthy frames and the blocks between them; skips deep idle.
final class TraceSampler: @unchecked Sendable {
    struct Sample {
        let t: TimeInterval // seconds since trace start
        let addrs: [UInt64]
    }

    private var mainPort: mach_port_t = 0
    private var t0 = Date()
    private var lastFrame: CFAbsoluteTime = 0
    private let lock = NSLock()
    private var buf: [Sample] = []

    func noteFrame() {
        lastFrame = CFAbsoluteTimeGetCurrent()
    }

    func start(mainPort port: mach_port_t) {
        mainPort = port
        t0 = Date()
        let t = Thread { [self] in loop() }
        t.name = "cc-trace-sampler"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func snapshot() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return buf
    }

    private func loop() {
        while true {
            usleep(10000) // ~100Hz
            // Sample while frames flowed within the last 2s: covers interactions AND the
            // blocks that stall them; skips deep idle (no pointless suspends).
            guard CFAbsoluteTimeGetCurrent() - lastFrame < 2.0 else { continue }
            guard let s = captureMainStack() else { continue }
            lock.lock()
            buf.append(s)
            if buf.count > 30000 {
                buf.removeFirst(6000)
            } // ~5min rolling
            lock.unlock()
        }
    }

    /// mach/arm/thread_status.h layout, local (see DashWatchdog: not exposed in all contexts).
    private struct ARMThreadState64 {
        var x: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                                           0, 0, 0, 0, 0, 0, 0, 0, 0)
        var fp: UInt64 = 0
        var lr: UInt64 = 0
        var sp: UInt64 = 0
        var pc: UInt64 = 0
        var cpsr: UInt32 = 0
        var flags: UInt32 = 0
    }

    private func captureMainStack() -> Sample? {
        #if arch(arm64)
            var addrs = [UInt64]()
            addrs.reserveCapacity(208)
            guard thread_suspend(mainPort) == KERN_SUCCESS else { return nil }
            var state = ARMThreadState64()
            var count = mach_msg_type_number_t(
                MemoryLayout<ARMThreadState64>.size / MemoryLayout<natural_t>.size
            )
            let kr = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                    thread_get_state(mainPort, 6 /* ARM_THREAD_STATE64 */, $0, &count)
                }
            }
            if kr == KERN_SUCCESS {
                let mask: UInt64 = 0x0000_7FFF_FFFF_FFFF
                addrs.append(state.pc & mask)
                var fp = state.fp & mask
                while addrs.count < 200, fp > 0x1000, fp % 8 == 0 {
                    guard let p = UnsafeRawPointer(bitPattern: UInt(fp)) else { break }
                    let nextFP = p.load(as: UInt64.self) & mask
                    let lr = p.load(fromByteOffset: 8, as: UInt64.self) & mask
                    if lr <= 0x1000 {
                        break
                    }
                    addrs.append(lr)
                    if nextFP <= fp {
                        break
                    }
                    fp = nextFP
                }
            }
            thread_resume(mainPort)
            guard !addrs.isEmpty else { return nil }
            return Sample(t: Date().timeIntervalSince(t0), addrs: addrs)
        #else
            return nil
        #endif
    }
}
