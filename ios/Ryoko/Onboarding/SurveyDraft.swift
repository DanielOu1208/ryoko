import Foundation

/// The survey's working answers, one value per control (design §4.1).
///
/// The forms edit a draft; `apply(_:to:)` writes one page's answer into a
/// profile, and `skip(_:in:)` writes a skipped page as `null`. Both clean the
/// values to the contract's limits, so a saved profile always validates
/// against `contracts/json-schema/Profile.schema.json`:
/// - text is trimmed and capped, and empty text is dropped;
/// - "none" is an empty list, a skipped page is `null` (design §7.2);
/// - the home language is never null: a skipped first page falls back to the
///   device language.
nonisolated struct SurveyDraft: Equatable, Sendable {
    // 1. Where you're from
    var nationality: String?
    var homeLanguage: String
    // 2. Languages you speak, in the order picked
    var spokenLanguages: [String]
    // 3. What you don't eat
    var diet: Set<Diet>
    var dietNotes: String
    // 4. Allergies: chip allergens and typed-in ones, each with a severity
    var allergies: [Allergy]
    // 5. Your usual: favourites, and taste sliders from 0 to 4 (2 is "as usual")
    var foods: [String]
    var drinks: [String]
    var sweetness: Int
    var spice: Int
    // 6. This or that
    var personality: Personality
    // 7. Where you're staying
    var homeBase: HomeBase?

    /// A blank survey for first launch, with the device's country and language
    /// filled in as suggestions.
    static func firstLaunch() -> SurveyDraft {
        let language = SurveyOptions.deviceLanguage
        return SurveyDraft(
            nationality: SurveyOptions.deviceCountry,
            homeLanguage: language,
            spokenLanguages: [language],
            diet: [],
            dietNotes: "",
            allergies: [],
            foods: [],
            drinks: [],
            sweetness: 2,
            spice: 2,
            personality: Personality(),
            homeBase: nil
        )
    }

    /// The answers already in a profile (Redo survey, Me's editors). Skipped
    /// pages start blank.
    init(profile: Profile) {
        self.init(
            nationality: profile.nationality,
            homeLanguage: profile.homeLanguage,
            spokenLanguages: profile.spokenLanguages ?? [profile.homeLanguage],
            diet: Set(profile.diet ?? []),
            dietNotes: profile.dietNotes ?? "",
            allergies: profile.allergies ?? [],
            foods: profile.favourites?.foods ?? [],
            drinks: profile.favourites?.drinks ?? [],
            sweetness: profile.taste?.sweetness ?? 2,
            spice: profile.taste?.spice ?? 2,
            personality: profile.personality ?? Personality(),
            homeBase: profile.homeBase
        )
    }

    init(
        nationality: String?, homeLanguage: String, spokenLanguages: [String], diet: Set<Diet>, dietNotes: String,
        allergies: [Allergy], foods: [String], drinks: [String], sweetness: Int, spice: Int,
        personality: Personality, homeBase: HomeBase?
    ) {
        self.nationality = nationality
        self.homeLanguage = homeLanguage
        self.spokenLanguages = spokenLanguages
        self.diet = diet
        self.dietNotes = dietNotes
        self.allergies = allergies
        self.foods = foods
        self.drinks = drinks
        self.sweetness = sweetness
        self.spice = spice
        self.personality = personality
        self.homeBase = homeBase
    }

    // MARK: Writing a profile

    /// The finished survey: each answered page from the draft, every other
    /// page `null`. `version` is filled in by `ProfileStore`.
    func profile(answered: Set<SurveyPage>) -> Profile {
        var profile = Profile(
            version: "",
            nationality: nil,
            homeLanguage: SurveyOptions.deviceLanguage,
            spokenLanguages: nil,
            diet: nil,
            dietNotes: nil,
            allergies: nil,
            favourites: nil,
            taste: nil,
            personality: nil,
            homeBase: nil
        )
        for page in SurveyPage.allCases {
            if answered.contains(page) {
                apply(page, to: &profile)
            } else {
                Self.skip(page, in: &profile)
            }
        }
        return profile
    }

    /// Writes one page's answer into `profile`.
    func apply(_ page: SurveyPage, to profile: inout Profile) {
        switch page {
        case .origin:
            profile.nationality = nationality.flatMap { SurveyOptions.isCountryCode($0) ? $0 : nil }
            profile.homeLanguage = SurveyOptions.isLanguageTag(homeLanguage) ? homeLanguage : SurveyOptions.deviceLanguage
        case .languages:
            var seen = Set<String>()
            profile.spokenLanguages = spokenLanguages
                .filter { SurveyOptions.isLanguageTag($0) && seen.insert($0).inserted }
                .prefix(SurveyOptions.maxSpokenLanguages)
                .map(\.self)
        case .diet:
            profile.diet = Diet.allCases.filter(diet.contains)
            profile.dietNotes = SurveyOptions.cleaned(dietNotes, limit: SurveyOptions.maxDietNotesLength) ?? ""
        case .allergies:
            profile.allergies = Self.cleaned(allergies)
        case .usual:
            profile.favourites = Favourites(foods: Self.cleaned(foods), drinks: Self.cleaned(drinks))
            profile.taste = Taste(sweetness: sweetness.clamped(to: 0...4), spice: spice.clamped(to: 0...4))
        case .thisOrThat:
            profile.personality = personality
        case .homeBase:
            profile.homeBase = homeBase.flatMap(Self.cleaned)
        }
    }

    /// Writes a skipped page into `profile`: `null` everywhere, except the home
    /// language, which falls back to the device language.
    static func skip(_ page: SurveyPage, in profile: inout Profile) {
        switch page {
        case .origin:
            profile.nationality = nil
            profile.homeLanguage = SurveyOptions.deviceLanguage
        case .languages:
            profile.spokenLanguages = nil
        case .diet:
            profile.diet = nil
            profile.dietNotes = nil
        case .allergies:
            profile.allergies = nil
        case .usual:
            profile.favourites = nil
            profile.taste = nil
        case .thisOrThat:
            profile.personality = nil
        case .homeBase:
            profile.homeBase = nil
        }
    }

    // MARK: Cleaning

    /// Trimmed, non-empty, unique (ignoring case) and within the schema's limits.
    static func cleaned(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items
            .compactMap { SurveyOptions.cleaned($0, limit: SurveyOptions.maxFavouriteLength) }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(SurveyOptions.maxFavourites)
            .map(\.self)
    }

    /// One entry per allergen (custom ones by label), labels only on custom
    /// allergens, at most 20.
    static func cleaned(_ allergies: [Allergy]) -> [Allergy] {
        var seen = Set<String>()
        var result: [Allergy] = []
        for allergy in allergies {
            var allergy = allergy
            if allergy.id == .custom {
                guard let label = allergy.label.flatMap({ SurveyOptions.cleaned($0, limit: SurveyOptions.maxAllergyLabelLength) })
                else { continue }
                allergy.label = label
            } else {
                allergy.label = nil
            }
            let key = allergy.id == .custom ? "custom:\(allergy.label!.lowercased())" : allergy.id.rawValue
            guard seen.insert(key).inserted else { continue }
            result.append(allergy)
        }
        return Array(result.prefix(SurveyOptions.maxAllergies))
    }

    /// Text fields trimmed and capped, empty ones dropped, the coordinate in range.
    static func cleaned(_ home: HomeBase) -> HomeBase? {
        guard let name = SurveyOptions.cleaned(home.name, limit: SurveyOptions.maxHomeBaseNameLength),
              (-90...90).contains(home.coordinate.lat), (-180...180).contains(home.coordinate.lon) else { return nil }
        return HomeBase(
            name: name,
            localName: home.localName.flatMap { SurveyOptions.cleaned($0, limit: SurveyOptions.maxHomeBaseNameLength) },
            address: home.address.flatMap { SurveyOptions.cleaned($0, limit: SurveyOptions.maxAddressLength) },
            addressLocal: home.addressLocal.flatMap { SurveyOptions.cleaned($0, limit: SurveyOptions.maxAddressLength) },
            coordinate: home.coordinate
        )
    }
}

nonisolated extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
