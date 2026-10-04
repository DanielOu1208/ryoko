import Foundation

/// The choices the survey offers, and the contract's limits (design §7.2,
/// contracts/src/profile.ts). Values are what goes into the profile; display
/// names come from `ProfileWording`.
nonisolated enum SurveyOptions {
    // MARK: Limits from the Profile schema

    static let maxFavourites = 20
    static let maxFavouriteLength = 60
    static let maxAllergies = 20
    static let maxAllergyLabelLength = 60
    static let maxDietNotesLength = 300
    static let maxSpokenLanguages = 10
    static let maxHomeBaseNameLength = 120
    static let maxAddressLength = 240

    // MARK: Countries

    /// Every ISO 3166-1 alpha-2 region with a display name, sorted by name.
    static let countries: [String] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter(isCountryCode)
        .filter { ProfileWording.countryName($0) != nil }
        .sorted { ProfileWording.country($0).localizedStandardCompare(ProfileWording.country($1)) == .orderedAscending }

    /// `^[A-Z]{2}$`, as the schema requires.
    static func isCountryCode(_ code: String) -> Bool {
        code.count == 2 && code.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
    }

    /// The device's region, when it's a country.
    static var deviceCountry: String? {
        guard let code = Locale.current.region?.identifier, isCountryCode(code) else { return nil }
        return code
    }

    // MARK: Languages

    /// Shown as chips on the languages page. The first three are Ryoko's
    /// first-class languages (design §2).
    static let commonLanguages: [String] = [
        "en", "zh-Hans", "ja", "zh-Hant", "yue", "ko", "es", "fr", "de", "hi",
    ]

    /// The longer list behind "More languages", as BCP-47 tags.
    static let allLanguages: [String] = {
        let extra = [
            "ar", "bn", "ca", "cs", "da", "el", "fa", "fi", "fil", "he", "hr", "hu", "id", "it",
            "km", "lo", "ms", "my", "nb", "ne", "nl", "pa", "pl", "pt", "ro", "ru", "si", "sk",
            "sr", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "vi",
        ]
        return (commonLanguages + extra).sorted {
            ProfileWording.language($0).localizedStandardCompare(ProfileWording.language($1)) == .orderedAscending
        }
    }()

    /// `^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$`, as the schema requires.
    static func isLanguageTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count),
              first.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (2...8).contains(part.count) && part.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) }
        }
    }

    /// The device's language as a profile tag: the bare language code, plus
    /// the script for Chinese (`zh-Hans`, `zh-Hant`). English if it can't tell.
    static var deviceLanguage: String {
        guard let identifier = Locale.preferredLanguages.first else { return LangCode.en.tag }
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier.lowercased() else { return LangCode.en.tag }
        if code == "zh" { return LangCode(tag: identifier)?.tag ?? LangCode.zhHans.tag }
        return isLanguageTag(code) ? code : LangCode.en.tag
    }

    // MARK: Favourites

    /// Food chips. Stored lowercase, as written here.
    static let foods = [
        "noodles", "dumplings", "rice dishes", "seafood", "street food", "barbecue", "hot pot", "desserts",
    ]

    /// Drink chips. Stored lowercase, as written here.
    static let drinks = [
        "coffee", "tea", "fruit tea", "milk tea", "matcha", "juice", "beer", "wine",
    ]

    /// Trims typed text and caps it at `limit` characters. nil when empty.
    static func cleaned(_ text: String, limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}
