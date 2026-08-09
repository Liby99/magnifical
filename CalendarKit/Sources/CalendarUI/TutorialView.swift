// The onboarding "tutorial" — a simple carousel of animated GIFs with captions. Shown once on first
// launch (see CalendarView's @AppStorage "cc.tutorial.seen") and re-openable from Help ▸ Tutorial. The
// body isn't really a tutorial: each slide is just a GIF demoing one gesture/feature.

import AppKit
import SwiftUI

/// One carousel slide: a GIF (loaded by name from the bundle's `tutorial/` folder) + a caption. The final
/// slide is a `welcome` card (app icon + a friendly sign-off) instead of a demo GIF.
struct TutorialSlide: Identifiable {
    let id = UUID()
    let gif: String // resource name without extension (see Resources/tutorial/README.md); "" for welcome
    let caption: String
    var welcome: Bool = false
}

struct TutorialView: View {
    let theme: Theme
    var ui: CalendarUIState // reads/writes ui.tutorialIndex (also driven by the key monitor)
    var onClose: () -> Void

    static let slides: [TutorialSlide] = [
        .init(gif: "pinch-zoom", caption: "Pinch to zoom into monthly, weekly, or daily view."),
        .init(gif: "band-year", caption: "Drag across days in the year view to create multi-day events."),
        .init(gif: "timed-week", caption: "Drag on the timeline to create timed events."),
        .init(gif: "ai-assistant", caption: "Click the AI button to let AI help you manage your calendar."),
        .init(gif: "markdown-notes", caption: "Edit markdown notes in events or the daily notepad to add TODO items."),
        .init(
            gif: "dashboard-tour",
            caption: "Every day, week, and month has a dashboard — press ⌘B for its TODO list, and click PROJ for per-project Gantt charts."
        ),
        .init(
            gif: "",
            caption: "That's the tour — your calendar is ready. Enjoy planning your time with MagnifiCal!",
            welcome: true
        ),
    ]

    // The demo GIFs span aspect ratios from ~4.3:1 (year band) to ~0.85:1 (AI panel). A landscape stage
    // (wider than tall) lets the very-wide clips stay legible while still fitting the tall ones; each GIF is
    // contained within it. (A square stage would shrink the wide clips to a sliver.)
    static let stageW: CGFloat = 620
    static let stageH: CGFloat = 440

    private var idx: Int {
        min(max(0, ui.tutorialIndex), Self.slides.count - 1)
    }

    private var isLast: Bool {
        idx == Self.slides.count - 1
    }

    var body: some View {
        ZStack {
            // Dimmed backdrop — the CatcherView's modal guards also block the canvas behind it. Tap closes.
            Color.black.opacity(0.28).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 18) {
                HStack {
                    Text("Getting Started").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textMuted)
                    Spacer()
                    Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(theme.textMuted)
                        .help("Close")
                }

                // The stage — a fixed-size area. Demo slides CONTAIN a GIF (fit to its own aspect ratio,
                // never cropped, border hugging the image); the final slide is the welcome card.
                Group {
                    if Self.slides[idx].welcome {
                        WelcomeStage(theme: theme)
                    } else {
                        GIFStage(name: Self.slides[idx].gif, theme: theme)
                    }
                }
                .frame(width: Self.stageW, height: Self.stageH)
                .id(idx) // swap the NSImageView when the slide changes
                .transition(.opacity)

                Text(Self.slides[idx].caption)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.stageW - 40)
                    .fixedSize(horizontal: false, vertical: true)

                // Page dots
                HStack(spacing: 7) {
                    ForEach(Self.slides.indices, id: \.self) { i in
                        Circle().fill(i == idx ? theme.text : theme.text.opacity(0.22))
                            .frame(width: 6, height: 6)
                            .onTapGesture { go(to: i) }
                    }
                }

                HStack {
                    Button("Back") { go(to: idx - 1) }
                        .disabled(idx == 0)
                    Spacer()
                    Button(isLast ? "Done" : "Next") {
                        if isLast {
                            onClose()
                        } else {
                            go(to: idx + 1)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .frame(width: Self.stageW)
            }
            .padding(28)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
            .fixedSize()
            .animation(.easeOut(duration: 0.18), value: ui.tutorialIndex)
        }
    }

    private func go(to i: Int) {
        ui.tutorialIndex = min(max(0, i), Self.slides.count - 1)
    }
}

/// The final slide: the MagnifiCal app icon + a welcome heading, centered (the friendly sign-off is the
/// caption rendered below the stage). Plain SwiftUI, so it centers cleanly in the fixed stage.
private struct WelcomeStage: View {
    let theme: Theme
    var body: some View {
        VStack(spacing: 22) {
            if let img = Self.appIcon() {
                Image(nsImage: img)
                    .resizable().interpolation(.high)
                    .frame(width: 150, height: 150) // the icon already has rounded corners + margins
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: 96)).foregroundStyle(Theme.accent)
            }
            Text("Welcome to MagnifiCal")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ALWAYS the latest icon: the running app's real icon when it has an asset-catalog one (kept
    /// current by every rebuild), else the bundled snapshot — the unsigned dev shell has no asset
    /// catalog, and its snapshot is refreshed by scripts/gen-icons.sh alongside the iconset.
    private static func appIcon() -> NSImage? {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil {
            return NSApp.applicationIconImage
        }
        if let url = Bundle.module.url(forResource: "app-icon", withExtension: "png", subdirectory: "tutorial") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

/// The GIF display area: an animating NSImageView loaded from the bundle, or a placeholder when the GIF
/// isn't present yet (so the carousel is fully usable before the assets are added). Each demo ships in
/// LIGHT and DARK variants ("<name>-light.gif"/"-dark.gif"); the one matching the viewer's theme is shown
/// (plain "<name>.gif" is the single-variant fallback).
private struct GIFStage: View {
    let name: String
    let theme: Theme

    private var url: URL? {
        Bundle.module.url(
            forResource: "\(name)-\(theme.dark ? "dark" : "light")",
            withExtension: "gif",
            subdirectory: "tutorial"
        )
            ?? Bundle.module.url(forResource: name, withExtension: "gif", subdirectory: "tutorial")
    }

    var body: some View {
        if let url,
           let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 {
            // Fit to the GIF's OWN aspect ratio within the stage, centered — the rounded border wraps the
            // image itself (no letterbox bars), so nothing is cropped whatever the clip's dimensions are.
            // No frame here: the parent's fixed .frame(stageW, stageH) centers this aspect-fit view.
            AnimatedGIFView(image: img)
                .aspectRatio(img.size.width / img.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                    theme.sep.opacity(0.4),
                    lineWidth: 1
                ))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.text.opacity(0.06))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 30))
                        .foregroundStyle(theme.textMuted)
                    Text("Demo GIF").font(.system(size: 12)).foregroundStyle(theme.textMuted)
                })
        }
    }
}

/// Wraps NSImageView so a multi-frame GIF actually animates (SwiftUI.Image renders only the first frame).
private struct AnimatedGIFView: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.image = image
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.canDrawSubviewsIntoLayer = true
        // Don't let the view's native pixel size (e.g. 840px) drive SwiftUI layout — the SwiftUI
        // aspectRatio + parent frame decide the size; the image just fills whatever it's given.
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image !== image {
            v.image = image; v.animates = true
        }
    }
}
