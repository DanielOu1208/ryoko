import SwiftUI
import UIKit

/// What Show mode displays (design §4.4). Show mode takes one of these, never raw
/// strings. W3 builds the Show mode views and the allergy and taxi cards.
enum ShowContent: Identifiable, Hashable {
    /// From Now, place sheets and Mimo's phrase blocks.
    case phrase(Phrase)
    /// A scrollable stack: each line in local script with your language below,
    /// and the severity always in words.
    case allergy(AllergyShowCard)
    /// The local name, the address, the fixed phrase and a map snapshot.
    case taxi(TaxiShowCard)

    var id: String {
        switch self {
        case let .phrase(phrase): "phrase-\(phrase.id)"
        case let .allergy(card): "allergy-\(card.language)-" + card.lines.map(\.id).joined(separator: ",")
        case let .taxi(card): "taxi-\(card.language)-\(card.name)"
        }
    }

    /// BCP-47 tag of the local text.
    var language: String {
        switch self {
        case let .phrase(phrase): phrase.lang
        case let .allergy(card): card.language
        case let .taxi(card): card.language
        }
    }
}

/// An allergy card ready to show, from the bundled templates (chip allergens)
/// or from `POST /v1/allergy-card` (free text).
struct AllergyShowCard: Hashable {
    struct Line: Hashable, Identifiable {
        var id: String
        var allergenId: AllergenId
        /// The full line in local script.
        var local: String
        /// The same line in the home language.
        var home: String
        var severity: Severity
        /// The severity in local script, from the templates' `severityLabels`.
        var severityLocal: String?
    }

    var language: String
    var titleLocal: String
    var titleHome: String?
    var lines: [Line]
    /// "Does this dish contain any of these?" in local script.
    var requestLocal: String
    var requestHome: String
    var requestRomanization: String?
    /// False for free-text cards, and for templates no native reader has checked
    /// yet. Show "Not reviewed" when false.
    var reviewed: Bool
}

extension AllergyShowCard {
    /// A free-text card from the server. Always unreviewed.
    init(_ response: AllergyCardResponse) {
        self.init(
            language: response.language,
            titleLocal: response.title,
            titleHome: nil,
            lines: response.items.enumerated().map { index, item in
                Line(
                    id: "\(item.allergenId.rawValue)-\(index)",
                    allergenId: item.allergenId,
                    local: item.local,
                    home: item.home,
                    severity: item.severity,
                    severityLocal: nil
                )
            },
            requestLocal: response.requestLocal,
            requestHome: response.requestHome,
            requestRomanization: response.romanization,
            reviewed: response.reviewed
        )
    }
}

/// A taxi card ready to show (design §4.6). No model is involved.
struct TaxiShowCard: Hashable {
    var language: String
    /// The place's name in local script.
    var name: String
    /// The address in local script, from `MKReverseGeocodingRequest`.
    var address: String
    /// The fixed phrase, e.g. 请带我去这里 ("Please take me here").
    var phrase: Phrase
    var coordinate: Coordinate?
    /// The `MKMapSnapshotter` image, with its attribution left visible.
    var snapshot: UIImage?
}

nonisolated extension Severity {
    /// The severity in words, in English (the home language for now).
    var displayName: String {
        switch self {
        case .mild: "Mild"
        case .serious: "Serious"
        case .lifeThreatening: "Life-threatening"
        }
    }
}
