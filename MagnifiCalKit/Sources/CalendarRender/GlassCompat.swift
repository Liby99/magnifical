// Liquid Glass backport shim. The app's visual language is built on macOS 26's
// .glassEffect, but the deployment floor is lower so friends on older systems can
// run it: on 26+ these helpers forward to the real Liquid Glass APIs; below, they
// fall back to the closest classic material (.ultraThinMaterial frost + tint wash —
// no refraction, but the same translucent read). All glass call sites in the tree
// go through this file; don't call .glassEffect / .buttonStyle(.glass) directly.

import SwiftUI

/// Mirror of the OS `Glass` configuration, expressible below macOS 26. Only the
/// surface we actually use: `.regular` / `.clear` + `.tint(_)`.
public struct CompatGlass: Equatable {
    var isClear = false
    var tintColor: Color?

    public static let regular = CompatGlass()
    public static let clear = CompatGlass(isClear: true)

    public func tint(_ color: Color) -> CompatGlass {
        var g = self
        g.tintColor = color
        return g
    }

    /// The real thing, buildable only where the SDK type exists.
    @available(macOS 26.0, iOS 26.0, *)
    var native: Glass {
        var g: Glass = isClear ? .clear : .regular
        if let tintColor {
            g = g.tint(tintColor)
        }
        return g
    }
}

public extension View {
    /// `.glassEffect(_:in:)` on OS 26+; below, a frosted-material fill in the same shape
    /// with the tint washed over it. Like the real modifier, the material sits BEHIND the
    /// view's content.
    @ViewBuilder
    func glassEffectCompat<S: Shape>(_ glass: CompatGlass = .regular, in shape: S) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(glass.native, in: shape)
        } else {
            background {
                ZStack {
                    if !glass.isClear {
                        shape.fill(.ultraThinMaterial)
                    }
                    if let t = glass.tintColor {
                        shape.fill(t)
                    }
                }
            }
        }
    }

    /// `.buttonStyle(.glass)` on OS 26+; a plain bordered button below. Chain
    /// `.buttonBorderShape(...)` after it as usual — it applies to both branches.
    @ViewBuilder
    func glassButtonStyleCompat() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// `ToolbarSpacer` on OS 26+; a no-op toolbar item below (pre-26 toolbars space items
/// by placement alone — the spacers are a Liquid Glass grouping refinement).
public struct ToolbarSpacerCompat: ToolbarContent {
    public enum Sizing { case fixed, flexible }
    let sizing: Sizing

    public init(_ sizing: Sizing = .flexible) {
        self.sizing = sizing
    }

    public var body: some ToolbarContent {
        if #available(macOS 26.0, iOS 26.0, *) {
            ToolbarSpacer(sizing == .fixed ? .fixed : .flexible)
        } else {
            ToolbarItem { EmptyView() }
        }
    }
}
