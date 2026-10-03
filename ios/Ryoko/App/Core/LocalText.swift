import SwiftUI

/// Shows text in a local language with the right language tag (design §7.9):
/// - `.typesettingLanguage`, so Chinese gets PingFang SC (or TC) and Japanese
///   gets Hiragino, never the wrong CJK glyph variants;
/// - a speech language, so VoiceOver reads it in that language instead of the
///   device's.
///
/// SwiftUI has no `accessibilitySpeechLanguage` modifier. Checked in the iOS 27
/// simulator: this view's accessibility label carries
/// `UIAccessibilitySpeechAttributeLanguage = zh-Hans-CN` (or `ja-Jpan-JP`).
/// `.environment(\.locale, …)` does not set it, so don't use that instead.
///
/// Use it wherever local script appears. Style it like `Text`:
/// `LocalText(phrase.local, languageTag: phrase.lang).font(.title)`.
struct LocalText: View {
    private let text: String
    private let languageTag: String

    init(_ text: String, lang: LangCode) {
        self.text = text
        self.languageTag = lang.tag
    }

    /// For a BCP-47 tag from the contracts, such as `phrase.lang`. Tags without a
    /// `LangCode` row are still applied as given.
    init(_ text: String, languageTag: String) {
        self.text = text
        self.languageTag = languageTag
    }

    var body: some View {
        Text.local(text, languageTag: languageTag)
    }
}

extension Text {
    /// A `Text` tagged with `languageTag`, for when a `Text` value is needed
    /// (concatenation, labels). Prefer `LocalText` in view bodies.
    static func local(_ string: String, lang: LangCode) -> Text {
        local(string, languageTag: lang.tag)
    }

    static func local(_ string: String, languageTag: String) -> Text {
        let tag = LangCode(tag: languageTag)?.tag ?? languageTag
        var attributed = AttributedString(string)
        // The language attribute and the typesetting language both tag the text;
        // together they put the speech language on VoiceOver's label.
        attributed.languageIdentifier = tag
        return Text(attributed)
            .typesettingLanguage(Locale.Language(identifier: tag))
    }
}
