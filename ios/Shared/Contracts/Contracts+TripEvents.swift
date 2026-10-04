import Foundation

// Mirror of contracts/src/trip-events.ts (design §8.3, after core): what the
// traveller did on the trip, for Mimo's trip memory (Tiger Data). The app sends
// small batches and never waits on the answer. A server without Tiger (or in
// fixture mode) accepts them and stores nothing.

// MARK: - POST /v1/trip-events

/// What happened. A closed set the device sends.
nonisolated enum TripEventKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// "I'm here" at a place.
    case placeConfirmed = "place_confirmed"
    /// A phrase opened in Show mode.
    case phraseShown = "phrase_shown"
    /// A phrase played aloud with Speak.
    case phraseSpoken = "phrase_spoken"
    /// A typed (or edited) turn in Translate.
    case typedTranslation = "typed_translation"
}

/// The place an event happened at.
nonisolated struct TripEventPlace: Codable, Hashable, Sendable {
    /// 1–120 characters.
    var name: String
    /// 1–120 characters.
    var localName: String?
    var category: CategorySlug?
}

nonisolated struct TripEvent: Codable, Hashable, Sendable {
    var kind: TripEventKind
    /// Local time with its UTC offset when it happened, in the situation's
    /// `localTime` format, e.g. `2026-10-05T19:42:00+09:00`.
    var at: String
    /// 1–300 characters: the phrase in local script, what was typed, or the
    /// place name (`placeConfirmed`).
    var text: String
    /// 1–300 characters: a phrase's meaning in the home language, or a typed
    /// text's translation.
    var meaning: String?
    /// BCP-47 tag of `text`.
    var language: String?
    var place: TripEventPlace?
    /// 1–80 characters.
    var city: String?
    /// ISO 3166-1 alpha-2.
    var countryCode: String?
}

nonisolated struct TripEventsRequest: Codable, Hashable, Sendable {
    /// The most events one request may carry (`TRIP_EVENTS_MAX`).
    static let maxEvents = 20

    /// 1–20 events.
    var events: [TripEvent]
}

nonisolated struct TripEventsResponse: Codable, Hashable, Sendable {
    /// How many were stored: 0 when trip memory is off, and repeats are skipped.
    var stored: Int
}

// MARK: - Cleaning

nonisolated extension TripEventPlace {
    /// The contract's `maxLength` for `name` and `localName`.
    static let maxNameLength = 120

    init(_ place: Place) {
        self.init(name: place.name, localName: place.localName, category: place.category)
    }
}

nonisolated extension TripEvent {
    /// The contract's `maxLength` for `text` and `meaning`.
    static let maxTextLength = 300
    /// The contract's `maxLength` for `city`.
    static let maxCityLength = 80

    /// The event as the server accepts it, so one odd event never gets a batch
    /// refused: text, meaning and names trimmed and cut to their limits, empty
    /// ones left out, and a language tag or country code that doesn't fit the
    /// contract left out. nil when no text is left.
    func cleaned() -> TripEvent? {
        guard let text = Self.clipped(text, to: Self.maxTextLength) else { return nil }
        var cleaned = self
        cleaned.text = text
        cleaned.meaning = Self.clipped(meaning, to: Self.maxTextLength)
        cleaned.language = language.flatMap { Self.isLanguageTag($0) ? $0 : nil }
        cleaned.place = place.flatMap { place in
            Self.clipped(place.name, to: TripEventPlace.maxNameLength).map {
                TripEventPlace(
                    name: $0,
                    localName: Self.clipped(place.localName, to: TripEventPlace.maxNameLength),
                    category: place.category
                )
            }
        }
        cleaned.city = Self.clipped(city, to: Self.maxCityLength)
        cleaned.countryCode = countryCode.map { $0.uppercased() }.flatMap { Self.isCountryCode($0) ? $0 : nil }
        return cleaned
    }

    /// `text` trimmed and cut to `limit` at a character boundary, or nil when
    /// nothing is left. Counted in Unicode scalars, as for `Profile.aboutMe`:
    /// TypeBox's count is never more than that.
    static func clipped(_ text: String?, to limit: Int) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.count > limit else { return trimmed }
        var clipped = ""
        var used = 0
        for character in trimmed {
            let size = character.unicodeScalars.count
            guard used + size <= limit else { break }
            clipped.append(character)
            used += size
        }
        let result = clipped.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// The contract's `LanguageTag` pattern: `^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$`.
    private static func isLanguageTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first, (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (2...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// The contract's `CountryCode` pattern: `^[A-Z]{2}$`.
    private static func isCountryCode(_ code: String) -> Bool {
        code.count == 2 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    }
}
