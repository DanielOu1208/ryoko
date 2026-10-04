import Foundation

/// Plain-language names for profile values, in sentence case. Shared by the
/// survey and Me, so both say the same thing. Severity is always written in
/// words (design §9.2).
nonisolated enum ProfileWording {
    // MARK: Places and languages

    static func country(_ code: String?) -> String {
        guard let code else { return "Skipped" }
        return countryName(code) ?? code
    }

    /// The display name of an ISO 3166-1 alpha-2 code, or nil if there's none.
    static func countryName(_ code: String) -> String? {
        Locale.current.localizedString(forRegionCode: code)
    }

    /// A language's name: the `LangCode` table's for the first-class languages,
    /// otherwise the system's, with a capital first letter.
    static func language(_ tag: String) -> String {
        if let row = LangCode(rawValue: tag) { return row.displayName }
        guard let name = Locale.current.localizedString(forIdentifier: tag) else { return tag }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A comma-separated list; "None" for an empty list and "Skipped" for nil.
    static func list(_ items: [String]?) -> String {
        guard let items else { return "Skipped" }
        return items.isEmpty ? "None" : items.joined(separator: ", ")
    }

    // MARK: Food

    static func diet(_ diet: Diet) -> String {
        switch diet {
        case .vegetarian: "Vegetarian"
        case .vegan: "Vegan"
        case .halal: "Halal"
        case .kosher: "Kosher"
        case .noPork: "No pork"
        case .noBeef: "No beef"
        case .glutenFree: "Gluten-free"
        case .lactoseFree: "Lactose-free"
        }
    }

    static func allergen(_ id: AllergenId) -> String {
        switch id {
        case .egg: "Egg"
        case .milk: "Milk"
        case .mustard: "Mustard"
        case .peanut: "Peanut"
        case .crustaceanMollusc: "Shellfish"
        case .fish: "Fish"
        case .sesame: "Sesame"
        case .soy: "Soy"
        case .sulphite: "Sulphites"
        case .treeNut: "Tree nuts"
        case .wheat: "Wheat"
        case .custom: "Other"
        }
    }

    static func allergen(_ allergy: Allergy) -> String {
        allergy.id == .custom ? (allergy.label ?? "Other") : allergen(allergy.id)
    }

    /// Lowercase, for running text: "Peanut · serious".
    static func severity(_ severity: Severity) -> String {
        switch severity {
        case .mild: "mild"
        case .serious: "serious"
        case .lifeThreatening: "life-threatening"
        }
    }

    /// Capitalized, for pickers.
    static func severityTitle(_ severity: Severity) -> String {
        switch severity {
        case .mild: "Mild"
        case .serious: "Serious"
        case .lifeThreatening: "Life-threatening"
        }
    }

    /// "Fruit tea" for the stored "fruit tea".
    static func favourite(_ item: String) -> String {
        item.prefix(1).uppercased() + item.dropFirst()
    }

    /// Taste sliders run 0–4, where 2 is "as usual".
    static func taste(_ value: Int?, noun: String) -> String {
        switch value {
        case nil: "Skipped"
        case 0?: "Much less \(noun)"
        case 1?: "Less \(noun)"
        case 2?: "As usual"
        case 3?: "More \(noun)"
        default: "Much more \(noun)"
        }
    }

    // MARK: This or that

    static func rhythm(_ value: Personality.Rhythm) -> String {
        value == .earlyBird ? "Early bird" : "Night owl"
    }

    static func food(_ value: Personality.Food) -> String {
        value == .localFavourite ? "Local favourite" : "My usual"
    }

    static func budget(_ value: Personality.Budget) -> String {
        value == .save ? "Save" : "Splurge"
    }

    static func vibe(_ value: Personality.Vibe) -> String {
        value == .quiet ? "Quiet" : "Lively"
    }

    static func personality(_ personality: Personality?) -> String {
        guard let personality else { return "Skipped" }
        let parts: [String] = [
            personality.rhythm.map(rhythm),
            personality.food.map(food),
            personality.budget.map(budget),
            personality.vibe.map(vibe),
        ].compactMap(\.self)
        return parts.isEmpty ? "No preference" : parts.joined(separator: " · ")
    }

    // MARK: Me's one-line summaries

    /// Me's row value for a survey page.
    static func summary(of page: SurveyPage, in profile: Profile) -> String {
        switch page {
        case .origin:
            let country = profile.nationality.map(country) ?? "Country skipped"
            return "\(country) · \(language(profile.homeLanguage))"
        case .languages:
            return list(profile.spokenLanguages?.map(language))
        case .diet:
            guard let diet = profile.diet else { return "Skipped" }
            var parts = diet.map(Self.diet)
            if let notes = profile.dietNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                parts.append(notes)
            }
            return parts.isEmpty ? "None" : parts.joined(separator: ", ")
        case .allergies:
            guard let allergies = profile.allergies else { return "Skipped" }
            if allergies.isEmpty { return "None" }
            return allergies.map { "\(allergen($0)) · \(severity($0.severity))" }.joined(separator: "\n")
        case .usual:
            guard profile.favourites != nil || profile.taste != nil else { return "Skipped" }
            var parts: [String] = []
            let favourites = (profile.favourites?.foods ?? []) + (profile.favourites?.drinks ?? [])
            if !favourites.isEmpty { parts.append(favourites.map(favourite).joined(separator: ", ")) }
            if let sweetness = profile.taste?.sweetness, sweetness != 2 {
                parts.append(taste(sweetness, noun: "sweet").lowercasedFirst)
            }
            if let spice = profile.taste?.spice, spice != 2 {
                parts.append(taste(spice, noun: "spicy").lowercasedFirst)
            }
            return parts.isEmpty ? "As usual" : parts.joined(separator: " · ").capitalizedFirst
        case .thisOrThat:
            return personality(profile.personality)
        case .homeBase:
            return profile.homeBase?.name ?? "Not set"
        }
    }

    /// True when the page's fields are all `null` (it was skipped).
    static func isSkipped(_ page: SurveyPage, in profile: Profile) -> Bool {
        switch page {
        case .origin: profile.nationality == nil
        case .languages: profile.spokenLanguages == nil
        case .diet: profile.diet == nil && profile.dietNotes == nil
        case .allergies: profile.allergies == nil
        case .usual: profile.favourites == nil && profile.taste == nil
        case .thisOrThat: profile.personality == nil
        case .homeBase: profile.homeBase == nil
        }
    }

    /// The home base's local address, unless it only repeats `address` with
    /// different separators (MapKit often gives Japanese addresses in both).
    static func distinctLocalAddress(of home: HomeBase) -> String? {
        guard let local = home.addressLocal else { return nil }
        guard let address = home.address else { return local }
        let squeeze = { (text: String) in text.filter { !$0.isWhitespace && $0 != "," && $0 != "，" && $0 != "、" } }
        return squeeze(local) == squeeze(address) ? nil : local
    }

    /// A language tag for local text with no tag of its own: kana means
    /// Japanese, other Han text is treated as Simplified Chinese.
    static func scriptTag(_ text: String) -> String {
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return LangCode.ja.tag }
        if text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) { return LangCode.zhHans.tag }
        return LangCode.en.tag
    }
}

nonisolated extension String {
    /// The string with its first character uppercased.
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    /// The string with its first character lowercased.
    fileprivate var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
