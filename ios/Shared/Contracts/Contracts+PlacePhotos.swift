import Foundation

// Mirror of contracts/src/place-photos.ts. POST /v1/place-photos: a photo of
// each place for its thumbnail and the Map place card's header, from the
// Foursquare Places API. A place with no `url` has no photo (or the server has
// no Foursquare key), and the app falls back to Look Around.

nonisolated struct PlacePhotoQuery: Codable, Hashable, Sendable {
    /// The app's key for the place, echoed back. At most 120 characters.
    var key: String
    /// At most 120 characters.
    var name: String
    /// The local-script name, which may match instead of `name`.
    var localName: String?
    var coordinate: Coordinate
}

nonisolated struct PlacePhotosRequest: Codable, Hashable, Sendable {
    /// The server takes at most this many places per request.
    static let maxPlaces = 25

    /// 1–25 places.
    var places: [PlacePhotoQuery]
}

nonisolated struct PlacePhoto: Codable, Hashable, Sendable {
    var key: String
    /// An https url, or nil when there's no photo.
    var url: String?
    /// Pixels, when known.
    var width: Int?
    var height: Int?
}

nonisolated struct PlacePhotosResponse: Codable, Hashable, Sendable {
    /// One per distinct requested key, in request order.
    var photos: [PlacePhoto]
}
