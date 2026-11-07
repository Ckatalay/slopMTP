import SwiftUI

/// Liquid Glass on macOS 26 and later, with material fallbacks for earlier systems.
extension View {
    /// A glass panel in a rounded rectangle.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { if let tint { shape.fill(tint.opacity(0.15)) } }
        }
    }

    /// A glass capsule, for pills and badges.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint), in: Capsule())
        } else {
            background((tint ?? .secondary).opacity(0.18), in: Capsule())
        }
    }

    /// Content scrolling under the top bar fades out with a progressive blur.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// Content scrolling under the top and bottom bars fades out with a progressive blur.
    @ViewBuilder
    func softVerticalEdges() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            self
        }
    }

    /// A bar pinned to an edge that content scrolls beneath (with the scroll edge blur on macOS 26).
    @ViewBuilder
    func edgeBar<Bar: View>(_ edge: VerticalEdge, @ViewBuilder bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, content: bar)
        } else {
            safeAreaInset(edge: edge, spacing: 0) {
                bar().background(.bar)
            }
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

/// Groups glass shapes so they blend and morph together on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
