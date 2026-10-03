import Foundation

/// The language spoken at a place, worked out on the device and never by the
/// agent (design §4.2, decision 16).
///
/// 1. A small override table handles exceptions: Quebec → `fr`; Hong Kong and
///    Macau are Cantonese, so speech there is flagged as unsupported.
/// 2. Otherwise the region is maximized with CLDR likely subtags
///    (`Locale.Language`): CN → `zh-Hans-CN`, JP → `ja-Jpan-JP`, TW → `zh-Hant-TW`.
/// 3. The result maps to a `LangCode` row when there is one; any other language
///    is sent as its bare language code (`fr`, `ko`), which the server handles
///    best-effort.
nonisolated struct LocalLanguage: Hashable, Sendable {
    /// The BCP-47 tag for `Situation.localLanguage`, e.g. `zh-Hans`.
    var tag: String
    /// The table row, or nil for a language Ryoko has no row for.
    var langCode: LangCode?
    /// False where the spoken language differs from the written one Ryoko
    /// supports (Cantonese in Hong Kong and Macau). Translate checks this.
    var speechSupported: Bool

    /// The fallback when the region is unknown.
    static let english = LocalLanguage(tag: LangCode.en.tag, langCode: .en, speechSupported: true)

    /// - Parameters:
    ///   - countryCode: ISO 3166-1 alpha-2, e.g. `CN`.
    ///   - subdivision: the state or province if known, as a code or a name
    ///     (`QC`, `Quebec`, `Québec`). Only used for the overrides.
    static func forRegion(_ countryCode: String, subdivision: String? = nil) -> LocalLanguage {
        let region = countryCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard region.count == 2, region.allSatisfy(\.isASCII), region.allSatisfy(\.isLetter) else {
            return .english
        }

        // Overrides first.
        if region == "CA", let subdivision, isQuebec(subdivision) {
            return LocalLanguage(tag: "fr", langCode: LangCode(tag: "fr"), speechSupported: true)
        }
        if region == "HK" || region == "MO" {
            return LocalLanguage(tag: LangCode.zhHant.tag, langCode: .zhHant, speechSupported: false)
        }

        // CLDR likely subtags.
        let likely = Locale.Language(identifier: "und-\(region)").maximalIdentifier
        if let row = LangCode(tag: likely) {
            return LocalLanguage(tag: row.tag, langCode: row, speechSupported: true)
        }
        guard let code = Locale.Language(identifier: likely).languageCode?.identifier, code != "und" else {
            return .english
        }
        return LocalLanguage(tag: code, langCode: nil, speechSupported: true)
    }

    /// Whether a subdivision code or name is Quebec.
    static func isQuebec(_ subdivision: String) -> Bool {
        let folded = subdivision
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded == "qc" || folded == "quebec" || folded == "ca-qc"
    }
}
