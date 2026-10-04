import Foundation

/// Ryoko's `ryoko://` links (design §4.11). The Live Activity's `widgetURL`
/// builds one; the app's `onOpenURL` parses it, on a cold start too.
///
/// - `ryoko://show?phrase=<id>`: Show mode for that phrase, which the app
///   kept when it put the phrase on the activity.
/// - `ryoko://nearby`: the Nearby tab (an activity with no phrase yet).
nonisolated enum RyokoDeepLink: Hashable, Sendable {
    case show(phraseID: String)
    case nearby

    static let scheme = "ryoko"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case let .show(phraseID):
            components.host = "show"
            components.queryItems = [URLQueryItem(name: "phrase", value: phraseID)]
        case .nearby:
            components.host = "nearby"
        }
        return components.url ?? URL(string: "ryoko://nearby")!
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme else { return nil }
        switch components.host?.lowercased() {
        case "show":
            guard let id = components.queryItems?.first(where: { $0.name == "phrase" })?.value,
                  !id.isEmpty else { return nil }
            self = .show(phraseID: id)
        case "nearby":
            self = .nearby
        default:
            return nil
        }
    }

    /// The link for an activity: its phrase in Show mode, or Nearby until there is one.
    init(phrase: ActivityPhrase?) {
        self = phrase.map { .show(phraseID: $0.id) } ?? .nearby
    }
}
