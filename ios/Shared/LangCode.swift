import Foundation

/// The language table (design §7.9), written by hand from
/// contracts/tables/langcodes.json. Keep the two in step.
///
/// The raw value is the BCP-47 tag used everywhere in the contracts.
nonisolated enum LangCode: String, Codable, Hashable, Sendable, CaseIterable {
    case zhHans = "zh-Hans"
    case ja
    case en
    /// Best effort, pending a decision on a Taipei stop. Taiwan Mandarin only:
    /// Hong Kong speech is Cantonese and unsupported. No allergy templates yet.
    case zhHant = "zh-Hant"

    nonisolated enum Status: String, Sendable {
        case supported
        case bestEffort = "best_effort"
    }

    nonisolated enum Romanization: String, Sendable {
        case pinyin
        case romaji
        case none
    }

    nonisolated enum RomanizationSource: String, Sendable {
        /// `pinyin-pro`, run on the server.
        case pinyinPro = "pinyin-pro"
        /// Written by the model.
        case model
        case none
    }

    /// The BCP-47 tag, e.g. `zh-Hans`.
    var tag: String { rawValue }

    var status: Status {
        self == .zhHant ? .bestEffort : .supported
    }

    /// English display name.
    var displayName: String {
        switch self {
        case .zhHans: "Chinese (Simplified)"
        case .ja: "Japanese"
        case .en: "English"
        case .zhHant: "Chinese (Traditional)"
        }
    }

    /// The language's name for itself, in its own script.
    var nativeName: String {
        switch self {
        case .zhHans: "简体中文"
        case .ja: "日本語"
        case .en: "English"
        case .zhHant: "繁體中文"
        }
    }

    /// Soniox language code.
    var sonioxCode: String {
        switch self {
        case .zhHans, .zhHant: "zh"
        case .ja: "ja"
        case .en: "en"
        }
    }

    /// Locale identifier for geocoding (`MKReverseGeocodingRequest.preferredLocale`).
    var localeIdentifier: String {
        switch self {
        case .zhHans: "zh_Hans_CN"
        case .ja: "ja_JP"
        case .en: "en"
        case .zhHant: "zh_Hant_TW"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    /// For `.typesettingLanguage`, so CJK text gets PingFang SC / Hiragino / PingFang TC.
    var language: Locale.Language { Locale.Language(identifier: rawValue) }

    var romanization: Romanization {
        switch self {
        case .zhHans, .zhHant: .pinyin
        case .ja: .romaji
        case .en: .none
        }
    }

    var romanizationSource: RomanizationSource {
        switch self {
        case .zhHans, .zhHant: .pinyinPro
        case .ja: .model
        case .en: .none
        }
    }

    /// Tier 2 voice id. None picked yet.
    var voice: String? { nil }

    /// Region codes that map to this language (CLDR likely subtags).
    var regions: [String] {
        switch self {
        case .zhHans: ["CN"]
        case .ja: ["JP"]
        case .en: ["CA", "US", "GB", "AU", "NZ", "IE"]
        case .zhHant: ["TW", "HK"]
        }
    }

    /// The language for a place's ISO region code, e.g. `CN` → `.zhHans`.
    /// Overrides such as Quebec → `fr` and Hong Kong speech being unsupported
    /// belong to the situation store (design §4.2).
    static func forRegion(_ countryCode: String) -> LangCode? {
        let region = countryCode.uppercased()
        return allCases.first { $0.regions.contains(region) }
    }

    /// Looks up a BCP-47 tag leniently: `zh-Hans`, `zh-CN` and `zh_Hans_CN` all give
    /// `.zhHans`; `zh-TW` and `zh-HK` give `.zhHant`; `ja-JP` gives `.ja`.
    init?(tag: String) {
        if let exact = LangCode(rawValue: tag) {
            self = exact
            return
        }
        let language = Locale.Language(identifier: tag.replacingOccurrences(of: "_", with: "-"))
        switch language.languageCode?.identifier {
        case "ja":
            self = .ja
        case "en":
            self = .en
        case "zh":
            if let script = language.script?.identifier {
                self = script == "Hant" ? .zhHant : .zhHans
            } else if let region = language.region?.identifier, ["TW", "HK", "MO"].contains(region) {
                self = .zhHant
            } else {
                self = .zhHans
            }
        default:
            return nil
        }
    }
}
