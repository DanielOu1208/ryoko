import Foundation

/// Whether text is written in a language's script (design §4.6). The taxi card
/// uses it to decide if a MapKit name or a stored local name can be shown to a
/// local driver.
///
/// MapKit names follow the app's UI language, not `preferredLocale` (D1). So a
/// Han-only name is only trusted for Chinese or Japanese when the UI language
/// isn't a *different* CJK language: under a Chinese UI, Tokyo places come back
/// as Chinese renderings, which are CJK but not Japanese.
nonisolated enum ScriptMatch {
    struct Scripts: Equatable {
        var han = false
        var kana = false
        var hangul = false
        var latin = false
    }

    static func scripts(in text: String) -> Scripts {
        var scripts = Scripts()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if scalar.properties.isIdeographic {
                scripts.han = true
            } else if (0x3040...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value) || (0xFF66...0xFF9D).contains(value) {
                scripts.kana = true
            } else if (0xAC00...0xD7AF).contains(value) || (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value) {
                scripts.hangul = true
            } else if scalar.properties.isAlphabetic, value < 0x0250 || (0x1E00...0x1EFF).contains(value) {
                scripts.latin = true
            }
        }
        return scripts
    }

    /// - Parameters:
    ///   - language: the target BCP-47 tag, e.g. `ja`.
    ///   - fromMapKit: true for a name MapKit returned, which follows the UI
    ///     language; false for text stored in the target language (home base).
    static func matches(_ text: String, language: String, fromMapKit: Bool = false, uiLanguage: String? = Locale.preferredLanguages.first) -> Bool {
        let scripts = scripts(in: text)
        let target = LangCode(tag: language)
        let primary = primarySubtag(language)
        // A name MapKit wrote in another CJK language isn't this one's, even if the script looks alike.
        let otherCJKUI: Bool = {
            guard fromMapKit, let ui = uiLanguage.flatMap(LangCode.init(tag:)), isCJK(ui) else { return false }
            return ui != target
        }()
        switch target {
        case .ja?:
            return scripts.kana || (scripts.han && !otherCJKUI)
        case .zhHans?, .zhHant?:
            return scripts.han && !scripts.kana && !otherCJKUI
        default:
            if primary == "ko" { return scripts.hangul }
            return scripts.latin && !scripts.han && !scripts.kana && !scripts.hangul
        }
    }

    /// The tag to set on text that may or may not be in `language`: `language`
    /// when it matches, otherwise the device's language (a fallback address).
    static func languageTag(for text: String, preferring language: String) -> String {
        if matches(text, language: language) { return language }
        return Locale.preferredLanguages.first ?? LangCode.en.tag
    }

    private static func primarySubtag(_ tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    private static func isCJK(_ lang: LangCode) -> Bool {
        lang == .zhHans || lang == .zhHant || lang == .ja
    }
}
