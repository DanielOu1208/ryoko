#if DEBUG
import os
import SwiftUI
import UIKit

/// DEBUG launch arguments for driving the Map from the command line (there's
/// no tap automation). Combine with the app's own, e.g.:
///
///     xcrun simctl launch booted com.danielou.ryoko -RyokoAPIMode fixture \
///       -RyokoMapDetent medium -RyokoMapLayers gems
///
/// - `-RyokoMapDetent small|medium|large`: the panel's starting size.
/// - `-RyokoMapDetails <name>`: once you're located, resolve the name with the
///   shared resolver and open its card (through `router.openMap(selecting:)`).
/// - `-RyokoMapCard here|pick|nearby`: open the current place's card (as the
///   header's tap does), the first Mimo pick's, or the first nearby place's,
///   once there is one.
/// - `-RyokoMapCardAction preview|taxi|allergy|phrase|here|mimo|directions|close`:
///   press that button on the card once it has loaded. (`-RyokoMapDetailsAction`
///   is the old name; `-RyokoShow phrase|allergy|taxi` means
///   `-RyokoMapCard here -RyokoMapCardAction <kind>`.)
/// - `-RyokoMapCardFailure offline|server`: the card's place-card request
///   fails like that (the error state, or the saved card when there is one).
/// - `-RyokoMapCardLatency <seconds>`: the card's place card answers from
///   fixtures that slowly, to see the `.redacted` loading state.
/// - `-RyokoMapDropPin <lat>,<lon>`: as if long-pressed there.
/// - `-RyokoMapLayers food,washrooms,gems,mimo`: layers to turn on.
/// - `-RyokoMapFromMimo 1`: put a sample three-stop plan (Shinjuku names) on
///   the From Mimo layer, as Mimo's "Show on map" would.
/// - `-RyokoMapSearch <text>`: open search with this text (suggestions).
/// - `-RyokoMapOpenLayers 1`: open the layers menu, for screenshots.
/// - `-RyokoMapResolverCheck "<name>|<name>|…"`: resolve each name near you and
///   log the result (category `places`). An entry can be
///   `<name>;<localName>;<category slug>`, as discover sends them.
enum MapDebugOptions {
    private static var defaults: UserDefaults { .standard }

    static var detent: MapSheetDetent? {
        switch defaults.string(forKey: "RyokoMapDetent") {
        case "small": .small
        case "medium": .medium
        case "large": .large
        default: nil
        }
    }

    static var detailsName: String? { defaults.string(forKey: "RyokoMapDetails") }

    /// `-RyokoMapCard`, or `here` for `-RyokoShow`.
    static var card: String? {
        defaults.string(forKey: "RyokoMapCard") ?? (ShowDebugOptions.showAtLaunch != nil ? "here" : nil)
    }

    static var cardAction: String? {
        defaults.string(forKey: "RyokoMapCardAction")
            ?? defaults.string(forKey: "RyokoMapDetailsAction")
            ?? ShowDebugOptions.showAtLaunch?.rawValue
    }

    static var cardFailure: RyokoAPIError? {
        switch defaults.string(forKey: "RyokoMapCardFailure") {
        case "offline":
            .transport(.notConnectedToInternet)
        case "server":
            .server(status: 500, ErrorBody(code: .modelError, message: "Mimo couldn't write this card.", retryable: true))
        default:
            nil
        }
    }

    static var cardLatency: Duration? {
        let seconds = defaults.double(forKey: "RyokoMapCardLatency")
        return seconds > 0 ? .seconds(seconds) : nil
    }

    static var dropPin: Coordinate? {
        guard let text = defaults.string(forKey: "RyokoMapDropPin") else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 2 ? Coordinate(lat: parts[0], lon: parts[1]) : nil
    }

    static var layers: Set<String> {
        Set((defaults.string(forKey: "RyokoMapLayers") ?? "").split(separator: ",").map(String.init))
    }

    static var fromMimoSample: Bool { defaults.bool(forKey: "RyokoMapFromMimo") }
    static var searchText: String? { defaults.string(forKey: "RyokoMapSearch") }
    static var opensLayers: Bool { defaults.bool(forKey: "RyokoMapOpenLayers") }

    static var resolverCheck: [String] {
        (defaults.string(forKey: "RyokoMapResolverCheck") ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A sample plan in Shinjuku, named the way Mimo's `show_places` names places.
    static let samplePlan: [ShownPlace] = [
        ShownPlace(name: "Fuunji", localName: "風雲児", why: "Tsukemen before the evening line", order: 1, when: "18:00"),
        ShownPlace(name: "Omoide Yokocho", localName: "思い出横丁", why: "Yakitori at a tiny counter", order: 2, when: "19:30"),
        ShownPlace(name: "Shinjuku Golden Gai", localName: "新宿ゴールデン街", why: "One small bar to finish", order: 3, when: "21:00"),
    ]

    /// Opens the menu nearest the trailing edge (the Layers menu) as a tap
    /// would, for screenshots. DEBUG only: there's no tap automation, and
    /// SwiftUI exposes no way to open a `Menu` from code. Tries the control's
    /// accessibility activation, then its context-menu interaction. Returns
    /// which worked, or nil when there's no such button.
    @discardableResult
    static func openTrailingBarMenu() -> String? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            guard let button = trailingBarMenuButton(in: window, windowWidth: window.bounds.width),
                  let interaction = button.interactions.compactMap({ $0 as? UIContextMenuInteraction }).first
            else { continue }
            if button.accessibilityActivate() { return "accessibility activation" }
            let selector = NSSelectorFromString("_presentMenuAtLocation:")
            guard interaction.responds(to: selector) else { return nil }
            typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let present = unsafeBitCast(interaction.method(for: selector), to: Present.self)
            present(interaction, selector, CGPoint(x: button.bounds.midX, y: button.bounds.midY))
            return "context-menu interaction"
        }
        return nil
    }

    /// Logs whether the bundled allergy templates are complete, once.
    static func runTemplateCheckOnce() {
        guard !didCheckTemplates else { return }
        didCheckTemplates = true
        AllergyTemplates.selfCheck()
    }

    private static var didCheckTemplates = false

    /// The first view with a menu in the trailing half of the window.
    private static func trailingBarMenuButton(in view: UIView, windowWidth: CGFloat) -> UIView? {
        let hasMenu = view.interactions.contains { $0 is UIContextMenuInteraction }
        if hasMenu, view.convert(view.bounds, to: nil).minX > windowWidth / 2 {
            return view
        }
        for subview in view.subviews {
            if let found = trailingBarMenuButton(in: subview, windowWidth: windowWidth) { return found }
        }
        return nil
    }
}

/// Swaps the place card's API for a failing or slow fixture when asked to at
/// launch (`-RyokoMapCardFailure`, `-RyokoMapCardLatency`).
struct MapCardDebugAPIOverride: ViewModifier {
    func body(content: Content) -> some View {
        if let failure = MapDebugOptions.cardFailure {
            content.environment(\.ryokoAPI, FixtureRyokoAPI(failure: failure))
        } else if let latency = MapDebugOptions.cardLatency {
            content.environment(\.ryokoAPI, FixtureRyokoAPI(latency: latency))
        } else {
            content
        }
    }
}
#endif
