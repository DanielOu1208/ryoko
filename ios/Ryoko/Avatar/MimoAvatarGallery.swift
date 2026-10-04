#if DEBUG
import SwiftUI

/// DEBUG: Mimo's avatar on one screen. The five moods animating, a mood round trip, the
/// 14 bloub states frozen at their most readable time, and the tab icon next to SF
/// Symbols. Open it with the launch argument `-RyokoAvatarGallery 1`.
struct MimoAvatarGallery: View {
    static let launchArgument = "RyokoAvatarGallery"

    /// true when the app was launched with `-RyokoAvatarGallery 1`.
    static var launchRequested: Bool { UserDefaults.standard.bool(forKey: launchArgument) }

    private let started = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Moods") {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(MimoMood.allCases, id: \.self) { mood in
                                tile(mood.rawValue) { MimoAvatarView(mood: mood, size: 64) }
                            }
                        }
                    }
                    section("A reply, start to finish") {
                        HStack(alignment: .center, spacing: 16) {
                            TimelineView(.periodic(from: started, by: 4)) { timeline in
                                let mood = roundTrip(at: timeline.date)
                                HStack(spacing: 12) {
                                    MimoAvatarView(mood: mood, size: 96)
                                    Text(mood.rawValue)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .contentTransition(.opacity)
                                        .frame(width: 72, alignment: .leading)
                                }
                            }
                            Spacer(minLength: 0)
                            tile("bloub") { MimoAvatarView(state: .idle, frozenAt: 1, size: 56, style: .bloubDefault) }
                            tile("Mimo") { MimoAvatarView(state: .idle, frozenAt: 1, size: 56) }
                        }
                    }
                    section("States") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 8) {
                            ForEach(Bloub.sequence, id: \.self) { state in
                                tile(state.rawValue) {
                                    MimoAvatarView(state: state, frozenAt: Bloub.poseTimes[state] ?? 1, size: 60)
                                }
                            }
                        }
                    }
                    section("Tab icon") {
                        HStack(alignment: .bottom, spacing: 0) {
                            iconTile("25 pt", MimoAvatarIcon.image(pointSize: 25), size: 25)
                            iconTile("28 pt", MimoAvatarIcon.image(pointSize: 28), size: 28)
                            iconTile("outline", MimoAvatarIcon.image(pointSize: 25, variant: .outline), size: 25)
                            iconTile("outline 28", MimoAvatarIcon.image(pointSize: 28, variant: .outline), size: 28)
                        }
                        HStack(spacing: 0) {
                            ForEach(["character.bubble", "location.fill", "map"], id: \.self) { symbol in
                                Image(systemName: symbol).font(.system(size: 22)).frame(maxWidth: .infinity)
                            }
                            MimoAvatarIcon.image().frame(maxWidth: .infinity)
                            Image(systemName: "person.crop.circle").font(.system(size: 22)).frame(maxWidth: .infinity)
                        }
                        .frame(height: 44)
                        .background(.quaternary.opacity(0.5), in: .capsule)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .navigationTitle("Mimo avatar")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// idle, listening, thinking, talking, happy: one turn of a chat, 4 s each.
    private func roundTrip(at date: Date) -> MimoMood {
        let all = MimoMood.allCases
        let i = Int(max(0, date.timeIntervalSince(started)) / 4) % all.count
        return all[i]
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func tile<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 2) {
            content()
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func iconTile(_ caption: String, _ image: Image, size: CGFloat) -> some View {
        tile(caption) {
            image.frame(width: size, height: size)
        }
    }
}

#Preview {
    MimoAvatarGallery()
}
#endif
