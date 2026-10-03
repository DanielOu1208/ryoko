import CoreLocation
import Foundation
import os

/// The MapKit points of interest attached to every Mimo message (design §4.9,
/// §7.7: "up to 20 nearby MapKit POIs"), so Mimo can talk about what's around.
/// They're optional: when MapKit has nothing or fails, messages go without them.
enum MimoNearby {
    /// Up to 20 places around `center`, nearest first.
    static func places(around center: Coordinate) async -> [NearbyPlace] {
        let location = CLLocation(latitude: center.lat, longitude: center.lon)
        do {
            let candidates = try await NearbySearch.nearestPlaces(
                to: location,
                radius: MimoFeature.nearbyRadiusMeters,
                limit: MimoFeature.nearbyLimit
            )
            return candidates.map { candidate in
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
            RyokoLog.mimo.info("No nearby places for Mimo: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
