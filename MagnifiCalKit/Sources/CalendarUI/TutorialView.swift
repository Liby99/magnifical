// The onboarding "tutorial" — a simple carousel of looping demo clips with captions. Shown once on
// first launch (see CalendarView's @AppStorage "cc.tutorial.seen") and re-openable from Help ▸
// Tutorial. The body isn't really a tutorial: each slide is just a clip demoing one gesture/feature.

import AppKit
import SwiftUI

/// One carousel slide: an mp4 demo clip (loaded by name from the bundle's `tutorial/` folder —
/// slides are BUNDLED so first launch works offline; see HelpMedia.swift) + a caption. The final
/// slide is a `welcome` card (app icon + a friendly sign-off) instead of a demo clip.
struct TutorialSlide: Identifiable {
    let id = UUID()
    let gif: String // media name without extension (see Resources/tutorial/README.md); "" for welcome
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

    // The demo clips span aspect ratios from ~4.3:1 (year band) to ~0.85:1 (AI panel). A landscape stage
    // (wider than tall) lets the very-wide clips stay legible while still fitting the tall ones; each clip
    // is contained within it. (A square stage would shrink the wide clips to a sliver.)
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

                // The stage — a fixed-size area. Demo slides CONTAIN a clip (fit to its own aspect ratio,
                // never cropped, border hugging the video); the final slide is the welcome card.
                Group {
                    if Self.slides[idx].welcome {
                        WelcomeStage(theme: theme)
                    } else {
                        DemoClip(name: Self.slides[idx].gif, dark: theme.dark, bundledOnly: true)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                                theme.sep.opacity(0.4),
                                lineWidth: 1
                            ))
                            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                    }
                }
                .frame(width: Self.stageW, height: Self.stageH)
                .id(idx) // swap the player when the slide changes
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
