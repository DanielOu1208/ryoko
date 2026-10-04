import SwiftUI

/// The seven survey pages (design §4.1), in order. Every page can be skipped;
/// a skipped page is stored as `null` (design §7.2). Me edits the profile one
/// page at a time with the same forms.
nonisolated enum SurveyPage: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case origin = 1
    case languages
    case diet
    case allergies
    case usual
    case thisOrThat
    case homeBase

    var id: Int { rawValue }

    /// "3 of 7", the large title's subtitle.
    var progress: String { "\(rawValue) of \(Self.allCases.count)" }

    var isLast: Bool { self == Self.allCases.last }

    var next: SurveyPage? { SurveyPage(rawValue: rawValue + 1) }

    /// The survey page's large title.
    var title: String {
        switch self {
        case .origin: "Where you're from"
        case .languages: "Languages you speak"
        case .diet: "What you don't eat"
        case .allergies: "Allergies"
        case .usual: "Your usual"
        case .thisOrThat: "This or that"
        case .homeBase: "Where you're staying"
        }
    }

    /// A title that fits the navigation bar at accessibility text sizes, where
    /// large titles don't wrap.
    var shortTitle: String {
        switch self {
        case .origin: "About you"
        case .languages: "Languages"
        case .diet: "Diet"
        case .allergies: "Allergies"
        case .usual: "Your usual"
        case .thisOrThat: "This or that"
        case .homeBase: "Home base"
        }
    }

    /// `title`, or `shortTitle` at accessibility text sizes.
    func title(for size: DynamicTypeSize) -> String {
        size.isAccessibilitySize ? shortTitle : title
    }

    /// The row label in Me's profile section.
    var meLabel: String {
        switch self {
        case .origin: "From"
        case .languages: "Speaks"
        case .diet: "Diet"
        case .allergies: "Allergies"
        case .usual: "Your usual"
        case .thisOrThat: "This or that"
        case .homeBase: "Home base"
        }
    }

    /// One line on what the answer changes, so personalization stays visible
    /// (design §1, §5).
    var explanation: String {
        switch self {
        case .origin:
            "Tips compare local customs with the ones at home, and Mimo writes to you in your language."
        case .languages:
            "Where people speak one of these, Ryoko doesn't need to hand you phrases."
        case .diet:
            "Mimo never suggests these, in phrases, picks or plans."
        case .allergies:
            "Never suggested, and your allergy card says how serious each one is in the local language."
        case .usual:
            "Phrases ask for it your way, like less sugar. The middle of each slider means as usual."
        case .thisOrThat:
            "These shape Mimo's picks and plans. Tap a card again to clear it."
        case .homeBase:
            "Optional. The taxi card takes you back here."
        }
    }
}
