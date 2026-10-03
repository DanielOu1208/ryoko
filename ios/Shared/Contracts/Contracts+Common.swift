import Foundation

// Swift mirrors of contracts/src/common.ts (design §7). Field names match the
// JSON exactly. Everything in Shared/ is also compiled into the Live Activity
// extension, which doesn't default to MainActor, so every type here is
// `nonisolated` and `Sendable`, and Foundation is the only import.
//
// Conventions:
// - Optional contract fields (`Type.Optional`) are Swift optionals and are
//   omitted from the JSON when nil.
// - Required-but-nullable fields (`Nullable(...)`) are Swift optionals too, but
//   their types write an explicit `null`, because the server rejects a missing key.
// - Closed sets the device sends (diet, allergens, severity) are Swift enums.
//   Open sets the server sends (basis, tool names, stop reasons, error codes)
//   are `RawRepresentable` structs, so a new value never breaks decoding.

nonisolated struct Coordinate: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
}

/// Place category slug, from contracts/tables/categories.json.
/// Unknown slugs decode as `.other`, so a new server category never breaks a response.
nonisolated enum CategorySlug: String, Codable, Hashable, Sendable, CaseIterable {
    case cafe
    case tea
    case restaurant
    case ramen
    case bar
    case bakery
    case convenienceStore = "convenience_store"
    case museum
    case park
    case templeShrine = "temple_shrine"
    case shopping
    case transit
    case hotel
    case other

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CategorySlug(rawValue: raw) ?? .other
    }
}

/// Which personalization input a "because…" line or tip rests on (design §5, §7.3).
nonisolated struct Basis: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let place = Basis(rawValue: "place")
    static let localTime = Basis(rawValue: "localTime")
    static let personality = Basis(rawValue: "personality")
    static let nationality = Basis(rawValue: "nationality")
    static let diet = Basis(rawValue: "diet")
    static let allergy = Basis(rawValue: "allergy")
    static let favourites = Basis(rawValue: "favourites")
    static let taste = Basis(rawValue: "taste")
    static let memory = Basis(rawValue: "memory")

    /// Every value the contract defines today.
    static let known: [Basis] = [.place, .localTime, .personality, .nationality, .diet, .allergy, .favourites, .taste, .memory]
}
