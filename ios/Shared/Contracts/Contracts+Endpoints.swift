import Foundation

// Mirrors of the JSON endpoints: contracts/src/place-card.ts, discover.ts and
// allergy-card.ts (design §6.5, §7.4–7.6).

// MARK: - POST /v1/place-card

nonisolated struct PlaceCardRequest: Codable, Hashable, Sendable {
    var profile: Profile
    var situation: Situation
}

nonisolated struct PlaceCardResponse: Codable, Hashable, Sendable {
    /// BCP-47 tag of the phrases.
    var language: String
    /// Two or three phrases, each with `because` and `basis`.
    var phrases: [Phrase]
    /// One or two tips.
    var tips: [Tip]
    /// The place's name in local script, for the taxi card (design §4.6).
    var placeNameLocal: String?
    var addressLocal: String?
    /// Server timestamp (ISO 8601).
    var generatedAt: String
}

// MARK: - POST /v1/discover

nonisolated struct DiscoverArea: Codable, Hashable, Sendable {
    var center: Coordinate
    /// 100–5000; the app sends 1500.
    var radiusMeters: Int
    var city: String
    var district: String?
}

nonisolated struct DiscoverRequest: Codable, Hashable, Sendable {
    var area: DiscoverArea
    var profile: Profile
    var situation: Situation
}

nonisolated struct DiscoverPlace: Codable, Hashable, Sendable {
    var name: String
    var localName: String
    /// One line in the home language, at most 60 characters.
    var why: String
    var category: CategorySlug
    /// Short display text in the home language, e.g. "Mornings".
    var bestTime: String?
}

nonisolated struct DiscoverResponse: Codable, Hashable, Sendable {
    /// Five to eight places.
    var places: [DiscoverPlace]
}

// MARK: - POST /v1/allergy-card (free-text allergens only)

nonisolated struct AllergyCardRequest: Codable, Hashable, Sendable {
    /// The local language to write the card in.
    var language: String
    var homeLanguage: String
    /// Custom allergies only (`id == .custom` with a `label`). Chip allergens use
    /// the bundled templates and never call the server.
    var allergies: [Allergy]
}

nonisolated struct AllergyCardItem: Codable, Hashable, Sendable {
    var allergenId: AllergenId
    var local: String
    var home: String
    var severity: Severity
}

nonisolated struct AllergyCardResponse: Codable, Hashable, Sendable {
    var language: String
    /// Card title in the local language.
    var title: String
    var items: [AllergyCardItem]
    /// Asks whether the dish contains these, in the local language.
    var requestLocal: String
    var requestHome: String
    /// Romanization of `requestLocal`.
    var romanization: String?
    /// Always false for generated cards; show "Not reviewed".
    var reviewed: Bool
}
