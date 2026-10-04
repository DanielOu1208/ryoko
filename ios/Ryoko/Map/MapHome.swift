import CoreLocation
import MapKit
import SwiftUI

/// The Map tab (design §4.7, W4): the home screen. The pieces:
///
/// - `MapView`: the tab root. Map, search, layers, long-press, and the bottom
///   panel. Applies `router.mapFocus`.
/// - `MapHomeModel`: what the Map shows (panel mode, picks, nearby places,
///   search results, pins) and the caches behind it.
/// - `MapSheetPanel`: the Apple Maps-style bottom panel with three snap points.
///   It's a panel inside the tab, not a `.sheet`: a native sheet covers the tab
///   bar inside `TabView` (checked on the iOS 27 simulator).
/// - `MapPlaceList` (Mimo picks, then nearest places) and `MapPlaceDetails`
///   (phrases, tips, Preview, Taxi card, Ask Mimo, Make this my place).
/// - `LivePlaceResolver`: the app's one MapKit `PlaceResolver`.
///
/// Every coordinate on the Map comes from MapKit (design §4.7): MapKit search,
/// points of interest, map features, or a long-press converted by `MapProxy`.
enum MapHome {
    /// How far the nearest-places list looks (the POI request's circle).
    static let nearbyRadius: CLLocationDistance = 500
    /// How many nearest places the list shows.
    static let nearbyLimit = 25
    /// The `discover` area (design §7.5: the app sends 1500).
    static let discoverRadius = 1_500
    /// How far Mimo's names are looked for (the resolver clamps to 1.5–3 km).
    static let resolveRadius: Double = 3_000

    /// Where the list is centred: the previewed place, otherwise your last fix
    /// (or the confirmed place). Stable while you confirm places around you.
    static func listAnchor(_ store: AppSituationStore) -> Coordinate? {
        if let preview = store.previewSituation { return preview.place?.coordinate }
        return store.lastFix ?? store.liveSituation?.place?.coordinate
    }
}

// MARK: - A place on the Map

/// A place the Map can list, pin, open in details, or make current: a contract
/// `Place` plus what MapKit knows about it.
struct MapPlace: Identifiable, Hashable {
    /// Where the Map got it from.
    enum Source: Hashable {
        /// A Mimo pick (`discover`), with its one-line why.
        case pick(why: String, bestTime: String?)
        /// The nearest-places list.
        case nearby
        /// A search suggestion or result.
        case search
        /// A tapped point of interest on the map.
        case feature
        /// A long-press.
        case droppedPin
        /// The From Mimo layer.
        case fromMimo(ShownPlace)
        /// Another tab asked the Map to show it (`router.openMap(selecting:)`).
        case focus
    }

    var place: Place
    var source: Source
    /// `MKMapItem.timeZone`, when MapKit gave one.
    var timeZone: TimeZone?
    /// City, district and country, when MapKit gave them.
    var area: PlaceArea?
    /// From the list's centre (your fix, or the previewed place).
    var distanceMeters: Double?
    /// The name to show, when it differs from MapKit's (Mimo's name for a From
    /// Mimo pin, "Dropped pin"). Picks show MapKit's name.
    var displayName: String?

    var id: String { Self.key(for: place) }
    var title: String { displayName ?? place.name }
    var coordinate: CLLocationCoordinate2D { place.coordinate.mapKitCoordinate }

    /// Mimo's one-line why, for picks and From Mimo pins.
    var why: String? {
        switch source {
        case let .pick(why, _): why
        case let .fromMimo(shown): shown.why
        default: nil
        }
    }

    /// The identifier when MapKit has one, otherwise the name and the
    /// coordinate rounded to 4 decimals (design §4.7).
    static func key(for place: Place) -> String {
        place.id ?? "\(place.name)@\(String(format: "%.4f,%.4f", place.coordinate.lat, place.coordinate.lon))"
    }
}

extension MapPlace {
    /// A place from a MapKit map item, or nil when it has no name.
    init?(item: MKMapItem, source: Source, from origin: CLLocation? = nil, name fallbackName: String? = nil) {
        var place = NearbySearch.place(from: item)
        if place == nil, let fallbackName {
            let coordinate = item.location.coordinate
            place = Place(
                id: nil,
                name: fallbackName,
                localName: nil,
                category: .other,
                address: ContractText.clean(
                    item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true),
                    maxLength: 240
                ),
                coordinate: Coordinate(lat: coordinate.latitude, lon: coordinate.longitude)
            )
        }
        guard let place else { return nil }
        self.init(
            place: place,
            source: source,
            timeZone: item.timeZone,
            area: item.addressRepresentations.flatMap { NearbySearch.area(from: $0, timeZone: item.timeZone) },
            distanceMeters: origin.map { item.location.distance(from: $0) }
        )
    }
}

// MARK: - Panel detents

/// The bottom panel's three snap points (Apple Maps style).
enum MapSheetDetent: Int, CaseIterable, Comparable {
    /// About three rows.
    case small
    /// About half the screen.
    case medium
    /// Nearly all of it, leaving the search field visible.
    case large

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var next: MapSheetDetent { MapSheetDetent(rawValue: rawValue + 1) ?? .large }
    var previous: MapSheetDetent { MapSheetDetent(rawValue: rawValue - 1) ?? .small }
}

// MARK: - Layers

/// The layer toggles (design §4.7).
struct MapLayers: Hashable {
    /// MapStyle filter: restaurants, cafés, bakeries, bars and food markets only.
    var foodAndDrink = false
    /// MapStyle filter: restrooms only.
    var washrooms = false
    /// Mimo's `discover` picks as pins.
    var hiddenGems = false
    /// Places and plans sent from the Mimo tab.
    var fromMimo = true

    static let foodAndDrinkCategories: [MKPointOfInterestCategory] = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .distillery, .nightlife, .foodMarket,
    ]

    /// Every POI, or only the filtered categories when a filter layer is on.
    var pointsOfInterest: PointOfInterestCategories {
        var categories: [MKPointOfInterestCategory] = []
        if foodAndDrink { categories += Self.foodAndDrinkCategories }
        if washrooms { categories.append(.restroom) }
        return categories.isEmpty ? .all : .including(categories)
    }

    var mapStyle: MapStyle {
        .standard(pointsOfInterest: pointsOfInterest)
    }
}

// MARK: - Helpers

// Names are prefixed `mapKit`/`map` so they can't collide with helpers other
// workstreams add to the same shared types.
extension Coordinate {
    var mapKitCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var mapKitLocation: CLLocation { CLLocation(latitude: lat, longitude: lon) }

    init(mapKit coordinate: CLLocationCoordinate2D) {
        self.init(lat: coordinate.latitude, lon: coordinate.longitude)
    }

    /// Metres to another coordinate.
    func mapDistance(to other: Coordinate) -> CLLocationDistance {
        mapKitLocation.distance(from: other.mapKitLocation)
    }
}

extension MKCoordinateRegion {
    /// A square region of `meters` across, centred on `center`.
    init(around center: Coordinate, meters: CLLocationDistance) {
        self.init(center: center.mapKitCoordinate, latitudinalMeters: meters, longitudinalMeters: meters)
    }
}

/// "350 m", "1.2 km": short distances for list rows.
enum MapDistanceText {
    static func text(_ meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        if meters < 1_000 {
            return Measurement(value: (meters / 10).rounded() * 10, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        return measurement.converted(to: .kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }
}

extension Situation {
    /// Where the Map's list is centred: the previewed place, the confirmed live
    /// place, or nil (live mode then uses the last fix).
    var mapAnchor: Coordinate? { place?.coordinate }

    /// "Shinjuku, Tokyo".
    var mapAreaText: String {
        [district, city].compactMap(\.self).joined(separator: ", ")
    }

    /// "Sun 7:00 PM" in the situation's time zone, with the time and its AM/PM
    /// glued by a no-break space.
    func mapClockText(at date: Date? = nil) -> String? {
        guard let instant = date ?? self.date, let zone else { return nil }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = zone
        var timeOnly = Date.FormatStyle.dateTime.hour().minute()
        timeOnly.timeZone = zone
        let time = instant.formatted(timeOnly)
        return instant.formatted(style).replacingOccurrences(of: time, with: time.replacing(/\s/, with: "\u{00A0}"))
    }
}
