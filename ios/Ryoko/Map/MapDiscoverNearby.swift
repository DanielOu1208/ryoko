import CoreLocation
import Foundation
import os

/// The real places sent with `discover` (design §6.5, decision #54), so Mimo
/// picks from what's actually around instead of from memory: MapKit points of
/// interest around the discover centre, nearest first, at most 40.
///
/// The POI request is a fixed 1.5 km circle, widened to 3 km when it finds
/// fewer than 12 places (quiet suburbs). Categories map through
/// `PlaceCategoryMapping`, as everywhere else. The list is optional: when
/// MapKit has nothing or fails, `discover` goes without it.
enum MapDiscoverNearby {
    static let radius: CLLocationDistance = 1_500
    static let widerRadius: CLLocationDistance = 3_000
    /// Fewer than this within `radius` widens the search.
    static let enough = 12
    /// The contract's cap (`DiscoverRequest.nearby`, at most 40).
    static let limit = 40

    static func places(around center: Coordinate) async -> [NearbyPlace] {
        let location = center.mapKitLocation
        do {
            var found = try await NearbySearch.nearestPlaces(to: location, radius: radius, limit: limit)
            if found.count < enough {
                let wider = try await NearbySearch.nearestPlaces(to: location, radius: widerRadius, limit: limit)
                if wider.count > found.count { found = wider }
            }
            return found.map { candidate in
                NearbyPlace(
                    name: candidate.place.name,
                    localName: candidate.place.localName,
                    category: candidate.place.category,
                    distanceMeters: min(50_000, max(0, Int(candidate.distanceMeters.rounded())))
                )
            }
        } catch is CancellationError {
            return []
        } catch {
            RyokoLog.places.info("No nearby places for discover: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
