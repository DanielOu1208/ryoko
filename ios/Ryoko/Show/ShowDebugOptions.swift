#if DEBUG
import Foundation

/// DEBUG launch arguments for Show mode and the cards (W3), alongside the
/// shell's `DebugLaunchOptions`. There's no tap automation, so screens are
/// driven from the command line:
///
///     xcrun simctl launch <udid> com.danielou.ryoko \
///       -RyokoAPIMode fixture -RyokoSamplePreview 19 -RyokoInitialTab nearby \
///       -RyokoShow taxi
///
/// - `-RyokoShow phrase|allergy|taxi`: once Nearby's card has loaded, open Show
///   mode with its first phrase, the allergy card or the taxi card (the quick
///   cards' own code path).
/// - `-RyokoShowFlipped 1`: Show mode opens flipped.
/// - `-RyokoShowAutoClose <seconds>`: Show mode closes itself after that long,
///   the way Done does (to check brightness and the idle timer are restored).
/// - `-RyokoExtraAllergy kiwi:serious`: add a free-text allergy to the allergy
///   card (not to the saved profile), to exercise `POST /v1/allergy-card`.
/// - `-RyokoMeShowAllergy zh-Hans|ja`: Me's allergy row opens the card at launch.
/// - `-RyokoTaxiTarget home`: the taxi quick card targets the home base even
///   when there's a place.
/// - Nearby's own: see `NearbyDebugOptions`.
nonisolated enum ShowDebugOptions {
    enum Kind: String {
        case phrase, allergy, taxi
    }

    static var showAtLaunch: Kind? {
        UserDefaults.standard.string(forKey: "RyokoShow").flatMap(Kind.init(rawValue:))
    }

    static var startsFlipped: Bool {
        UserDefaults.standard.bool(forKey: "RyokoShowFlipped")
    }

    static var autoCloseAfter: Duration? {
        let seconds = UserDefaults.standard.double(forKey: "RyokoShowAutoClose")
        return seconds > 0 ? .seconds(seconds) : nil
    }

    static var extraAllergy: Allergy? {
        guard let raw = UserDefaults.standard.string(forKey: "RyokoExtraAllergy") else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard let label = parts.first, !label.isEmpty else { return nil }
        let severity = parts.count > 1 ? Severity(rawValue: parts[1]) ?? .serious : .serious
        return Allergy(id: .custom, label: label, severity: severity)
    }

    static var meAllergyLanguage: String? {
        UserDefaults.standard.string(forKey: "RyokoMeShowAllergy")
    }

    static var taxiTargetsHome: Bool {
        UserDefaults.standard.string(forKey: "RyokoTaxiTarget") == "home"
    }
}
#endif
