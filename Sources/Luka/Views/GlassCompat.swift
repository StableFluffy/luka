import SwiftUI

/// Liquid Glass on macOS 26, system materials before that (or when glass is turned off).
/// Mirrors the shape of SwiftUI's `Glass` so call sites read the same either way.
struct LukaGlass {
    var clear = false
    var tintColor: Color?
    var isInteractive = false

    static let regular = LukaGlass()
    static let clear = LukaGlass(clear: true)

    func tint(_ color: Color?) -> LukaGlass {
        var g = self
        g.tintColor = color
        return g
    }

    func interactive() -> LukaGlass {
        var g = self
        g.isInteractive = true
        return g
    }

    @available(macOS 26, *)
    var glass: Glass {
        var g: Glass = clear ? .clear : .regular
        if let tintColor { g = g.tint(tintColor) }
        return isInteractive ? g.interactive() : g
    }
}

extension EnvironmentValues {
    /// Whether to draw Liquid Glass; false before macOS 26 or when turned off in Settings.
    @Entry var usesGlass: Bool = LukaGlassSupport.available
}

enum LukaGlassSupport {
    static var available: Bool {
        if #available(macOS 26, *) { true } else { false }
    }
}

private struct GlassModifier<S: Shape>: ViewModifier {
    @Environment(\.usesGlass) private var usesGlass
    @Environment(\.colorScheme) private var colorScheme
    let style: LukaGlass
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *), usesGlass {
            content.glassEffect(style.glass, in: shape)
        } else {
            content.background {
                ZStack {
                    shape.fill(style.clear ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))
                    if let tint = style.tintColor { shape.fill(tint.opacity(style.isInteractive ? 0.92 : 0.6)) }
                    shape.stroke(.white.opacity(colorScheme == .dark ? 0.14 : 0.5), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            }
        }
    }
}

private struct GlassIDModifier: ViewModifier {
    @Environment(\.usesGlass) private var usesGlass
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26, *), usesGlass {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

private struct GlassButtonModifier: ViewModifier {
    @Environment(\.usesGlass) private var usesGlass
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *), usesGlass {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

extension View {
    func lukaGlass<S: Shape>(_ style: LukaGlass = .regular, in shape: S) -> some View {
        modifier(GlassModifier(style: style, shape: shape))
    }

    func lukaGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        modifier(GlassIDModifier(id: id, namespace: namespace))
    }

    func lukaGlassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonModifier(prominent: prominent))
    }
}

/// Groups glass shapes so they morph together on macOS 26; a plain container otherwise.
struct LukaGlassContainer<Content: View>: View {
    @Environment(\.usesGlass) private var usesGlass
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *), usesGlass {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
