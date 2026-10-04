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
        /// One place's card, in the same panel.
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
    var detent: MapSheetDetent = .medium
    /// Where closing a card goes: the list or results, at the size it had.
    @ObservationIgnored private var returnPanel: Panel = .list
    @ObservationIgnored private var returnDetent: MapSheetDetent = .medium
    /// A card opened by tapping the map: deselecting closes it.
    private(set) var detailsFromMap = false

    var details: MapPlace? {
        if case let .details(place) = panel { place } else { nil }
    }

    /// What the open card has learned about its place, for the card's header:
    /// its area (city, time zone) and its local-script name from the place card.
    var detailsArea: PlaceArea?
    var detailsLocalName: String?

    // MARK: Map

    var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    var selection: MapSelection<String>?
    var visibleRegion: MKCoordinateRegion?
    var layers = MapLayers()

    /// The map's safe area (between the search field and the resting list),
    /// in global coordinates: camera positions are framed in it. `MapView`
    /// keeps it up to date.
    @ObservationIgnored var mapSafeArea: CGRect?
    /// The map left visible above a card at its large size, in global
    /// coordinates. `MapView` keeps it up to date.
    @ObservationIgnored var cardStrip: CGRect?
    /// Your live location, to frame it with a card's place when it's close.
    @ObservationIgnored var userLocation: Coordinate?

    // MARK: Content

    private(set) var picks: PicksState = .idle
    private(set) var nearby: NearbyState = .idle
    private(set) var searchResults: [MapPlace] = []
    private(set) var droppedPin: MapPlace?
    /// Bumped by "Try again" on the picks.
    var picksAttempt = 0

    #if DEBUG
    /// A card button to press once, from `-RyokoMapCardAction`.
    var debugCardAction: String?
    #endif

    // MARK: Caches

    @ObservationIgnored private var picksCache: [PicksKey: [MapPlace]] = [:]
    @ObservationIgnored private var nearbyCache: [String: [MapPlace]] = [:]
    @ObservationIgnored private var cardCache: [CardKey: PlaceCardResponse] = [:]
    @ObservationIgnored private var areaCache: [String: PlaceArea] = [:]

    // MARK: - Mimo picks

    /// Mirrors the server's `discover` cache key (design §7.5: area, hour
    /// bucket, profile version), so confirming a place nearby doesn't reload.
    /// The real places sent with the request (`nearby`) come from the same
    /// ~100 m area, so the key covers them too.
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

    /// Loads `discover` for the key's area, grounded in the real places MapKit
    /// knows around it (`MapDiscoverNearby`), and resolves each name, one at a
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
        do {
            let nearbyPlaces = await MapDiscoverNearby.places(around: key.center)
            try Task.checkCancellation()
            #if DEBUG
            RyokoLog.places.info("Discover: sending \(nearbyPlaces.count) nearby places")
            #endif
            let request = DiscoverRequest(
                area: key.area,
                profile: profile,
                situation: situation,
                nearby: nearbyPlaces.isEmpty ? nil : nearbyPlaces
            )
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
                // The row shows MapKit's name, not Mimo's, so it names the
                // place a tap opens even if the two ever differ.
                let place = MapPlace(
                    place: resolved.place,
                    source: .pick(why: pick.why, bestTime: pick.bestTime),
                    distanceMeters: resolved.distanceMeters
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

    // MARK: - Cards

    /// Opens `place`'s card in the panel (design §4.7): almost full height,
    /// with the map gliding so the place sits, highlighted, in the strip of
    /// map above it. Nothing about the situation changes.
    func showDetails(_ place: MapPlace, fromMap: Bool) {
        if details == nil {
            returnPanel = panel
            returnDetent = detent
        }
        if details?.id != place.id {
            detailsArea = place.area
            detailsLocalName = nil
        }
        panel = .details(place)
        detailsFromMap = fromMap
        detent = .large
        if !fromMap, let tag = markerTag(for: place) {
            selection = MapSelection(tag)
        }
        focusCard(on: place.place.coordinate)
    }

    /// Replaces the place on the card with a fuller version of the same place
    /// (a map item arriving after a tap).
    func refineDetails(_ place: MapPlace, replacing placeholder: MapPlace) {
        guard details == placeholder else { return }
        if detailsArea == nil { detailsArea = place.area }
        panel = .details(place)
    }

    /// Closes the card (back to the list or results at the size they had),
    /// or the results (back to the list). The map stays where it is.
    func back() {
        switch panel {
        case .details:
            panel = returnPanel
            detent = returnDetent
        case .results:
            panel = .list
            searchResults = []
            detent = .medium
        case .list:
            return
        }
        detailsFromMap = false
        detailsArea = nil
        detailsLocalName = nil
        selection = nil
        droppedPin = nil
        if case .list = panel { searchResults = [] }
    }

    /// The tag of the marker that shows `place` on the map, so its card can
    /// highlight it. Tapped map features are highlighted by MapKit itself.
    func markerTag(for place: MapPlace) -> String? {
        switch place.source {
        case .feature: nil
        case .pick: layers.hiddenGems ? MapMarkerTag.gem.tag(place.id) : MapMarkerTag.focus.tag(place.id)
        case .search: MapMarkerTag.search.tag(place.id)
        case .droppedPin: MapMarkerTag.pin.tag(place.id)
        case .fromMimo: layers.fromMimo ? MapMarkerTag.mimo.tag(place.id) : MapMarkerTag.focus.tag(place.id)
        case .nearby, .focus: MapMarkerTag.focus.tag(place.id)
        }
    }

    // MARK: - Search

    /// Shows search results in the panel, or the place's card when there's one.
    func showResults(_ places: [MapPlace], for query: String) {
        searchResults = places
        droppedPin = nil
        if places.count == 1, let only = places.first {
            returnPanel = .list
            returnDetent = .medium
            showDetails(only, fromMap: false)
            return
        }
        panel = .results(query: query)
        detent = .medium
        fit(places.map(\.place.coordinate))
    }

    // MARK: - Dropped pin

    /// A long-press: a pin at `coordinate` (from `MapProxy`, so MapKit's own
    /// coordinate) and its card. The address arrives with reverse geocoding.
    func dropPin(at coordinate: Coordinate, origin: Coordinate?) async {
        let placeholder = MapPlace(
            place: Place(id: nil, name: "Dropped pin", localName: nil, category: .other, address: nil, coordinate: coordinate),
            source: .droppedPin,
            distanceMeters: origin.map { coordinate.mapDistance(to: $0) },
            displayName: "Dropped pin"
        )
        droppedPin = placeholder
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

    /// About 600 m across the screen: street level for a card.
    static let cardMetersPerPoint = 1.5
    /// How far out a card zooms to fit your location too (about 2 km across).
    static let cardMaxMetersPerPoint = 5.0
    /// Your location is framed with a card's place within this distance.
    static let cardFrameUserRadius: CLLocationDistance = 1_000
    /// A marker's balloon sits above its point: aim the point this far below
    /// the strip's middle, so the pin looks centred.
    static let markerLift: CGFloat = 22

    /// Glides the camera, north up, so `coordinate` sits in the middle of the
    /// strip of map above a card (`cardStrip`), at street level. Your location
    /// is framed too when it's within 1 km and still fits.
    ///
    /// The map's safe area (`mapSafeArea`) doesn't follow the panel, so the
    /// camera's centre stays at its middle: the region is centred off the
    /// place by however far the strip's middle is from there, and sized to
    /// the safe area so MapKit frames it exactly.
    func focusCard(on coordinate: Coordinate) {
        guard let safeArea = mapSafeArea, let strip = cardStrip,
              safeArea.width > 0, safeArea.height > 0 else {
            focus(on: coordinate, meters: 700)
            return
        }
        let target = CGPoint(x: strip.midX, y: strip.midY + Self.markerLift)
        var metersPerPoint = Self.cardMetersPerPoint
        if let user = userLocation, user.mapDistance(to: coordinate) <= Self.cardFrameUserRadius {
            let offset = coordinate.mapVector(to: user)
            let margin: CGFloat = 28
            let halfWidth = max(min(target.x - strip.minX, strip.maxX - target.x) - margin, 1)
            let above = max(target.y - strip.minY - margin, 1)
            let below = max(strip.maxY - target.y - margin, 1)
            let needed = max(
                abs(offset.east) / Double(halfWidth),
                offset.north > 0 ? offset.north / Double(above) : -offset.north / Double(below)
            )
            if needed <= Self.cardMaxMetersPerPoint {
                metersPerPoint = max(metersPerPoint, needed)
            }
        }

        // The place must appear at `target`; the camera's centre is the safe
        // area's middle. Work out the centre that puts the place there.
        let east = Double(target.x - safeArea.midX) * metersPerPoint
        let north = Double(safeArea.midY - target.y) * metersPerPoint
        let center = coordinate.mapOffset(east: -east, north: -north)
        let region = MKCoordinateRegion(
            center: center.mapKitCoordinate,
            latitudinalMeters: Double(safeArea.height) * metersPerPoint,
            longitudinalMeters: Double(safeArea.width) * metersPerPoint
        )
        withAnimation(.smooth(duration: 0.6)) {
            camera = .region(region)
        }
    }

    /// Centres on `coordinate`, in the map above the resting list.
    func focus(on coordinate: Coordinate, meters: CLLocationDistance = 700) {
        withAnimation(.smooth) {
            camera = .region(MKCoordinateRegion(around: coordinate, meters: meters))
        }
    }

    /// Fits a set of coordinates, with some margin, above the resting list.
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
        let padX = max(rect.size.width * 0.2, 300)
        let padY = max(rect.size.height * 0.2, 300)
        rect = rect.insetBy(dx: -padX, dy: -padY)
        withAnimation(.smooth) {
            camera = .rect(rect)
        }
    }
}
