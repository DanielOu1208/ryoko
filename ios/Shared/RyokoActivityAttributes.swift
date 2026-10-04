import ActivityKit
import Foundation

/// The Live Activity for the active place (design §4.11). The app starts and
/// updates it (`LiveActivityCoordinator`); the extension renders it.
///
/// Every field is a short string, clamped when built: the whole payload must
/// stay well under ActivityKit's 4 KB.
///
/// `nonisolated` because the two targets use different default actor
/// isolation, and this type must be usable from both.
nonisolated struct RyokoActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// The place card's top phrase, or nil until it arrives (or if it can't).
        var phrase: ActivityPhrase?
        /// True while the place card is loading: the views show a placeholder.
        var isLoading: Bool
        /// The committed time of a look-ahead preview; nil for the live place.
        /// It can change while the activity runs (the preview's time picker).
        var previewDate: Date?

        /// The first content: a placeholder until the place card arrives.
        static func placeholder(previewDate: Date?) -> ContentState {
            ContentState(phrase: nil, isLoading: true, previewDate: previewDate)
        }
    }

    var placeName: String
    /// The city, shown beside the local clock so it reads as that city's time.
    var city: String
    /// The category's SF Symbol (`CategorySlug.sfSymbol`).
    var categorySymbol: String
    /// IANA time zone of the place, for the local clock.
    var timeZoneID: String
    var isPreview: Bool

    init(placeName: String, city: String, categorySymbol: String, timeZoneID: String, isPreview: Bool) {
        self.placeName = ActivityText.clamp(placeName, to: ActivityText.nameLimit)
        self.city = ActivityText.clamp(city, to: ActivityText.nameLimit)
        self.categorySymbol = ActivityText.clamp(categorySymbol, to: ActivityText.idLimit)
        self.timeZoneID = ActivityText.clamp(timeZoneID, to: ActivityText.idLimit)
        self.isPreview = isPreview
    }
}

/// The phrase a Live Activity shows: just what the lock screen and the Dynamic
/// Island need, plus the id for the deep link. The app keeps the full `Phrase`
/// (`LiveActivityPhraseStore`) to open in Show mode.
nonisolated struct ActivityPhrase: Codable, Hashable, Sendable {
    var id: String
    /// BCP-47 tag of `local`.
    var lang: String
    var local: String
    var gloss: String

    init(id: String, lang: String, local: String, gloss: String) {
        self.id = ActivityText.clamp(id, to: ActivityText.idLimit)
        self.lang = ActivityText.clamp(lang, to: ActivityText.idLimit)
        self.local = ActivityText.clamp(local, to: ActivityText.localLimit)
        self.gloss = ActivityText.clamp(gloss, to: ActivityText.glossLimit)
    }

    init(_ phrase: Phrase) {
        self.init(id: phrase.id, lang: phrase.lang, local: phrase.local, gloss: phrase.gloss)
    }
}

nonisolated extension RyokoActivityAttributes {
    /// A short place name for the Dynamic Island's compact trailing slot:
    /// the part before a branch or district suffix ("Heytea (Jing'an)" →
    /// "Heytea"), then as many whole words as fit `limit` characters.
    var shortPlaceName: String { Self.shortName(placeName) }

    static func shortName(_ name: String, limit: Int = 12) -> String {
        let separators: Set<Character> = ["(", "（", "·", ",", "，", "|", "/", "–", "—"]
        let head = name.split(whereSeparator: { separators.contains($0) }).first.map(String.init) ?? name
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? name.trimmingCharacters(in: .whitespaces) : trimmed
        guard base.count > limit else { return base }
        var kept = ""
        for word in base.split(separator: " ") {
            let next = kept.isEmpty ? String(word) : kept + " " + word
            if next.count > limit { break }
            kept = next
        }
        if !kept.isEmpty { return kept }
        return String(base.prefix(limit - 1)) + "…"
    }
}

/// Length limits that keep the payload small. Generous for real names and
/// phrases (a place-card phrase is one short sentence); anything longer is cut
/// with an ellipsis.
nonisolated enum ActivityText {
    static let nameLimit = 60
    static let idLimit = 64
    static let localLimit = 80
    static let glossLimit = 120

    static func clamp(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// The encoded size of an activity's attributes and content, in bytes.
    static func payloadSize(
        _ attributes: RyokoActivityAttributes,
        _ state: RyokoActivityAttributes.ContentState
    ) -> Int {
        let encoder = JSONEncoder()
        let a = (try? encoder.encode(attributes).count) ?? 0
        let s = (try? encoder.encode(state).count) ?? 0
        return a + s
    }
}
