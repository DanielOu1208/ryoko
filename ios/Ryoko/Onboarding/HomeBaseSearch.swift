import CoreLocation
import MapKit
import Observation
import os

/// Finds the home base (design §4.1 page 7, §4.6): `MKLocalSearchCompleter`
/// suggestions while typing, resolved to a map item when one is picked.
@MainActor
@Observable
final class HomeBaseSearch {
    /// The search field's text. Each change asks the completer for suggestions.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            let fragment = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if fragment.isEmpty {
                completer.cancel()
                suggestions = []
                hasNoResults = false
            } else {
                completer.queryFragment = fragment
            }
        }
    }

    /// Whether the search field is active.
    var isPresented = false

    private(set) var suggestions: [MKLocalSearchCompletion] = []
    /// The completer found nothing for the current text.
    private(set) var hasNoResults = false
    /// A suggestion is being turned into a home base.
    private(set) var isResolving = false
    /// The last problem, in words. nil when fine.
    private(set) var failure: String?

    /// True while there's text to show suggestions for.
    var isSearching: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private let relay = HomeBaseCompleterRelay()

    init() {
        completer.resultTypes = [.pointOfInterest, .address]
        relay.onUpdate = { [weak self] in
            guard let self else { return }
            suggestions = completer.results
            hasNoResults = completer.results.isEmpty
        }
        relay.onEmpty = { [weak self] in
            self?.suggestions = []
            self?.hasNoResults = true
        }
        relay.onError = { error in
            RyokoLog.onboarding.error("Home base suggestions failed: \(String(describing: error), privacy: .public)")
        }
        completer.delegate = relay
    }

    /// The home base for a picked suggestion, or nil (with `failure` set).
    func homeBase(for completion: MKLocalSearchCompletion, homeLanguage: String) async -> HomeBase? {
        isResolving = true
        failure = nil
        defer { isResolving = false }
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.pointOfInterest, .address]
        do {
            guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
                failure = "Couldn't find that place. Try another search."
                return nil
            }
            return await HomeBaseLocalizer.homeBase(from: item, homeLanguage: homeLanguage)
        } catch {
            RyokoLog.onboarding.error("Couldn't open a home base suggestion: \(String(describing: error), privacy: .public)")
            failure = "Couldn't find that place. Check your connection and try again."
            return nil
        }
    }

    /// Ends the search: clears the text and closes the field.
    func finish() {
        text = ""
        isPresented = false
    }
}

/// The completer's delegate. MapKit calls it on the main thread.
private final class HomeBaseCompleterRelay: NSObject, MKLocalSearchCompleterDelegate {
    var onUpdate: (() -> Void)?
    var onEmpty: (() -> Void)?
    var onError: ((any Error) -> Void)?

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { onUpdate?() }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            // No results is reported as an error; it isn't one.
            if (error as? MKError)?.code == .placemarkNotFound {
                onEmpty?()
            } else {
                onError?(error)
            }
        }
    }
}

/// Turns a map item or a spot on the map into a `HomeBase`, with the local
/// name and address the taxi card needs (design §4.6). No model is involved:
///
/// - `localName` is the map item's name when it's already in the local script
///   (MapKit names follow the app's language, so often it isn't, and the taxi
///   card falls back to the address).
/// - `addressLocal` comes from `MKReverseGeocodingRequest` with the local
///   language's `preferredLocale`, kept only when it's in the local script.
/// - Both stay empty where the local language is your own.
enum HomeBaseLocalizer {
    static func homeBase(from item: MKMapItem, homeLanguage: String) async -> HomeBase? {
        let coordinate = item.location.coordinate
        let address = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            ?? item.address?.fullAddress
        guard let name = item.name ?? item.address?.shortAddress ?? address else { return nil }
        var home = HomeBase(
            name: name,
            localName: nil,
            address: address,
            addressLocal: nil,
            coordinate: Coordinate(lat: coordinate.latitude, lon: coordinate.longitude)
        )
        await localize(&home, from: item, homeLanguage: homeLanguage)
        return home
    }

    /// The home base for a spot picked on the map: reverse geocoded in the
    /// device's language for its name and address.
    static func homeBase(at coordinate: CLLocationCoordinate2D, homeLanguage: String) async -> HomeBase? {
        guard let item = await reverseGeocode(coordinate, locale: nil) else {
            // Keep the spot even without an address.
            return HomeBase(
                name: "Pinned place",
                localName: nil,
                address: nil,
                addressLocal: nil,
                coordinate: Coordinate(lat: coordinate.latitude, lon: coordinate.longitude)
            )
        }
        var home = await homeBase(from: item, homeLanguage: homeLanguage)
        // The pin, not the geocoder's snapped point, is where the traveller stays.
        home?.coordinate = Coordinate(lat: coordinate.latitude, lon: coordinate.longitude)
        return home
    }

    private static func localize(_ home: inout HomeBase, from item: MKMapItem, homeLanguage: String) async {
        guard let region = item.addressRepresentations?.region?.identifier else { return }
        let local = LocalLanguage.forRegion(region)
        guard !sameLanguage(local.tag, homeLanguage) else { return }
        if ScriptMatch.matches(home.name, language: local.tag, fromMapKit: true) {
            home.localName = home.name
        }
        // A place's own address is the most precise; MapKit often gives it in
        // local script already (Tokyo hotels come back as 東京都新宿区…).
        if isCJK(local), let own = localAddress(of: item, in: local) {
            home.addressLocal = own
            return
        }
        let locale = local.langCode?.locale ?? Locale(identifier: local.tag)
        let location = CLLocationCoordinate2D(latitude: home.coordinate.lat, longitude: home.coordinate.lon)
        guard let geocoded = await reverseGeocode(location, locale: locale) else { return }
        home.addressLocal = localAddress(of: geocoded, in: local)
    }

    private static func isCJK(_ language: LocalLanguage) -> Bool {
        [LangCode.zhHans, .zhHant, .ja].contains(language.langCode)
    }

    /// The item's address as one line in the local way, or nil when it isn't
    /// in the local script. MapKit's single line joins parts with ", " even in
    /// Japanese, so CJK lines are joined without separators (`joinedCJK`).
    private static func localAddress(of item: MKMapItem, in local: LocalLanguage) -> String? {
        let line = isCJK(local)
            ? item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: false).map(TaxiCardFactory.joinedCJK)
            : item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
        guard let line = (line ?? item.address?.fullAddress)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty, ScriptMatch.matches(line, language: local.tag) else { return nil }
        return line
    }

    /// Same language for the taxi card's purposes: the same `LangCode` row, or
    /// the same primary subtag for languages without one.
    private static func sameLanguage(_ a: String, _ b: String) -> Bool {
        if let rowA = LangCode(tag: a), let rowB = LangCode(tag: b) { return rowA == rowB }
        return a.split(separator: "-").first?.lowercased() == b.split(separator: "-").first?.lowercased()
    }

    /// The first map item `MKReverseGeocodingRequest` returns. `locale` nil
    /// means the device's language.
    private static func reverseGeocode(_ coordinate: CLLocationCoordinate2D, locale: Locale?) async -> MKMapItem? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        if let locale { request.preferredLocale = locale }
        do {
            return try await request.mapItems.first
        } catch let error as MKError where error.code == .placemarkNotFound {
            return nil
        } catch {
            RyokoLog.onboarding.error("Home base geocoding failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
