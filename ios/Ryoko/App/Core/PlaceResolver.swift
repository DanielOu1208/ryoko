import Foundation
import os

/// A name to find on the map: from Mimo's `show_places`, `discover`, or a place card.
nonisolated struct PlaceQuery: Hashable, Sendable {
    var name: String
    /// Local-script name; tried first in China (design §4.7).
    var localName: String?
    /// A category to fall back to, and to tag the result with.
    var category: CategorySlug?
    /// The centre of the search region, normally the active situation's place.
    var near: Coordinate
    /// The search region's radius. Results are still capped at 5 km.
    var radiusMeters: Double = 3_000
}

/// A name the resolver found.
nonisolated struct ResolvedPlace: Hashable, Sendable, Identifiable {
    var query: PlaceQuery
    /// `id` is the `MKMapItem.Identifier` raw value when MapKit has one.
    var place: Place
    var distanceMeters: Double

    var id: String {
        place.id ?? "\(place.name)@\(String(format: "%.4f,%.4f", place.coordinate.lat, place.coordinate.lon))"
    }
}

/// Turns names into MapKit places (design §4.7, W4.4). Mimo names places; the
/// device locates them. The real resolver uses `MKLocalSearch` with
/// `regionPriority .required`, a 5 km cap, a cache and a throttle.
@MainActor
protocol PlaceResolver: AnyObject {
    /// The nearest match within 5 km, or nil. Misses are dropped silently,
    /// so this doesn't throw.
    func resolve(_ query: PlaceQuery) async -> ResolvedPlace?
}

extension PlaceResolver {
    /// Resolves names one at a time (MapKit throttles at about 50 a minute),
    /// keeping their order and dropping misses.
    func resolveAll(_ queries: [PlaceQuery]) async -> [ResolvedPlace] {
        var resolved: [ResolvedPlace] = []
        for query in queries {
            if Task.isCancelled { break }
            if let place = await resolve(query) {
                resolved.append(place)
            }
        }
        return resolved
    }
}

/// Resolves every name to a made-up spot near the query's centre, for previews
/// and fixture mode. The coordinates are fake on purpose: each name lands at a
/// stable offset of 150–950 m, so pins spread out. Names in `misses` aren't found.
@MainActor
final class FixturePlaceResolver: PlaceResolver {
    var misses: Set<String>
    var latency: Duration

    init(misses: Set<String> = [], latency: Duration = .milliseconds(120)) {
        self.misses = misses
        self.latency = latency
    }

    func resolve(_ query: PlaceQuery) async -> ResolvedPlace? {
        try? await Task.sleep(for: latency)
        guard !misses.contains(query.name) else {
            RyokoLog.places.info("Fixture resolver: no match for \(query.name, privacy: .public)")
            return nil
        }
        // A stable hash of the name, so the same name always lands in the same spot.
        let seed = query.name.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        let bearing = Double(seed % 360) * .pi / 180
        let distance = 150 + Double(seed / 360 % 800)
        let metersPerDegree = 111_320.0
        let coordinate = Coordinate(
            lat: query.near.lat + distance * cos(bearing) / metersPerDegree,
            lon: query.near.lon + distance * sin(bearing) / (metersPerDegree * cos(query.near.lat * .pi / 180))
        )
        let place = Place(
            id: "fixture-\(seed)",
            name: query.name,
            localName: query.localName,
            category: query.category ?? .other,
            address: nil,
            coordinate: coordinate
        )
        return ResolvedPlace(query: query, place: place, distanceMeters: distance)
    }
}
