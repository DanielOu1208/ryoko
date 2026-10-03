import SwiftUI

/// The soft, static time-of-day wash from design §9.3: a `LinearGradient` over
/// the top ~45% of Now and of place sheets, fading into the system background.
/// No animation. It follows the active situation's local time, so a previewed
/// 8 AM looks like morning.
///
/// Use it as a background that fills the screen:
///
///     ScrollView { … }
///         .background { TimeOfDayGradient(date: date, timeZone: zone) }
///
/// It doesn't appear in Show mode, Translate, Mimo, Me or onboarding.
struct TimeOfDayGradient: View {
    let partOfDay: PartOfDay
    /// What the wash fades into, and what fills the rest of the screen.
    var background: Color = Theme.pageBackground

    @Environment(\.colorScheme) private var colorScheme

    init(partOfDay: PartOfDay, background: Color = Theme.pageBackground) {
        self.partOfDay = partOfDay
        self.background = background
    }

    /// The wash for `date` as seen in `timeZone` (the place's zone, not the device's).
    init(date: Date, timeZone: TimeZone, background: Color = Theme.pageBackground) {
        self.init(partOfDay: PartOfDay(date: date, timeZone: timeZone), background: background)
    }

    var body: some View {
        let palette = Palette(partOfDay, colorScheme)
        GeometryReader { proxy in
            LinearGradient(
                stops: [
                    .init(color: palette.top, location: 0),
                    .init(color: palette.fade, location: 0.55),
                    .init(color: background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: proxy.size.height * Theme.gradientHeightFraction)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(background)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension TimeOfDayGradient {
    /// The two colours of a wash. The values are the §9.3 starting values; tune
    /// them on device here and in the design doc together.
    nonisolated struct Palette: Equatable, Sendable {
        let topHex: UInt32
        /// `nil` means black (the dark-mode fade).
        let fadeHex: UInt32?

        var top: Color { Color(hex: topHex) }
        var fade: Color { fadeHex.map { Color(hex: $0) } ?? .black }

        init(topHex: UInt32, fadeHex: UInt32?) {
            self.topHex = topHex
            self.fadeHex = fadeHex
        }

        init(_ partOfDay: PartOfDay, _ colorScheme: ColorScheme) {
            switch (partOfDay, colorScheme == .dark) {
            case (.morning, false): self.init(topHex: 0xFFD8B5, fadeHex: 0xFFF3E3)
            case (.midday, false): self.init(topHex: 0xCDE5FF, fadeHex: 0xEEF6FF)
            case (.evening, false): self.init(topHex: 0xFFC48A, fadeHex: 0xF9B9B0)
            case (.night, false): self.init(topHex: 0xC5CCE0, fadeHex: 0xE6E9F2)
            case (.morning, true): self.init(topHex: 0x5A3A26, fadeHex: nil)
            case (.midday, true): self.init(topHex: 0x1D3A5C, fadeHex: nil)
            case (.evening, true): self.init(topHex: 0x5C3524, fadeHex: nil)
            case (.night, true): self.init(topHex: 0x1A1F3D, fadeHex: nil)
            }
        }
    }
}

#Preview("Parts of day") {
    TabView {
        ForEach(PartOfDay.allCases, id: \.self) { part in
            TimeOfDayGradient(partOfDay: part)
                .overlay { Text(part.displayName).font(.largeTitle.bold()) }
        }
    }
    .tabViewStyle(.page)
}
