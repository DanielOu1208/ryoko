import SwiftUI

/// Nearby's quick cards row (design §4.3): the allergy card and the taxi card,
/// each opening in Show mode. Side by side, or stacked at accessibility sizes.
///
/// - **Allergy:** the profile's allergies in the local language
///   (`AllergyCardStore`). Disabled, with the reason, when the profile has none
///   or the language has no templates yet.
/// - **Taxi:** to the current place, or to the home base when no place is known.
struct NearbyQuickCards: View {
    let situation: Situation
    /// The place's local name from its place card, for the taxi card.
    let placeNameLocal: String?
    /// True once the place card has loaded (or failed), for the DEBUG launch hook.
    var cardSettled = false

    @Environment(ProfileStore.self) private var profileStore
    @Environment(AppRouter.self) private var router
    @Environment(\.ryokoAPI) private var api
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var allergy = AllergyCardPresenter()
    @State private var isBuildingTaxi = false

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.grid * 1.5))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.grid * 1.5))
        layout {
            allergyTile
            taxiTile
        }
        .fixedSize(horizontal: false, vertical: true)
        .allergyCardFailureAlert(allergy)
        #if DEBUG
        .task(id: cardSettled) { runLaunchHook() }
        #endif
    }

    // MARK: Allergy

    private var allergyTile: some View {
        let profile = profileStore.profile
        let reason = AllergyCardStore.unavailability(profile: profile, language: situation.localLanguage)
        return QuickCardTile(
            title: "Allergy card",
            subtitle: allergySubtitle(reason, profile: profile),
            systemImage: "allergens",
            isLoading: allergy.isLoading,
            isEnabled: reason == nil,
            hint: "Opens your allergy card in the local language, full screen",
            action: openAllergy
        )
    }

    private func allergySubtitle(_ reason: AllergyCardStore.Unavailable?, profile: Profile) -> String {
        switch reason {
        case nil:
            AllergyCardStore.summary(profile: profile, language: situation.localLanguage)
        case let .noAllergies(skipped)?:
            skipped ? "Allergies skipped in your profile" : "No allergies in your profile"
        case let .unsupportedLanguage(tag)?:
            "Not available in \(Self.languageName(tag)) yet"
        }
    }

    private func openAllergy() {
        allergy.present(profile: profileStore.profile, language: situation.localLanguage, api: api, router: router)
    }

    // MARK: Taxi

    private enum TaxiTarget {
        case place(Place)
        case home(HomeBase)
    }

    private var taxiTarget: TaxiTarget? {
        #if DEBUG
        if ShowDebugOptions.taxiTargetsHome, let home = profileStore.profile.homeBase { return .home(home) }
        #endif
        if let place = situation.place { return .place(place) }
        return profileStore.profile.homeBase.map(TaxiTarget.home)
    }

    private var taxiTile: some View {
        let subtitle: String = switch taxiTarget {
        case let .place(place)?: "To \(place.name)"
        case let .home(home)?: "To your home base, \(home.name)"
        case nil: "No home base set"
        }
        return QuickCardTile(
            title: "Taxi card",
            subtitle: subtitle,
            systemImage: "car.fill",
            isLoading: isBuildingTaxi,
            isEnabled: taxiTarget != nil,
            hint: "Opens the address in the local language, full screen, to show a driver",
            action: openTaxi
        )
    }

    private func openTaxi() {
        guard let target = taxiTarget, !isBuildingTaxi else { return }
        isBuildingTaxi = true
        Task {
            let card = switch target {
            case let .place(place):
                await TaxiCardFactory.card(for: place, language: situation.localLanguage, placeNameLocal: placeNameLocal)
            case let .home(home):
                await TaxiCardFactory.card(forHomeBase: home, language: situation.localLanguage)
            }
            isBuildingTaxi = false
            router.show = .taxi(card)
        }
    }

    static func languageName(_ tag: String) -> String {
        LangCode(tag: tag)?.displayName ?? Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    #if DEBUG
    /// `-RyokoShow allergy|taxi`: open the card once the place card has settled.
    private func runLaunchHook() {
        guard cardSettled, !NearbyDebugOptions.didRunShowHook, let kind = ShowDebugOptions.showAtLaunch else { return }
        switch kind {
        case .allergy:
            NearbyDebugOptions.didRunShowHook = true
            openAllergy()
        case .taxi:
            NearbyDebugOptions.didRunShowHook = true
            openTaxi()
        case .phrase:
            break // NearbyView opens the first phrase
        }
    }
    #endif
}

/// One quick card: a solid tile with an icon, a title and one or two lines.
private struct QuickCardTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isLoading: Bool
    let isEnabled: Bool
    let hint: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .title2) private var iconHeight: CGFloat = 28

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.grid) {
                Group {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: systemImage)
                            .font(.title2)
                            .foregroundStyle(isEnabled ? .primary : .tertiary)
                    }
                }
                .frame(height: iconHeight, alignment: .leading)
                .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Theme.grid * 2)
            .background(Theme.cardFill, in: Theme.cardShape)
            .contentShape(Theme.cardShape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isEnabled ? hint : "")
        .accessibilityValue(isLoading ? "Loading" : "")
    }
}
