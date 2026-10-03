import Foundation
import os

/// The hand-written allergy and taxi text from `contracts/tables/allergy-templates.json`
/// (design §4.5, §4.6), bundled through `Core/Fixtures/` by `ios/scripts/sync-fixtures.sh`.
/// It works offline and never calls a model.
///
/// Every language block carries `reviewed`. Until a native reader has checked it,
/// it's false and the card says "Not reviewed".
nonisolated struct AllergyTemplates: Decodable, Sendable {
    /// One line in the local language with the same line in the home language.
    struct Text: Decodable, Hashable, Sendable {
        var local: String
        var home: String
    }

    /// One chip allergen's wording at each severity.
    struct Allergen: Decodable, Sendable {
        /// The allergen's name in local script.
        var name: String
        /// The allergen's name in the home language, lowercase ("peanuts").
        var nameHome: String
        var mild: Text
        var serious: Text
        var lifeThreatening: Text

        private enum CodingKeys: String, CodingKey {
            case name, nameHome, mild, serious
            case lifeThreatening = "life_threatening"
        }

        func text(for severity: Severity) -> Text {
            switch severity {
            case .mild: mild
            case .serious: serious
            case .lifeThreatening: lifeThreatening
            }
        }
    }

    /// Everything for one local language.
    struct Language: Decodable, Sendable {
        var reviewed: Bool
        var reviewedBy: String?
        var title: Text
        /// "Does this dish contain any of these?"
        var request: Text
        var requestRomanization: String?
        /// Keyed by `Severity.rawValue`.
        var severityLabels: [String: Text]
        /// Keyed by `AllergenId.rawValue` (chip allergens only).
        var allergens: [String: Allergen]

        func allergen(_ id: AllergenId) -> Allergen? { allergens[id.rawValue] }
        func severityLabel(_ severity: Severity) -> Text? { severityLabels[severity.rawValue] }
    }

    /// The taxi card's fixed phrase ("Please take me here").
    struct TaxiPhrase: Decodable, Sendable {
        var local: String
        var romanization: String?
        var gloss: String
        var reviewed: Bool
    }

    /// The language the `home` lines are written in.
    var homeLanguage: String
    /// Keyed by BCP-47 tag (`zh-Hans`, `ja`).
    var languages: [String: Language]
    var taxiPhrases: [String: TaxiPhrase]

    /// The bundled table, read once. Nil (and logged) only if the file is missing
    /// or doesn't decode, which `selfCheck()` catches in DEBUG.
    static let bundled: AllergyTemplates? = {
        do {
            return try load()
        } catch {
            RyokoLog.show.fault("allergy-templates.json didn't load: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    static let fileName = "allergy-templates"

    static func load(bundle: Bundle = .main) throws -> AllergyTemplates {
        guard let url = bundle.url(forResource: fileName, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(AllergyTemplates.self, from: Data(contentsOf: url))
    }

    /// The templates for a local language, matched leniently (`ja-JP` → `ja`).
    func language(for tag: String) -> (tag: String, templates: Language)? {
        if let exact = languages[tag] { return (tag, exact) }
        if let row = LangCode(tag: tag), let match = languages[row.tag] { return (row.tag, match) }
        return nil
    }

    /// The fixed taxi phrase for a local language, matched leniently.
    func taxiPhrase(for tag: String) -> (tag: String, phrase: TaxiPhrase)? {
        if let exact = taxiPhrases[tag] { return (tag, exact) }
        if let row = LangCode(tag: tag), let match = taxiPhrases[row.tag] { return (row.tag, match) }
        return nil
    }

    #if DEBUG
    /// DEBUG: every language has a title, a request, all three severity labels and
    /// every chip allergen. Logs one line; returns the problems found.
    @discardableResult
    static func selfCheck() -> [String] {
        guard let table = bundled else {
            RyokoLog.show.fault("Allergy templates self-check FAILED: the table didn't load")
            return ["the table didn't load"]
        }
        var problems: [String] = []
        for (tag, language) in table.languages.sorted(by: { $0.key < $1.key }) {
            for severity in Severity.allCases where language.severityLabel(severity) == nil {
                problems.append("\(tag): no severity label for \(severity.rawValue)")
            }
            for id in AllergenId.chips where language.allergen(id) == nil {
                problems.append("\(tag): no template for \(id.rawValue)")
            }
            if table.taxiPhrase(for: tag) == nil {
                problems.append("\(tag): no taxi phrase")
            }
        }
        if problems.isEmpty {
            let languages = table.languages.keys.sorted().joined(separator: ", ")
            RyokoLog.show.notice("Allergy templates self-check passed: \(languages, privacy: .public), \(AllergenId.chips.count) allergens each")
        } else {
            RyokoLog.show.fault("Allergy templates self-check FAILED: \(problems.joined(separator: "; "), privacy: .public)")
        }
        return problems
    }
    #endif
}

extension RyokoLog {
    /// Show mode, the allergy card and the taxi card.
    nonisolated static let show = Logger(subsystem: subsystem, category: "show")
}
