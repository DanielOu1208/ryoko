import Foundation

// Mirrors of contracts/src/translate.ts and soniox-key.ts (design §4.8, §6.4,
// tier 2): Translate's typed text, and the short-lived Soniox keys.

// MARK: - POST /v1/translate

nonisolated struct TranslateRequest: Codable, Hashable, Sendable {
    /// The longest text Type mode sends (`TRANSLATE_MAX_CHARS`).
    static let maxCharacters = 500

    /// What you typed, in your language. 1–500 characters.
    var text: String
    /// BCP-47 tag of `text`, e.g. `en`.
    var from: String
    /// BCP-47 tag to translate into, e.g. `zh-Hans`.
    var to: String
    /// The active situation, so the wording fits the place. Omitted when there's
    /// none (a pair picked by hand with no place).
    var situation: Situation?
}

nonisolated struct TranslateResponse: Codable, Hashable, Sendable {
    /// The text in the `to` language.
    var translation: String
}

// MARK: - POST /v1/soniox-key

/// The request body: an empty JSON object.
nonisolated struct SonioxKeyRequest: Codable, Hashable, Sendable {}

/// A temporary Soniox key for one real-time session (single use, about a minute
/// to open it). The key is a secret: its descriptions are redacted so it can't
/// reach a log by accident.
nonisolated struct SonioxKeyResponse: Codable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var apiKey: String
    /// When the key stops working for new sessions (ISO 8601).
    var expiresAt: String

    var description: String { "SonioxKeyResponse(apiKey: <\(apiKey.count) characters>, expiresAt: \(expiresAt))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["apiKey": "<redacted>", "expiresAt": expiresAt], displayStyle: .struct)
    }
}
