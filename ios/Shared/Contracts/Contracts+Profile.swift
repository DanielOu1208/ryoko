import Foundation

// Mirror of contracts/src/profile.ts (design §7.2).
// In the profile, `nil` means the survey page or field was skipped and is
// written as `null`; an empty array means "none". The profile's one optional
// key, `aboutMe`, is left out instead.

nonisolated enum Diet: String, Codable, Hashable, Sendable, CaseIterable {
    case vegetarian
    case vegan
    case halal
    case kosher
    case noPork = "no_pork"
    case noBeef = "no_beef"
    case glutenFree = "gluten_free"
    case lactoseFree = "lactose_free"
}

/// Chip allergens plus `custom`, which carries a free-text `label`.
nonisolated enum AllergenId: String, Codable, Hashable, Sendable, CaseIterable {
    case egg
    case milk
    case mustard
    case peanut
    case crustaceanMollusc = "crustacean_mollusc"
    case fish
    case sesame
    case soy
    case sulphite
    case treeNut = "tree_nut"
    case wheat
    case custom

    /// The eleven chip allergens, which have reviewed templates (no `custom`).
    static let chips: [AllergenId] = allCases.filter { $0 != .custom }
}

nonisolated enum Severity: String, Codable, Hashable, Sendable, CaseIterable {
    case mild
    case serious
    case lifeThreatening = "life_threatening"
}

/// A chip allergy is `{id, severity}`; a custom one is `{id: "custom", label, severity}`.
/// Set `label` only when `id == .custom`: the server rejects it on a chip allergy.
nonisolated struct Allergy: Codable, Hashable, Sendable {
    var id: AllergenId
    var label: String?
    var severity: Severity
}

nonisolated struct Favourites: Codable, Hashable, Sendable {
    var foods: [String]
    var drinks: [String]
}

/// Sliders from 0 to 4, where 2 is "as usual". `nil` means the slider was skipped.
nonisolated struct Taste: Codable, Hashable, Sendable {
    var sweetness: Int?
    var spice: Int?

    private enum CodingKeys: String, CodingKey { case sweetness, spice }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sweetness, forKey: .sweetness)
        try c.encode(spice, forKey: .spice)
    }
}

/// The four "this or that" pairs. Each may be `nil` (skipped).
nonisolated struct Personality: Codable, Hashable, Sendable {
    nonisolated enum Rhythm: String, Codable, Hashable, Sendable, CaseIterable {
        case earlyBird = "early_bird"
        case nightOwl = "night_owl"
    }

    nonisolated enum Food: String, Codable, Hashable, Sendable, CaseIterable {
        case localFavourite = "local_favourite"
        case myUsual = "my_usual"
    }

    nonisolated enum Budget: String, Codable, Hashable, Sendable, CaseIterable {
        case save
        case splurge
    }

    nonisolated enum Vibe: String, Codable, Hashable, Sendable, CaseIterable {
        case quiet
        case lively
    }

    var rhythm: Rhythm?
    var food: Food?
    var budget: Budget?
    var vibe: Vibe?

    private enum CodingKeys: String, CodingKey { case rhythm, food, budget, vibe }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rhythm, forKey: .rhythm)
        try c.encode(food, forKey: .food)
        try c.encode(budget, forKey: .budget)
        try c.encode(vibe, forKey: .vibe)
    }
}

/// Where the traveller is staying: the taxi card's default destination (design §4.6).
nonisolated struct HomeBase: Codable, Hashable, Sendable {
    var name: String
    var localName: String?
    var address: String?
    var addressLocal: String?
    var coordinate: Coordinate
}

nonisolated struct Profile: Codable, Hashable, Sendable {
    /// sha-256 (lowercase hex) of the canonical JSON of the profile without `version`
    /// (contracts/src/canonical.ts). The server treats it as an opaque cache key.
    var version: String
    /// ISO 3166-1 alpha-2, e.g. `CA`.
    var nationality: String?
    /// BCP-47, e.g. `en`.
    var homeLanguage: String
    var spokenLanguages: [String]?
    var diet: [Diet]?
    var dietNotes: String?
    var allergies: [Allergy]?
    var favourites: Favourites?
    var taste: Taste?
    var personality: Personality?
    var homeBase: HomeBase?
    /// The traveller's own words about themselves, typed in Me ("About me").
    /// Optional in the contract: the key is left out when there's none, never
    /// `null` or empty, so profiles from before it existed keep their version.
    /// Set it through `Profile.cleanedAboutMe(_:)`.
    var aboutMe: String?

    private enum CodingKeys: String, CodingKey {
        case version, nationality, homeLanguage, spokenLanguages, diet, dietNotes
        case allergies, favourites, taste, personality, homeBase, aboutMe
    }

    // The contract's required keys are always written, so skipped fields are
    // `null`. `aboutMe` is optional: written only when set. (Decoding is
    // synthesized, so a missing `aboutMe` key reads as nil.)
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(nationality, forKey: .nationality)
        try c.encode(homeLanguage, forKey: .homeLanguage)
        try c.encode(spokenLanguages, forKey: .spokenLanguages)
        try c.encode(diet, forKey: .diet)
        try c.encode(dietNotes, forKey: .dietNotes)
        try c.encode(allergies, forKey: .allergies)
        try c.encode(favourites, forKey: .favourites)
        try c.encode(taste, forKey: .taste)
        try c.encode(personality, forKey: .personality)
        try c.encode(homeBase, forKey: .homeBase)
        try c.encodeIfPresent(aboutMe, forKey: .aboutMe)
    }
}

// MARK: - About me

nonisolated extension Profile {
    /// The contract's `maxLength` for `aboutMe`.
    static let aboutMeLimit = 500

    /// How much of `aboutMeLimit` the text uses, counted in Unicode scalars.
    ///
    /// The server checks `maxLength` with TypeBox, whose character count is
    /// never more than the number of scalars, but can be more than Swift's
    /// characters (Thai and Hindi marks, skin tones, `\r\n`). Counting scalars
    /// keeps a capped text valid in any script; for most text it's the same as
    /// the number of characters.
    static func aboutMeLength(of text: String) -> Int {
        text.unicodeScalars.count
    }

    /// `text` cut to `aboutMeLimit` at a character boundary, untrimmed (the
    /// field while typing).
    static func cappedAboutMe(_ text: String) -> String {
        guard aboutMeLength(of: text) > aboutMeLimit else { return text }
        var capped = ""
        var used = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard used + size <= aboutMeLimit else { break }
            capped.append(character)
            used += size
        }
        return capped
    }

    /// The value to store: trimmed and capped, or nil when nothing is left
    /// (the contract allows no empty string).
    static func cleanedAboutMe(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = cappedAboutMe(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
