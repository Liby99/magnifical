// Colors for the calendar. Structural colors (background, text, lines/borders) come
// straight from the system palette so the app matches the OS light/dark theme
// automatically — a near-black/dark-gray content background with white-to-light-gray
// lines in dark mode, and the mirror in light mode. Only two things are colored: the
// event stickers (their own palette) and the red now/today accent.
//
// Lives in CalendarRender so the iPhone client shares it: AppKit resolves system colors
// via NSAppearance, UIKit via UITraitCollection — same resolved sRGB values either way.

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// The user-selectable accent (Settings ▸ Appearance). Cached so the per-render Theme builds
/// never touch UserDefaults; `set` persists, updates the cache, and posts the view-prefs
/// notification (→ engine.viewPrefsChanged → repaint).
public enum AccentPref {
    public static let key = "cc.accentHex"
    public static let defaultHex: UInt32 = 0xFF3B6B // MagnifiCal red
    /// The alternatives row in Settings (name, hex).
    public static let alternatives: [(name: String, hex: UInt32)] = [
        ("Blue", 0x007AFF), // Apple system blue
        ("Purple", 0xAF52DE),
        ("Red", 0xD70015), // big red
        ("Pink", 0xFF2D55),
        ("Orange", 0xFF9500),
        ("Forest Green", 0x0E8A3E), // saturated forest green
        ("Cyan Blue", 0x32ADE6), // cyan-leaning blue
    ]
    private nonisolated(unsafe) static var cached: UInt32 = {
        let v = UserDefaults.standard.integer(forKey: key)
        return v == 0 ? defaultHex : UInt32(truncatingIfNeeded: v)
    }()

    public static var hex: UInt32 {
        cached
    }

    public static func set(_ h: UInt32) {
        cached = h
        UserDefaults.standard.set(Int(h), forKey: key)
        NotificationCenter.default.post(name: .calendarViewPrefsChanged, object: nil)
    }
}

public struct Theme {
    /// The app-wide accent (now-line, selection pills, send button, …). User-selectable in
    /// Settings ▸ Appearance; SINGLE source of truth — never hardcode an accent hex elsewhere.
    public static var accent: Color {
        Color(hex: AccentPref.hex)
    }

    public let dark: Bool // only affects the event palette; structural colors are system-native

    // Structural colors — resolved ONCE per render from the system palette against the
    // correct appearance. (SwiftUI.Canvas resolves dynamic system colors against the
    // light appearance regardless of the window, so we must resolve them to concrete
    // colors ourselves; otherwise dark mode shows light-mode colors.)
    public let bg: Color
    public let text: Color
    public let textMuted: Color
    public let accentDark: Color
    public let accentGrey: Color
    public let sep: Color
    public let gridLine: Color
    public let cellGrid: Color
    public let dimFill: Color
    public let weekendWash: Color
    public let highlight: Color
    public let cursor: Color
    public let nowLine: Color
    public let todayTint: Color
    public let todayMonthWash: Color
    // Multiplier on the event-sticker tint opacity. Dark mode is already colorful at the
    // BandStyle base opacities; light mode washes out (a saturated hue at 20% over white
    // reads pale), so we boost it there only.
    public let eventTintScale: Double

    public init(dark: Bool) {
        self.dark = dark
        #if canImport(AppKit)
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? .currentDrawing()
            func sys(_ ns: NSColor) -> Color {
                var out = Color.clear
                appearance.performAsCurrentDrawingAppearance {
                    if let c = ns.usingColorSpace(.sRGB) {
                        out = Color(.sRGB, red: Double(c.redComponent), green: Double(c.greenComponent),
                                    blue: Double(c.blueComponent), opacity: Double(c.alphaComponent))
                    }
                }
                return out
            }
            let label = sys(.labelColor) // white in dark, near-black in light
            bg = sys(.textBackgroundColor) // content background (near-black / white)
            textMuted = sys(.secondaryLabelColor)
        #else
            let trait = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            func sys(_ ui: UIColor) -> Color {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                ui.resolvedColor(with: trait).getRed(&r, green: &g, blue: &b, alpha: &a)
                return Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
            }
            let label = sys(.label) // white in dark, near-black in light
            bg = sys(.systemBackground) // content background (near-black / white)
            textMuted = sys(.secondaryLabel)
        #endif
        // Text: keep the bright system label in dark mode; in light mode the system label is
        // effectively pure black, which reads harsh — soften to a modest dark gray. Structural
        // lines/borders below still derive from `label`, so only the text itself changes.
        text = dark ? label : Color(.sRGB, red: 58 / 255, green: 58 / 255, blue: 63 / 255, opacity: 1)
        eventTintScale = dark ? 1.0 : 1.5
        accentDark = label
        accentGrey = label.opacity(0.28)
        sep = label.opacity(0.28)
        gridLine = label.opacity(0.35) // solid gridlines
        cellGrid = label.opacity(0.16) // dotted day-cell verticals + lane separators
        dimFill = label.opacity(0.09)
        weekendWash = label.opacity(CalendarGeometry.Layout.weekendWashOpacity)
        highlight = label // hover wash (item opacity is tiny)
        cursor = label.opacity(0.6)
        nowLine = Self.accent // red accent (kept)
        todayTint = Self.accent.opacity(0.07)
        todayMonthWash = Color(hex: 0xC77E8B, opacity: 0.05) // current-month wash: faint red-pink gray
    }

    /// Event stickers are the ONLY color: a translucent tint fill + an opaque
    /// border/accent, exact values from globals.css (--event-*).
    public func eventFill(_ key: String?) -> Color {
        ev(key).fill
    }

    public func eventBorder(_ key: String?) -> Color {
        ev(key).border
    }

    /// The saturated fill hue at full opacity, so callers can set their own alpha.
    public func eventColor(_ key: String?) -> Color {
        #if canImport(AppKit)
            guard let c = NSColor(ev(key).fill).usingColorSpace(.sRGB) else { return ev(key).fill }
            return Color(
                .sRGB,
                red: Double(c.redComponent),
                green: Double(c.greenComponent),
                blue: Double(c.blueComponent),
                opacity: 1
            )
        #else
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(ev(key).fill).getRed(&r, green: &g, blue: &b, alpha: &a) else { return ev(key).fill }
            return Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: 1)
        #endif
    }

    private func ev(_ key: String?) -> (fill: Color, border: Color) {
        func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
            Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
        }
        // extra palette is literal (theme-consistent) in both modes
        switch key {
        case "orange": return (c(236, 152, 70, 0.2), c(236, 152, 70))
        case "cyan": return (c(104, 196, 206, 0.2), c(104, 196, 206))
        case "darkgreen": return (c(104, 146, 86, 0.22), c(104, 146, 86))
        case "indigo": return (c(124, 150, 226, 0.2), c(124, 150, 226))
        default: break
        }
        if dark {
            switch key {
            case "red": return (c(255, 128, 128, 0.18), c(255, 179, 179))
            case "yellow": return (c(255, 236, 179, 0.18), c(255, 224, 130))
            case "green": return (c(200, 255, 200, 0.18), c(178, 255, 178))
            case "blue": return (c(128, 170, 255, 0.18), c(179, 207, 255))
            case "purple": return (c(200, 128, 255, 0.18), c(218, 179, 255))
            default: return (c(255, 214, 224, 0.10), c(255, 214, 224, 0.4))
            }
        } else {
            // Light mode: saturated, on-hue tints (the old values were earthy/desaturated —
            // "blue" was teal, "purple" was dusty rose — which read pale under the tint). The
            // fill alpha here is nominal; perceived vibrance comes from eventColor × the boosted
            // eventTintScale at the render sites.
            switch key {
            case "red": return (c(240, 96, 96, 0.2), c(240, 96, 96))
            case "yellow": return (c(236, 176, 52, 0.2), c(214, 156, 30))
            case "green": return (c(104, 186, 92, 0.2), c(104, 186, 92))
            case "blue": return (c(74, 142, 232, 0.2), c(74, 142, 232))
            case "purple": return (c(168, 104, 216, 0.2), c(168, 104, 216))
            default: return (c(76, 45, 20, 0.102), c(76, 45, 20, 0.4))
            }
        }
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
