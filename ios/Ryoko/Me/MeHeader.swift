import SwiftUI

/// The top of Me (design §4.10, #69): your avatar, where you're from and the
/// languages you speak.
///
/// The profile has no name or photo, so the avatar is an SF Symbol you pick,
/// kept on this device only (`AppSettings`-style storage, not the profile, so
/// it never changes `profile.version`). Until you pick one it follows your
/// rhythm: a sunrise for early birds, the moon for night owls.
struct MeHeader: View {
    @Environment(ProfileStore.self) private var profileStore
    @AppStorage(MeAvatar.storageKey) private var storedSymbol = ""
    @State private var isChoosingAvatar = false

    var body: some View {
        let profile = profileStore.profile
        let symbol = MeAvatar.symbol(stored: storedSymbol, profile: profile)
        Section {
            VStack(spacing: Theme.grid * 2) {
                Button { isChoosingAvatar = true } label: {
                    MeAvatarView(symbol: symbol, size: 104)
                        .overlay(alignment: .bottomTrailing) { editBadge }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Avatar")
                .accessibilityHint("Choose a different avatar")

                VStack(spacing: Theme.grid / 2) {
                    Text(Self.title(for: profile))
                        .font(.title2.bold())
                    if let languages = Self.languages(for: profile) {
                        Text(languages)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)

            }
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .sheet(isPresented: $isChoosingAvatar) {
            MeAvatarPicker(selected: symbol) { picked in
                storedSymbol = picked
                isChoosingAvatar = false
            }
            .presentationDetents([.medium])
        }
    }

    private var editBadge: some View {
        Image(systemName: "pencil")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(uiColor: .systemBackground))
            .frame(width: 30, height: 30)
            .background(Color.primary, in: .circle)
            .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2))
            .accessibilityHidden(true)
    }

    // MARK: Copy

    /// "Traveller from Canada", or "Traveller" when the country was skipped.
    static func title(for profile: Profile) -> String {
        guard let code = profile.nationality, let country = ProfileWording.countryName(code) else { return "Traveller" }
        return "Traveller from \(country)"
    }

    /// "Speaks English and French": the home language first, then the others.
    static func languages(for profile: Profile) -> String? {
        var tags = [profile.homeLanguage]
        for tag in profile.spokenLanguages ?? [] where !tags.contains(tag) {
            tags.append(tag)
        }
        let names = tags.map(ProfileWording.language)
        return "Speaks \(names.formatted(.list(type: .and)))"
    }
}

// MARK: - Avatar

/// The avatar choices and where the pick is kept.
enum MeAvatar {
    static let storageKey = "RyokoMeAvatarSymbol"

    static let choices = [
        "figure.walk", "airplane", "backpack.fill", "camera.fill",
        "fork.knife", "cup.and.saucer.fill", "mountain.2.fill", "tram.fill",
        "sunrise.fill", "moon.stars.fill", "leaf.fill", "book.fill",
    ]

    /// The picked symbol, or one that follows the profile's rhythm.
    static func symbol(stored: String, profile: Profile) -> String {
        if choices.contains(stored) { return stored }
        switch profile.personality?.rhythm {
        case .earlyBird?: return "sunrise.fill"
        case .nightOwl?: return "moon.stars.fill"
        case nil: return "figure.walk"
        }
    }
}

/// A round avatar: the symbol on a solid disc with a hairline edge.
struct MeAvatarView: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Theme.cardFill, in: .circle)
            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

/// The sheet for choosing an avatar.
private struct MeAvatarPicker: View {
    let selected: String
    let pick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.grid * 2), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.grid * 2) {
                    ForEach(MeAvatar.choices, id: \.self) { symbol in
                        Button { pick(symbol) } label: {
                            MeAvatarView(symbol: symbol, size: 64)
                                .overlay {
                                    if symbol == selected {
                                        Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                        .accessibilityAddTraits(symbol == selected ? .isSelected : [])
                    }
                }
                .pageMargins()
                .padding(.vertical, Theme.grid * 2)
            }
            .navigationTitle("Choose an avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
