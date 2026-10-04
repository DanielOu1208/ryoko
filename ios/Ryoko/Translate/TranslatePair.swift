import Foundation

/// One side of Translate's language pair: a BCP-47 tag for display and
/// `LocalText`, and the Soniox code for the session.
nonisolated struct PairLanguage: Hashable, Sendable, Identifiable {
    /// BCP-47 tag, e.g. `zh-Hans`.
    var tag: String
    /// Soniox code, e.g. `zh`.
    var sonioxCode: String
    /// English name, e.g. `Chinese`.
    var name: String
    /// The language's name in its own script, e.g. `中文`.
    var nativeName: String

    var id: String { tag }

    init(tag: String, sonioxCode: String, name: String, nativeName: String) {
        self.tag = tag
        self.sonioxCode = sonioxCode
        self.name = name
        self.nativeName = nativeName
    }

    init(_ lang: LangCode) {
        self.init(tag: lang.tag, sonioxCode: lang.sonioxCode, name: Self.shortName(lang), nativeName: Self.shortNativeName(lang))
    }

    /// Any BCP-47 tag. Tags with a `LangCode` row use it; others (`fr`, `ko`)
    /// use their bare language code, which is also the Soniox code.
    init?(tag: String) {
        if let row = LangCode(tag: tag) {
            self.init(row)
            return
        }
        let language = Locale.Language(identifier: tag.replacingOccurrences(of: "_", with: "-"))
        guard let code = language.languageCode?.identifier, code != "und", code.count <= 3 else { return nil }
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        let nativeName = Locale(identifier: code).localizedString(forLanguageCode: code) ?? name
        self.init(tag: code, sonioxCode: code, name: name, nativeName: nativeName)
    }

    /// Short names for the pair label: "Chinese", not "Chinese (Simplified)".
    private static func shortName(_ lang: LangCode) -> String {
        switch lang {
        case .zhHans: "Chinese"
        case .zhHant: "Chinese (Traditional)"
        case .ja, .en: lang.displayName
        }
    }

    private static func shortNativeName(_ lang: LangCode) -> String {
        switch lang {
        case .zhHans: "中文"
        case .zhHant: "中文（繁體）"
        case .ja, .en: lang.nativeName
        }
    }

    /// A short prompt in this language for the other person, shown in the
    /// face-to-face half that faces them. nil when there's no reviewed text.
    var speakPrompt: String? {
        switch LangCode(rawValue: tag) {
        case .zhHans: "请说中文"
        case .zhHant: "請說中文"
        case .ja: "日本語で話してください"
        case .en: "Please speak English"
        case nil: nil
        }
    }
}

/// Translate's language pair (design §4.8): your home language and the other
/// person's. A session keeps the pair it started with.
nonisolated struct TranslatePair: Hashable, Sendable {
    var home: PairLanguage
    var other: PairLanguage

    /// "English ⇄ Chinese".
    var label: String { "\(home.name) ⇄ \(other.name)" }

    var sonioxConfig: SonioxConfig {
        SonioxConfig(languageA: home.sonioxCode, languageB: other.sonioxCode)
    }

    /// The Soniox code of the language `speaker` speaks: yours, or the other person's.
    func sonioxCode(for speaker: TurnSpeaker) -> String {
        speaker == .me ? home.sonioxCode : other.sonioxCode
    }

    /// Whether Soniox can translate between the two (they differ).
    var isUsable: Bool { home.sonioxCode != other.sonioxCode }

    /// The pair language for a Soniox code, if it's one of the two.
    func language(forSoniox code: String?) -> PairLanguage? {
        guard let code else { return nil }
        if code == home.sonioxCode { return home }
        if code == other.sonioxCode { return other }
        return nil
    }
}

/// How Translate picks its pair: home language ⇄ the active situation's local
/// language, unless you picked one by hand.
nonisolated enum PairChoice {
    /// The languages offered in the picker: every `LangCode` row, plus the
    /// situation's language if it has no row.
    static func options(situationLanguage: String?) -> [PairLanguage] {
        var options = LangCode.allCases.map(PairLanguage.init)
        if let tag = situationLanguage, let extra = PairLanguage(tag: tag),
           !options.contains(where: { $0.tag == extra.tag }) {
            options.append(extra)
        }
        return options
    }

    /// The pair to use.
    /// - Parameters:
    ///   - homeTag: the profile's home language.
    ///   - situationLanguage: the active situation's `localLanguage`, if any.
    ///   - manualHome, manualOther: tags picked by hand, which win.
    /// - Returns: nil when there's no other language, or it's the same as yours.
    static func resolve(
        homeTag: String,
        situationLanguage: String?,
        manualHome: String? = nil,
        manualOther: String? = nil
    ) -> TranslatePair? {
        let home = PairLanguage(tag: manualHome ?? homeTag) ?? PairLanguage(.en)
        guard let otherTag = manualOther ?? situationLanguage,
              let other = PairLanguage(tag: otherTag) else { return nil }
        let pair = TranslatePair(home: home, other: other)
        return pair.isUsable ? pair : nil
    }
}
