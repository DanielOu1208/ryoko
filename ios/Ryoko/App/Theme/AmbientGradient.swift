import SwiftUI

/// What the screen behind the wash is doing (design §9.3).
nonisolated enum AmbientMood: Hashable, Sendable {
    /// Nothing going on: the wash holds still.
    case calm
    /// Mimo is working on a reply, or Translate is connecting: the wash drifts.
    case working
    /// Translate is listening: the wash swells with the voice.
    case listening
}

/// The blue wash from design §9.3: a soft gradient over the top ~45% of
/// Translate, Mimo and Me, fading into the page background. It's the same
/// blue at every hour.
///
/// It holds still while nothing is going on. While Mimo works it drifts
/// slowly, and while Translate listens it swells and brightens with the
/// microphone level. Under Reduce Motion it never moves.
///
///     ScrollView { … }
///         .background { AmbientGradient(mood: .working) }
///
/// It doesn't appear on the Map, in Show mode or in onboarding.
struct AmbientGradient: View {
    /// What the wash fades into, and what fills the rest of the screen.
    var background: Color = Theme.pageBackground
    var mood: AmbientMood = .calm
    /// The microphone level, 0…1, read while listening. Read here rather than
    /// passed in, so a level change redraws only the wash, not the screen.
    var level: (() -> Float)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let energy = reduceMotion ? 0 : currentEnergy
        let presence: Double = mood == .calm || reduceMotion ? 0 : 1
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: nil, paused: presence == 0)) { context in
                MeshWash(
                    palette: Palette(colorScheme),
                    background: background,
                    time: context.date.timeIntervalSinceReferenceDate * (mood == .listening ? 0.55 : 0.9),
                    presence: presence,
                    energy: energy
                )
            }
            .frame(height: proxy.size.height * (Theme.gradientHeightFraction + CGFloat(energy) * 0.14))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // The level arrives about eight times a second: ease between readings.
        .animation(.smooth(duration: 0.35), value: energy)
        .animation(.smooth(duration: 0.8), value: presence)
        .background(background)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// 0 at rest, up to 1: how strongly the wash reacts right now.
    private var currentEnergy: Double {
        switch mood {
        case .calm: return 0
        case .working: return 0.5
        case .listening:
            // Room noise sits around 0.2 on the mic's scale; speech around 0.4–0.75.
            let raw = Double(level?() ?? 0)
            return 0.15 + 0.85 * min(max((raw - 0.25) / 0.5, 0), 1)
        }
    }
}

/// A 3 × 3 mesh: the blue along the top, the fade across the middle, the page
/// background along the bottom. With `presence` 0 it's a plain top-down wash.
/// `presence` and `energy` animate (the timeline only moves `time`), so the
/// wash eases in and out of motion and between level readings.
private struct MeshWash: View, Animatable {
    let palette: AmbientGradient.Palette
    let background: Color
    let time: Double
    var presence: Double
    var energy: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(presence, energy) }
        set {
            presence = newValue.first
            energy = newValue.second
        }
    }

    var body: some View {
        let sway = presence * (0.05 + 0.06 * energy)
        let tint = presence * (0.35 + 0.65 * energy)

        func wave(_ rate: Double, _ phase: Double) -> Double { sin(time * rate + phase) }
        /// 0…1, for colour mixing.
        func pulse(_ rate: Double, _ phase: Double) -> Double { (wave(rate, phase) + 1) / 2 }

        let points: [SIMD2<Float>] = [
            [0, 0], [0.5, 0], [1, 0],
            [0, Float(0.55 + sway * wave(0.7, 0))],
            [Float(0.5 + sway * 1.6 * wave(0.9, 1.3)), Float(0.55 + sway * wave(0.6, 2.1))],
            [1, Float(0.55 + sway * wave(0.8, 4.0))],
            [0, 1], [0.5, 1], [1, 1],
        ]
        let colors: [Color] = [
            palette.top.mix(with: palette.vivid, by: tint * pulse(0.8, 0)),
            palette.top.mix(with: palette.violet, by: tint * pulse(0.6, 2.0)),
            palette.top.mix(with: palette.vivid, by: tint * pulse(0.7, 4.2)),
            palette.fade.mix(with: palette.top, by: tint * 0.5 * pulse(0.5, 1.0)),
            palette.fade.mix(with: palette.vivid, by: tint * 0.35 * pulse(0.9, 3.0)),
            palette.fade.mix(with: palette.top, by: tint * 0.5 * pulse(0.55, 5.0)),
            background, background, background,
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: colors, smoothsColors: true)
    }
}

extension AmbientGradient {
    /// The wash's colours. Tune on device here and in design §9.3 together.
    nonisolated struct Palette: Equatable, Sendable {
        let topHex: UInt32
        /// `nil` means black (the dark-mode fade).
        let fadeHex: UInt32?
        /// A brighter blue the top leans toward when the wash reacts.
        let vividHex: UInt32
        /// A periwinkle the top leans toward when the wash reacts.
        let violetHex: UInt32

        var top: Color { Color(hex: topHex) }
        var fade: Color { fadeHex.map { Color(hex: $0) } ?? .black }
        var vivid: Color { Color(hex: vividHex) }
        var violet: Color { Color(hex: violetHex) }

        init(_ colorScheme: ColorScheme) {
            if colorScheme == .dark {
                self.init(topHex: 0x1E416A, fadeHex: nil, vividHex: 0x2A5F9E, violetHex: 0x2E3A86)
            } else {
                self.init(topHex: 0xADD2FF, fadeHex: 0xDDECFF, vividHex: 0x86BAFF, violetHex: 0xB6C0FF)
            }
        }

        init(topHex: UInt32, fadeHex: UInt32?, vividHex: UInt32, violetHex: UInt32) {
            self.topHex = topHex
            self.fadeHex = fadeHex
            self.vividHex = vividHex
            self.violetHex = violetHex
        }
    }
}

#Preview("Moods") {
    TabView {
        ForEach([AmbientMood.calm, .working, .listening], id: \.self) { mood in
            AmbientGradient(mood: mood, level: { 0.6 })
                .overlay { Text(String(describing: mood)).font(.largeTitle.bold()) }
        }
    }
    .tabViewStyle(.page)
}

/// The blue wash as a tab's background (Translate, Mimo and Me). It starts
/// live mode (without a prompt), so a tab opened first still has a situation.
struct SituationGradient: View {
    var background: Color = Theme.pageBackground
    var mood: AmbientMood = .calm
    var level: (() -> Float)?

    @Environment(AppSituationStore.self) private var situationStore

    var body: some View {
        AmbientGradient(background: background, mood: mood, level: level)
            .task { situationStore.startLiveIfAuthorized() }
    }
}
