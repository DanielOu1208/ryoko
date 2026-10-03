#if DEBUG
import SwiftUI

/// DEBUG launch arguments for Nearby's states (W3). Use with
/// `-RyokoInitialTab nearby`; Show mode's are in `ShowDebugOptions`.
///
/// - `-RyokoSamplePlace shanghai|vancouver`: preview the Shanghai café fixture
///   at 3 PM, or a Vancouver market (the local language is your own: no phrase
///   cards, "Preview a place").
/// - `-RyokoNearbyFailure offline|server`: Nearby's API calls fail like that, to
///   show the error state, or the saved card marked offline when one exists.
/// - `-RyokoNearbyLatency <seconds>`: answer from fixtures that slowly, to see
///   the `.redacted` loading state.
enum NearbyDebugOptions {
    /// `-RyokoShow` runs once per launch, not again after Done.
    static var didRunShowHook = false

    nonisolated static var samplePlace: String? {
        UserDefaults.standard.string(forKey: "RyokoSamplePlace")
    }

    nonisolated static var failure: RyokoAPIError? {
        switch UserDefaults.standard.string(forKey: "RyokoNearbyFailure") {
        case "offline":
            .transport(.notConnectedToInternet)
        case "server":
            .server(status: 500, ErrorBody(code: .modelError, message: "Mimo couldn't write this card.", retryable: true))
        default:
            nil
        }
    }

    nonisolated static var latency: Duration? {
        let seconds = UserDefaults.standard.double(forKey: "RyokoNearbyLatency")
        return seconds > 0 ? .seconds(seconds) : nil
    }

    /// Starts the `-RyokoSamplePlace` preview, once.
    static func applySamplePlace(to store: AppSituationStore) {
        guard !didApplySample, let sample = samplePlace else { return }
        didApplySample = true
        switch sample {
        case "shanghai":
            guard let place = Fixtures.shanghai?.place, let zone = TimeZone(identifier: "Asia/Shanghai") else { return }
            store.startPreview(SituationPreview(
                place: place,
                date: SamplePlaces.next(hour: 15, in: zone),
                timeZone: zone,
                city: "Shanghai",
                district: "Jing'an",
                countryCode: "CN"
            ))
        case "vancouver":
            guard let zone = TimeZone(identifier: "America/Vancouver") else { return }
            store.startPreview(SituationPreview(
                place: Place(
                    id: nil,
                    name: "Granville Island Public Market",
                    localName: nil,
                    category: .shopping,
                    address: "1669 Johnston Street, Vancouver, BC",
                    coordinate: Coordinate(lat: 49.2727, lon: -123.1349)
                ),
                date: SamplePlaces.next(hour: 11, in: zone),
                timeZone: zone,
                city: "Vancouver",
                district: "Granville Island",
                countryCode: "CA"
            ))
        default:
            break
        }
    }

    private static var didApplySample = false

    /// Logs whether the bundled allergy templates are complete (`AllergyTemplates.selfCheck()`).
    static func runTemplateCheckOnce() {
        guard !didCheckTemplates else { return }
        didCheckTemplates = true
        AllergyTemplates.selfCheck()
    }

    private static var didCheckTemplates = false
}

/// Swaps Nearby's API for a failing or slow fixture when asked to at launch.
struct NearbyDebugAPIOverride: ViewModifier {
    func body(content: Content) -> some View {
        if let failure = NearbyDebugOptions.failure {
            content.environment(\.ryokoAPI, FixtureRyokoAPI(failure: failure))
        } else if let latency = NearbyDebugOptions.latency {
            content.environment(\.ryokoAPI, FixtureRyokoAPI(latency: latency))
        } else {
            content
        }
    }
}
#endif
