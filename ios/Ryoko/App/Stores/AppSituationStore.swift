import CoreLocation
import Foundation
import Observation
import os

/// The app's real `SituationStore` (design §4.2, §7.1, W2.3). Everything follows
/// its `situation`, live or previewed: the Now card, Mimo picks, Translate's
/// pair, Mimo's context and the gradient.
///
/// **Live:** `refresh()` gets one location fix (when-in-use), reverse-geocodes
/// it for the city, and lists the nearest points of interest within 150 m
/// (closest first, at most three). Until you confirm one, the situation is
/// city-only (`place == nil`). Indoor GPS is fuzzy, so there's no automatic pick.
///
/// **Preview:** `startPreview(_:)` sets a place, a date and its time zone. It
/// overrides live mode until `endPreview()` ("Back to here").
///
/// The local language is always worked out on the device (`LocalLanguage`).
/// `localTime` carries the place's UTC offset, so the server never uses its clock.
@MainActor
@Observable
final class AppSituationStore: SituationStore {
    /// Where live mode is.
    enum LiveState: Equatable {
        /// Not started. `refresh()` starts it.
        case idle
        /// Waiting for permission or a location fix.
        case locating
        /// Looking for places nearby.
        case searching
        /// Done: `candidates` lists what's nearby (possibly nothing).
        case ready
        /// Location is off for Ryoko.
        case denied
        /// No fix, or MapKit failed. The message is safe to show.
        case failed(String)

        var isBusy: Bool { self == .locating || self == .searching }
    }

    // MARK: State

    /// The active situation: the preview if there is one, otherwise live.
    var situation: Situation? { previewSituation ?? liveSituation }

    /// Live mode's situation: city-only until a place is confirmed.
    private(set) var liveSituation: Situation?
    /// The look-ahead preview, if one is active.
    private(set) var previewSituation: Situation?

    private(set) var liveState: LiveState = .idle
    /// The nearest places, closest first (at most three).
    private(set) var candidates: [NearbyCandidate] = []
    /// The place you confirmed in live mode.
    private(set) var confirmedPlace: Place?
    /// Where the last fix was, and what MapKit says about it.
    private(set) var lastFix: Coordinate?
    private(set) var liveArea: PlaceArea?

    /// The local language of the live and previewed situations, with the
    /// speech-support flag (false in Hong Kong).
    private(set) var liveLanguage: LocalLanguage?
    private(set) var previewLanguage: LocalLanguage?

    /// `SituationStore`: the places to confirm.
    var nearbyCandidates: [Place] { candidates.map(\.place) }

    /// The active situation's language details.
    var language: LocalLanguage? { previewSituation != nil ? previewLanguage : liveLanguage }

    /// When-in-use permission, refreshed whenever live mode runs.
    private(set) var authorization: CLAuthorizationStatus

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private let usesLocation: Bool

    /// - Parameter usesLocation: false for previews and tests: `refresh()` then
    ///   does nothing, and no permission is asked for.
    init(usesLocation: Bool = true) {
        self.usesLocation = usesLocation
        authorization = usesLocation ? LocationFix.authorization : .notDetermined
    }

    /// A store already showing `situation`, for SwiftUI previews.
    static func preview(_ situation: Situation? = Fixtures.tokyo) -> AppSituationStore {
        let store = AppSituationStore(usesLocation: false)
        if let situation {
            let language = LocalLanguage.forRegion(situation.countryCode)
            if situation.mode == .preview {
                store.previewSituation = situation
                store.previewLanguage = language
            } else {
                store.liveSituation = situation
                store.liveLanguage = language
                store.confirmedPlace = situation.place
                store.candidates = situation.place.map {
                    [NearbyCandidate(place: $0, distanceMeters: 20, timeZone: situation.zone, area: nil)]
                } ?? []
                store.liveState = .ready
            }
        }
        return store
    }

    // MARK: Live

    /// Whether live mode can start without showing the permission prompt.
    var isLocationAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Starts live mode if permission was already given (no prompt). Call it
    /// when Now appears and when the app becomes active (location may have
    /// been turned on in Settings); use `refresh()` from a button to ask.
    func startLiveIfAuthorized() {
        guard usesLocation, liveState == .idle || liveState == .denied else { return }
        authorization = LocationFix.authorization
        if isLocationAuthorized { refresh() }
    }

    /// Re-checks where you are: a fresh fix, the city, and nearby places. Keeps
    /// the confirmed place unless you've moved away from it. Updates the live
    /// clock too.
    func refresh() {
        guard usesLocation else { return }
        liveTask?.cancel()
        liveTask = Task { await runLive() }
    }

    private func runLive() async {
        liveState = .locating
        let location: CLLocation
        do {
            location = try await LocationFix.current()
        } catch LocationFix.Failure.denied {
            authorization = LocationFix.authorization
            liveState = .denied
            return
        } catch is CancellationError {
            return
        } catch {
            liveState = .failed("Can't find where you are right now.")
            RyokoLog.situation.error("No location fix: \(String(describing: error), privacy: .public)")
            return
        }
        authorization = LocationFix.authorization
        if Task.isCancelled { return }

        let fix = Coordinate(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        lastFix = fix
        liveState = .searching

        // The city and the places nearby, together.
        async let areaLookup = NearbySearch.area(at: location)
        async let placesLookup = NearbySearch.nearestPlaces(to: location)
        let area = try? await areaLookup
        let places: [NearbyCandidate]
        do {
            places = try await placesLookup
        } catch is CancellationError {
            return
        } catch {
            RyokoLog.situation.error("POI search failed: \(String(describing: error), privacy: .public)")
            places = []
            if area == nil {
                liveState = .failed("Can't look up places nearby right now.")
                return
            }
        }
        if Task.isCancelled { return }

        liveArea = area ?? places.first?.area
        candidates = places
        // Keep the confirmed place unless you've moved more than 300 m from it.
        if let confirmed = confirmedPlace,
           CLLocation(latitude: confirmed.coordinate.lat, longitude: confirmed.coordinate.lon).distance(from: location) > 300 {
            confirmedPlace = nil
        }
        rebuildLive()
        liveState = .ready
        RyokoLog.situation.info("Live: \(places.count) places within \(Int(NearbySearch.radiusMeters)) m")
    }

    /// `SituationStore`: confirms where you are (live mode).
    func confirm(_ place: Place) {
        confirmedPlace = place
        rebuildLive()
        RyokoLog.situation.info("Confirmed \(place.name, privacy: .public)")
    }

    /// Clears the confirmed place, back to city-only.
    func clearConfirmation() {
        confirmedPlace = nil
        rebuildLive()
    }

    /// Builds the live situation from the confirmed place (or city-only) at the
    /// current time.
    private func rebuildLive() {
        let candidate = confirmedPlace.flatMap { place in candidates.first { $0.place == place } }
        // The fix's reverse geocode names the city more reliably than a POI's own
        // address (in Tokyo a POI may give just its ward); they're within 150 m.
        let area = liveArea ?? candidate?.area
        guard let area else {
            // Nothing known about the city: no situation yet (design §4.3 "Where are you?").
            liveSituation = nil
            liveLanguage = nil
            return
        }
        let zone = candidate?.timeZone ?? area.timeZone ?? .current
        let language = LocalLanguage.forRegion(area.countryCode, subdivision: area.subdivision)
        liveLanguage = language
        liveSituation = Situation(
            mode: .live,
            date: .now,
            timeZone: zone,
            place: confirmedPlace,
            city: area.city,
            district: area.district,
            countryCode: area.countryCode,
            localLanguage: language.tag
        )
    }

    // MARK: Preview

    /// `SituationStore`: previews a place at a chosen time.
    func startPreview(_ preview: SituationPreview) {
        startPreview(preview, subdivision: nil)
    }

    /// Previews a place at a chosen time. `subdivision` (state or province) is
    /// only needed for language overrides such as Quebec → `fr`; without it,
    /// the place's address is checked.
    func startPreview(_ preview: SituationPreview, subdivision: String?) {
        let countryCode = preview.countryCode.uppercased()
        let language = LocalLanguage.forRegion(
            countryCode,
            subdivision: subdivision ?? Self.quebecHint(in: preview.place.address)
        )
        previewLanguage = language
        previewSituation = Situation(
            mode: .preview,
            date: preview.date,
            timeZone: preview.timeZone,
            place: preview.place,
            city: ContractText.clean(preview.city, maxLength: 80)
                ?? NearbySearch.cityFromTimeZone(preview.timeZone) ?? preview.place.name,
            district: ContractText.clean(preview.district, maxLength: 80),
            countryCode: countryCode,
            localLanguage: language.tag
        )
        RyokoLog.situation.info("Previewing \(preview.place.name, privacy: .public) at \(self.previewSituation?.localTime ?? "?", privacy: .public)")
    }

    /// `SituationStore`: "Back to here". Live mode picks up where it was.
    func endPreview() {
        previewSituation = nil
        previewLanguage = nil
        if liveSituation != nil { rebuildLive() } // refresh the live clock
    }

    /// `QC` or `Québec` in an address, for previews that don't pass a subdivision.
    private static func quebecHint(in address: String?) -> String? {
        guard let address else { return nil }
        let parts = address.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        return parts.first(where: LocalLanguage.isQuebec)
    }
}
