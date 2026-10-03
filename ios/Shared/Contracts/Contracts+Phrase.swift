import Foundation

// Mirror of contracts/src/phrase.ts (design §6.2, §7.3).
// One Phrase type for Now's cards, place sheets, Mimo's phrase blocks and Show mode.
// The contract's `CardPhrase` (place cards) is the same shape with `because` and
// `basis` required; Swift uses this one type for both.

nonisolated struct Phrase: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// BCP-47 tag of `local`, e.g. `zh-Hans`.
    var lang: String
    /// The phrase in local script.
    var local: String
    /// Pinyin or romaji; nil for Latin-script languages (written as `null`).
    var romanization: String?
    /// Meaning in the home language.
    var gloss: String
    /// About 8–10 words in the home language. Present on place-card phrases.
    var because: String?
    /// One or two inputs the "because…" line rests on. Present on place-card phrases.
    var basis: [Basis]?

    private enum CodingKeys: String, CodingKey {
        case id, lang, local, romanization, gloss, because, basis
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(lang, forKey: .lang)
        try c.encode(local, forKey: .local)
        try c.encode(romanization, forKey: .romanization) // required key, may be `null`
        try c.encode(gloss, forKey: .gloss)
        try c.encodeIfPresent(because, forKey: .because)
        try c.encodeIfPresent(basis, forKey: .basis)
    }
}

/// A cultural tip on a place card, in the home language.
nonisolated struct Tip: Codable, Hashable, Sendable {
    var text: String
    var basis: [Basis]
}
