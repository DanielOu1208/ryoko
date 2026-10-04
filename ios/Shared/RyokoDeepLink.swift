import Foundation

/// Ryoko's `ryoko://` links (design §4.11). The Live Activity's `widgetURL`
/// builds one; the app's `onOpenURL` parses it, on a cold start too.
///
/// - `ryoko://show?phrase=<id>`: Show mode for that phrase, which the app
///   kept when it put the phrase on the activity.
/// - `ryoko://map`: the Map with the current place's card (an activity with
///   no phrase yet). `ryoko://nearby`, from activities started before the
///   Nearby tab was merged into the Map, opens the same.
nonisolated enum RyokoDeepLink: Hashable, Sendable {
    case show(phraseID: String)
    case currentPlace

    static let scheme = "ryoko"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case let .show(phraseID):
            components.host = "show"
            components.queryItems = [URLQueryItem(name: "phrase", value: phraseID)]
        case .currentPlace:
            components.host = "map"
        }
        return components.url ?? URL(string: "ryoko://map")!
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme else { return nil }
        switch components.host?.lowercased() {
        case "show":
            guard let id = components.queryItems?.first(where: { $0.name == "phrase" })?.value,
                  !id.isEmpty else { return nil }
            self = .show(phraseID: id)
        case "map", "nearby":
            self = .currentPlace
        default:
            return nil
        }
    }

    /// The link for an activity: its phrase in Show mode, or the current
    /// place's card until there is one.
    init(phrase: ActivityPhrase?) {
        self = phrase.map { .show(phraseID: $0.id) } ?? .currentPlace
    }
}
