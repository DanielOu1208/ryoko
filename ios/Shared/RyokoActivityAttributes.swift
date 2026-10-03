import ActivityKit
import Foundation

/// Shared by the app (which starts and updates the activity) and the
/// Live Activity extension (which renders it). Keep every field a short
/// string: the whole payload must stay under 4 KB.
///
/// `nonisolated` because the two targets use different default actor
/// isolation, and this type must be usable from both.
nonisolated struct RyokoActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// The top phrase in local script.
        var phraseLocal: String
        /// A short gloss of the phrase in the traveller's language.
        var phraseGloss: String
        /// Set while previewing a place; nil for the real current place.
        var previewDate: Date?
    }

    var placeName: String
    var categorySymbol: String
    var timeZoneID: String
    var isPreview: Bool
}
