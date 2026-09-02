import SwiftUI

/// The standard content container: padded, rounded, on a `card` surface with
/// the matching elevation.
///
/// Thin on purpose. `reloraSurface` already pairs the surface tone with its
/// shadow — which is what keeps dark mode legible — so this adds only the
/// padding and the default radius, and exists so a screen does not repeat that
/// four-line incantation a dozen times.
public struct ReloraCard<Content: View>: View {
    private let surface: Color
    private let radius: CGFloat
    private let shadow: ReloraShadow
    private let padding: CGFloat
    private let content: Content

    public init(
        surface: Color = ReloraColor.card,
        radius: CGFloat = ReloraRadius.lg,
        shadow: ReloraShadow = .card,
        padding: CGFloat = ReloraSpacing.md,
        @ViewBuilder content: () -> Content
    ) {
        self.surface = surface
        self.radius = radius
        self.shadow = shadow
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .reloraSurface(surface, radius: radius, shadow: shadow)
            .reloraBorder(radius: radius)
    }
}

/// The initials circle that stands in for a contact photo.
///
/// Coral fill with `onAccent` initials, matching every RN avatar. Sized off the
/// text style so it grows with Dynamic Type instead of leaving a 44pt puck
/// beside 30pt text.
public struct ReloraAvatar: View {
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 44

    private let name: String

    public init(name: String) {
        self.name = name
    }

    /// Up to two uppercase initials. Ports `getInitials`
    /// (apps/mobile/src/utils/text.ts).
    public static func initials(for name: String) -> String {
        name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }

    public var body: some View {
        Text(ReloraAvatar.initials(for: name))
            .font(ReloraFont.footnote)
            .foregroundStyle(ReloraColor.onAccent)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(ReloraColor.accent))
            // The name is already announced by the row; the initials would
            // repeat it one letter at a time.
            .accessibilityHidden(true)
    }
}
