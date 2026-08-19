// Demo media for the Tutorial carousel + Help browser. The Welcome slides ship IN the bundle
// (first launch must work offline); everything else — the Help-only demo clips and screenshots —
// lives in the public repo (MagnifiCalKit/media/help/) and is fetched on first view, cached on
// disk, keyed to this build's release tag. Clips are H.264 .mp4 (5–10× smaller than the GIFs they
// replaced), played by LoopingVideo; stills are pngquant-crushed PNGs.
//
// Resolution order everywhere: bundle → disk cache → GitHub raw at the pinned ref. Theme variants
// follow the house convention: "<name>-light/-dark.<ext>" first, plain "<name>.<ext>" fallback.

import AppKit
import AVFoundation
import SwiftUI

enum HelpMedia {
    /// Bundle lookup (Resources/tutorial): the six Welcome slides + app icon.
    static func bundled(_ name: String, ext: String, dark: Bool) -> URL? {
        Bundle.module.url(forResource: "\(name)-\(dark ? "dark" : "light")", withExtension: ext,
                          subdirectory: "tutorial")
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "tutorial")
    }

    /// The git ref remote assets are pinned to: the release tag for a real build (the release flow
    /// syncs the public repo and re-points the tag at it, so a v-tag always has this build's
    /// assets), `main` for dev shells (no real version set).
    static let remoteRef: String = {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
            return "v\(v)"
        }
        return "main"
    }()

    static func remoteURL(file: String) -> URL {
        URL(
            string: "https://raw.githubusercontent.com/Liby99/magnifical/\(remoteRef)/MagnifiCalKit/media/help/\(file)"
        )!
    }

    /// Per-ref cache dir — a new release naturally re-fetches; old refs are small and rare enough
    /// that the system's cache pruning handles them.
    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagnifiCal/help-media/\(remoteRef)", isDirectory: true)
    }

    /// Resolve a media name to a playable/displayable local URL, or nil when it's neither bundled,
    /// cached, nor reachable (the views show an offline placeholder then).
    static func resolve(_ name: String, ext: String, dark: Bool) async -> URL? {
        if let b = bundled(name, ext: ext, dark: dark) {
            return b
        }
        let candidates = ["\(name)-\(dark ? "dark" : "light").\(ext)", "\(name).\(ext)"]
        for file in candidates {
            let local = cacheDir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: local.path) {
                return local
            }
        }
        for file in candidates {
            if let fetched = await download(file) {
                return fetched
            }
        }
        return nil
    }

    private static func download(_ file: String) async -> URL? {
        guard let (tmp, resp) = try? await URLSession.shared.download(from: remoteURL(file: file)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let dest = cacheDir.appendingPathComponent(file)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}

// ── Views ────────────────────────────────────────────────────────────────────────────────────────

/// A demo clip sized to its own aspect ratio: resolves the mp4 (bundle → cache → remote), reads the
/// asset's natural size, and loops it chromeless. While resolving: a quiet pulsing placeholder; when
/// unreachable: an offline note. `bundledOnly` skips the network (the Tutorial's slides — a missing
/// slide there is a build problem, not a connectivity one).
struct DemoClip: View {
    let name: String
    let dark: Bool
    var bundledOnly = false

    @State private var resolved: URL?? = .none // .none = resolving, .some(nil) = unavailable
    @State private var aspect: CGFloat = 16.0 / 9.0

    var body: some View {
        Group {
            switch resolved {
            case .none:
                placeholder { ProgressView().controlSize(.small) }
            case .some(nil):
                placeholder {
                    VStack(spacing: 8) {
                        Image(systemName: bundledOnly ? "play.rectangle.on.rectangle" : "wifi.slash")
                            .font(.system(size: 26)).foregroundStyle(.secondary)
                        Text(bundledOnly ? "Demo unavailable" : "Demo needs an internet connection")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            case let .some(.some(url)):
                LoopingVideo(url: url)
                    .aspectRatio(aspect, contentMode: .fit)
            }
        }
        .task(id: "\(name)|\(dark)") {
            let url = bundledOnly
                ? HelpMedia.bundled(name, ext: "mp4", dark: dark)
                : await HelpMedia.resolve(name, ext: "mp4", dark: dark)
            if let url,
               let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               size.width > 0, size.height > 0 {
                aspect = size.width / size.height
            }
            resolved = .some(url)
        }
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05))
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(content())
    }
}

/// A help screenshot: resolves the PNG the same way (these are never bundled) and renders it at its
/// own aspect ratio.
struct RemoteStill: View {
    let name: String
    let dark: Bool

    @State private var image: NSImage?? = .none

    var body: some View {
        Group {
            switch image {
            case .none:
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
            case .some(nil):
                EmptyView() // a missing still just collapses — the topic text stands alone
            case let .some(.some(img)):
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(img.size.width / max(1, img.size.height), contentMode: .fit)
            }
        }
        .task(id: "\(name)|\(dark)") {
            let url = await HelpMedia.resolve(name, ext: "png", dark: dark)
            image = .some(url.flatMap { NSImage(contentsOf: $0) })
        }
    }
}

/// Chromeless, muted, infinitely-looping video — the mp4 replacement for the animated-GIF
/// NSImageView. AVPlayerLayer as the backing layer; AVPlayerLooper handles gapless restarts.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    final class PlayerView: NSView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var current: URL?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        @available(*, unavailable) required init?(coder _: NSCoder) {
            fatalError()
        }

        override func makeBackingLayer() -> CALayer {
            let l = AVPlayerLayer()
            l.videoGravity = .resizeAspect
            return l
        }

        func load(_ url: URL) {
            guard url != current else { return }
            current = url
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
            (layer as? AVPlayerLayer)?.player = queue
            player = queue
            queue.play()
        }
    }

    func makeNSView(context _: Context) -> PlayerView {
        let v = PlayerView(frame: .zero)
        v.load(url)
        return v
    }

    func updateNSView(_ v: PlayerView, context _: Context) {
        v.load(url)
    }
}
