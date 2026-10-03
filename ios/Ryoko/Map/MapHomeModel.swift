import MapKit
import Observation
import SwiftUI
import os

/// What the Map tab shows and remembers (design §4.7). `MapView` owns one in
/// `@State`, so it survives tab switches: Mimo picks, nearest places and place
/// cards aren't fetched again when you come back.
@MainActor
@Observable
final class MapHomeModel {
    /// What the bottom panel shows.
    enum Panel: Equatable {
        /// Mimo picks, then the nearest places.
        case list
        /// Places matching a submitted search.
        case results(query: String)
        /// One place's details, in the same panel.
        case details(MapPlace)
    }

    /// Mimo picks: `discover`, then each name through the shared resolver.
    enum PicksState: Equatable {
        /// No situation yet, so no area to ask about.
        case idle
        /// Resolved so far (empty while `discover` is still loading).
        case loading([MapPlace])
        case loaded([MapPlace])
        case failed(String)

        var places: [MapPlace] {
            switch self {
            case let .loading(places), let .loaded(places): places
            case .idle, .failed: []
            }
        }
    }

    enum NearbyState: Equatable {
        case idle
        case loading
        case loaded([MapPlace])
        case failed(String)

        var places: [MapPlace] {
            if case let .loaded(places) = self { places } else { [] }
        }
    }

    // MARK: Panel

    var panel: Panel = .list
    var detent: MapSheetDetent = .small
    /// Where Back goes from details.
    @ObservationIgnored private var returnPanel: Panel = .list
    @ObservationIgnored private var returnDetent: MapSheetDetent = .small
    /// Details opened by tapping the map: deselecting closes them.
    private(set) var detailsFromMap = false

    var details: MapPlace? {
        if case let .details(place) = panel { place } else { nil }
    }

    // MARK: Map

    var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    var selection: MapSelection<String>?
    var visibleRegion: MKCoordinateRegion?
    var layers = MapLayers()

    // MARK: Content

    private(set) var picks: PicksState = .idle
    private(set) var nearby: NearbyState = .idle
    private(set) var searchResults: [MapPlace] = []
    private(set) var droppedPin: MapPlace?
    /// Bumped by "Try again" on the picks.
    var picksAttempt = 0

    #if DEBUG
    /// A details button to press once, from `-RyokoMapDetailsAction`.
    var debugDetailsAction: String?
    #endif

    // MARK: Caches

    @ObservationIgnored private var picksCache: [PicksKey: [MapPlace]] = [:]
    @ObservationIgnored private var nearbyCache: [String: [MapPlace]] = [:]
    @ObservationIgnored private var cardCache: [CardKey: PlaceCardResponse] = [:]
    @ObservationIgnored private var areaCache: [String: PlaceArea] = [:]

    // MARK: - Mimo picks

    /// Mirrors the server's `discover` cache key (design §7.5: area, hour
    /// bucket, profile version), so confirming a place nearby doesn't reload.
    struct PicksKey: Hashable {
        var center: Coordinate
        var city: String
        var district: String?
        var hourBucket: String
        var localLanguage: String
        var profileVersion: String
        var apiGeneration: Int
        var attempt: Int

        var area: DiscoverArea {
            DiscoverArea(center: center, radiusMeters: MapHome.discoverRadius, city: city, district: district)
        }
    }

    /// Loads `discover` for the key's area and resolves each name, one at a
    /// time, showing them as they're found. Misses are dropped. `situation` is
    /// the active situation as of now (`currentSituation()`); `origin` is the
    /// unrounded list centre that names are found near and measured from.
    func loadPicks(
        _ key: PicksKey,
        origin: Coordinate,
        profile: Profile,
        situation: Situation,
        api: any RyokoAPI,
        resolver: any PlaceResolver
    ) async {
        if let cached = picksCache[key] {
            picks = .loaded(cached)
            return
        }
        picks = .loading([])
        let request = DiscoverRequest(area: key.area, profile: profile, situation: situation)
        do {
            let response = try await api.discover(request)
            var found: [MapPlace] = []
            for pick in response.places {
                try Task.checkCancellation()
                let query = PlaceQuery(
                    name: pick.name,
                    localName: pick.localName,
                    category: pick.category,
                    near: origin,
                    radiusMeters: MapHome.resolveRadius
                )
                guard let resolved = await resolver.resolve(query) else { continue }
                let place = MapPlace(
                    place: resolved.place,
                    source: .pick(why: pick.why, bestTime: pick.bestTime),
                    distanceMeters: resolved.distanceMeters,
                    displayName: pick.name
                )
                guard !found.contains(where: { $0.id == place.id }) else { continue }
                found.append(place)
                picks = .loading(found)
            }
            try Task.checkCancellation()
            picksCache[key] = found
            picks = .loaded(found)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            picks = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
        }
    }

    func clearPicks() {
        picks = .idle
    }

    // MARK: - Nearest places

    /// The nearest points of interest to `anchor`, closest first (design §4.7).
    /// The POI request is a fixed circle, so nothing leaks in from elsewhere.
    func loadNearby(around anchor: Coordinate) async {
        let key = String(format: "%.4f,%.4f", anchor.lat, anchor.lon)
        if let cached = nearbyCache[key] {
            nearby = .loaded(cached)
            return
        }
        nearby = .loading
        let origin = anchor.mapKitLocation
        let request = MKLocalPointsOfInterestRequest(center: origin.coordinate, radius: MapHome.nearbyRadius)
        do {
            let items: [MKMapItem]
            do {
                items = try await MKLocalSearch(request: request).start().mapItems
            } catch let error as MKError where error.code == .placemarkNotFound {
                items = []
            }
            var seen = Set<String>()
            let places = items
                .compactMap { MapPlace(item: $0, source: .nearby, from: origin) }
                .sorted { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }
                .filter { seen.insert($0.id).inserted }
                .prefix(MapHome.nearbyLimit)
            nearbyCache[key] = Array(places)
            nearby = .loaded(Array(places))
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            RyokoLog.places.error("Nearest places failed: \(String(describing: error), privacy: .public)")
            nearby = .failed("Can't look up places nearby right now.")
        }
    }

    func clearNearby() {
        nearby = .idle
    }

    // MARK: - Details

    /// Shows `place` in the panel (design §4.7: the same sheet, with Back).
    func showDetails(_ place: MapPlace, fromMap: Bool) {
        if details == nil {
            returnPanel = panel
            returnDetent = detent
        }
        panel = .details(place)
        detailsFromMap = fromMap
        if detent == .small { detent = .medium }
        focus(on: place.place.coordinate, meters: 700, liftForPanel: true)
    }

    /// Replaces the place in details with a fuller version of the same place
    /// (a map item arriving after a tap).
    func refineDetails(_ place: MapPlace, replacing placeholder: MapPlace) {
        guard details == placeholder else { return }
        panel = .details(place)
    }

    /// Back from details (or from search results) to where you were.
    func back() {
        switch panel {
        case .details:
            panel = returnPanel
            detent = returnDetent
        case .results:
            panel = .list
            searchResults = []
            detent = .small
        case .list:
            return
        }
        detailsFromMap = false
        selection = nil
        droppedPin = nil
        if case .list = panel { searchResults = [] }
    }

    // MARK: - Search

    /// Shows search results in the panel, or the place itself when there's one.
    func showResults(_ places: [MapPlace], for query: String) {
        searchResults = places
        droppedPin = nil
        if places.count == 1, let only = places.first {
            returnPanel = .list
            returnDetent = .small
            panel = .details(only)
            detailsFromMap = false
            detent = .medium
            focus(on: only.place.coordinate, meters: 700, liftForPanel: true)
            return
        }
        panel = .results(query: query)
        detent = .medium
        fit(places.map(\.place.coordinate))
    }

    // MARK: - Dropped pin

    /// A long-press: a pin at `coordinate` (from `MapProxy`, so MapKit's own
    /// coordinate) and its details. The address arrives with reverse geocoding.
    func dropPin(at coordinate: Coordinate, origin: Coordinate?) async {
        let placeholder = MapPlace(
            place: Place(id: nil, name: "Dropped pin", localName: nil, category: .other, address: nil, coordinate: coordinate),
            source: .droppedPin,
            distanceMeters: origin.map { coordinate.mapDistance(to: $0) },
            displayName: "Dropped pin"
        )
        droppedPin = placeholder
        selection = nil
        showDetails(placeholder, fromMap: false)

        guard let request = MKReverseGeocodingRequest(location: coordinate.mapKitLocation),
              let item = try? await request.mapItems.first else { return }
        var place = placeholder
        let address = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
        // The place card and taxi card need a name: the street address, when there is one.
        place.place.name = ContractText.clean(item.name ?? address, maxLength: 120) ?? "Dropped pin"
        place.place.address = ContractText.clean(address, maxLength: 240)
        place.timeZone = item.timeZone
        place.area = item.addressRepresentations.flatMap { NearbySearch.area(from: $0, timeZone: item.timeZone) }
        guard droppedPin == placeholder else { return }
        droppedPin = place
        refineDetails(place, replacing: placeholder)
    }

    // MARK: - Area

    /// City, district, country and time zone for a place: MapKit's, or the
    /// active situation's when the place is within 3 km of it, or a reverse
    /// geocode. Needed for a preview, a place card and the taxi card's language.
    func area(for place: MapPlace, situation: Situation?, anchor: Coordinate?) async -> PlaceArea? {
        if let area = place.area { return area }
        if let cached = areaCache[place.id] { return cached }
        if let situation, let anchor, anchor.mapDistance(to: place.place.coordinate) < 3_000 {
            return PlaceArea(
                city: situation.city,
                district: situation.district,
                countryCode: situation.countryCode,
                subdivision: nil,
                timeZone: situation.zone
            )
        }
        if let area = try? await NearbySearch.area(at: place.place.coordinate.mapKitLocation) {
            areaCache[place.id] = area
            return area
        }
        return nil
    }

    // MARK: - Place cards

    struct CardKey: Hashable {
        var place: String
        var hourBucket: String
        var mode: SituationMode
        var localLanguage: String
        var profileVersion: String
        var apiGeneration: Int
    }

    func cachedCard(_ key: CardKey) -> PlaceCardResponse? { cardCache[key] }

    func storeCard(_ card: PlaceCardResponse, for key: CardKey) {
        cardCache[key] = card
    }

    // MARK: - Camera

    /// Centres on `coordinate`. With `liftForPanel`, the point sits in the
    /// upper part of the map, above a medium panel.
    func focus(on coordinate: Coordinate, meters: CLLocationDistance = 700, liftForPanel: Bool = false) {
        var center = coordinate
        if liftForPanel {
            center.lat -= meters / 111_320 * 0.3
        }
        withAnimation(.smooth) {
            camera = .region(MKCoordinateRegion(around: center, meters: meters))
        }
    }

    /// Fits a set of coordinates, with some margin.
    func fit(_ coordinates: [Coordinate]) {
        guard let first = coordinates.first else { return }
        if coordinates.count == 1 {
            focus(on: first, meters: 900)
            return
        }
        let points = coordinates.map { MKMapPoint($0.mapKitCoordinate) }
        var rect = MKMapRect(origin: points[0], size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        let padX = max(rect.size.width * 0.3, 400)
        let padY = max(rect.size.height * 0.3, 400)
        // Extra room at the bottom for the panel.
        rect = MKMapRect(
            x: rect.origin.x - padX,
            y: rect.origin.y - padY,
            width: rect.size.width + padX * 2,
            height: rect.size.height + padY * 3
        )
        withAnimation(.smooth) {
            camera = .rect(rect)
        }
    }
}
