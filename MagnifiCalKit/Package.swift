// swift-tools-version: 6.0
import PackageDescription

/// CalendarKit — native Swift port of the web calendar.
///
/// Layering (dependencies point one way, toward purity):
///   CalendarGeometry  ← pure math, no dependencies (Foundation + CoreGraphics)
///   CalendarEngine    ← @Observable view-state + tween clock   (→ Geometry)
///   CalendarRender    ← portable Canvas renderer + glass overlays (→ Geometry, Engine)
///   CalendarUI        ← AppKit input/editing/chrome + views     (→ Geometry, Engine, Render)
///   CalendarMac       ← macOS app bootstrap (executable)        (→ UI)
///
/// Floor is macOS 15 (Sequoia) so Intel-era Macs that can't run 26 still work: all
/// Liquid Glass call sites route through GlassCompat.swift (CalendarRender), which
/// uses the real .glassEffect on 26+ and a material-frost fallback below. Going
/// lower than 15 would mean backporting onScrollGeometryChange (the pager scroll
/// drivers) — don't, without a plan for that. Language mode is held at v5 for now
/// to avoid strict-concurrency churn.
///
/// iOS 26 is a supported platform: the iPhone app links CalendarEngine (which carries
/// the CloudKit sync layer) and CalendarRender (the platform-neutral scene renderer —
/// Canvas passes + glass event/deadline overlays + Theme). CalendarUI/CalendarMac use
/// AppKit and are only built when their product is requested (the macOS app), so they
/// never compile for iOS.
let package = Package(
    name: "MagnifiCalKit",
    platforms: [.macOS("15.0"), .iOS("26.0")],
    products: [
        .library(name: "CalendarGeometry", targets: ["CalendarGeometry"]),
        .library(name: "CalendarEngine", targets: ["CalendarEngine"]),
        .library(name: "CalendarRender", targets: ["CalendarRender"]),
        .library(name: "CalendarUI", targets: ["CalendarUI"]),
        .executable(name: "CalendarMac", targets: ["CalendarMac"]),
        .executable(name: "assistant-eval", targets: ["AssistantEvalRunner"]),
    ],
    targets: [
        .target(name: "CalendarGeometry"),
        .target(name: "CalendarEngine", dependencies: ["CalendarGeometry"]),
        .target(name: "CalendarRender", dependencies: ["CalendarGeometry", "CalendarEngine"]),
        .target(name: "CalendarUI", dependencies: ["CalendarGeometry", "CalendarEngine", "CalendarRender"],
                resources: [.copy("Resources/editor"), // bundled WKWebView notes editor (see webeditor/)
                            .copy("Resources/tutorial")]), // onboarding carousel GIFs (see TutorialView)
        .executableTarget(name: "CalendarMac", dependencies: ["CalendarUI"]),
        .executableTarget(name: "AssistantEvalRunner", dependencies: ["CalendarUI"]),
        .testTarget(name: "CalendarGeometryTests", dependencies: ["CalendarGeometry"]),
        .testTarget(name: "CalendarRenderTests", dependencies: ["CalendarRender", "CalendarEngine", "CalendarGeometry"]),
        .testTarget(name: "CalendarEngineTests", dependencies: ["CalendarEngine", "CalendarGeometry"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
