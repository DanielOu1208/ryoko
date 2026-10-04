import SwiftUI

/// Design tokens from design §9. Use these instead of literal numbers so the
/// whole app moves together when the styling is tuned on device.
///
/// - Controls are monochrome: the root view applies `.tint(Theme.tint)`.
/// - Content cards are solid (`Theme.cardFill`) with 24 pt continuous corners.
///   Liquid Glass is for floating controls only, never for cards.
/// - Margins are 20 pt horizontal on an 8 pt grid.
enum Theme {
    /// The accent: the primary label colour (black in light mode, white in dark).
    static let tint: Color = .primary

    /// Horizontal page margin.
    static let margin: CGFloat = 20
    /// The layout grid. Vertical spacing is a multiple of this.
    static let grid: CGFloat = 8
    /// Spacing between stacked cards.
    static let cardSpacing: CGFloat = 16
    /// Inner padding of a content card.
    static let cardPadding: CGFloat = 20

    /// Corner radius of content cards, with `.continuous` corners.
    static let cardRadius: CGFloat = 24
    static let cardShape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)

    /// Solid card fill (design §9.4).
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    /// The page behind cards, and what the blue wash fades into.
    static let pageBackground = Color(uiColor: .systemGroupedBackground)

    /// Share of the screen height the blue wash covers at rest (design §9.3).
    static let gradientHeightFraction: CGFloat = 0.45
}

extension View {
    /// A solid content card: `secondarySystemGroupedBackground`, 24 pt continuous corners.
    func cardSurface(padding: CGFloat = Theme.cardPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: Theme.cardShape)
    }

    /// The 20 pt horizontal page margin.
    func pageMargins() -> some View {
        padding(.horizontal, Theme.margin)
    }
}

/// `.borderedProminent` in the monochrome tint. The tint is the primary label
/// colour, white in dark mode, and the system draws a prominent button's label
/// white too, so it would vanish on the white capsule. Here the label takes the
/// background colour instead: white on black in light mode, black on white in
/// dark. Disabled, it's tertiary on the system's dimmed fill.
///
///     Button("Open the map") { … }
///         .buttonStyle(.monochromeProminent)
struct MonochromeProminentButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            configuration.trigger()
        } label: {
            configuration.label
                .foregroundStyle(isEnabled ? AnyShapeStyle(Color(uiColor: .systemBackground)) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderedProminent)
    }
}

extension PrimitiveButtonStyle where Self == MonochromeProminentButtonStyle {
    /// `.borderedProminent` with a label that stays readable in the monochrome tint.
    static var monochromeProminent: MonochromeProminentButtonStyle { MonochromeProminentButtonStyle() }
}

extension Color {
    /// An sRGB colour from a 24-bit hex literal, e.g. `Color(hex: 0xFFD8B5)`.
    nonisolated init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
