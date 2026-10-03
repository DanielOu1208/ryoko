import CoreLocation
import Foundation
import MapKit

/// Where a coordinate is: city, district, country and time zone, from MapKit's
/// address representations (iOS 26; `placemark` is deprecated).
nonisolated struct PlaceArea: Hashable, Sendable {
    var city: String
    var district: String?
    /// ISO 3166-1 alpha-2, uppercased.
    var countryCode: String
    /// State or province when MapKit names one (`QC`, `CA`), for language overrides.
    var subdivision: String?
    var timeZone: TimeZone?
}

/// A place near you that you can confirm (design §4.2).
nonisolated struct NearbyCandidate: Hashable, Sendable, Identifiable {
    var place: Place
    var distanceMeters: Double
    /// `MKMapItem.timeZone`.
    var timeZone: TimeZone?
    /// The place's own city and country, when its map item has them.
    var area: PlaceArea?

    var id: String {
        place.id ?? "\(place.name)@\(String(format: "%.5f,%.5f", place.coordinate.lat, place.coordinate.lon))"
    }
}

/// MapKit lookups for live mode: points of interest around you, and reverse
/// geocoding for the city. MapKit's own region rules apply: a POI request is a
/// fixed circle, so results never leak outside it (unlike a `.default`-priority
/// text search, which D1 saw return Canadian results for Shanghai).
enum NearbySearch {
    /// How far to look for places to confirm (design §4.2: 100–150 m; POIs are
    /// sparse in Shanghai at 50 m).
    static let radiusMeters: CLLocationDistance = 150
    /// How many places to offer.
    static let candidateLimit = 3

    /// The nearest points of interest within `radius`, closest first. No results
    /// (`MKError.placemarkNotFound`) is an empty list, not an error.
    static func nearestPlaces(
        to location: CLLocation,
        radius: CLLocationDistance = radiusMeters,
        limit: Int = candidateLimit
    ) async throws -> [NearbyCandidate] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: radius)
        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        }
        var seen = Set<String>()
        return items
            .compactMap { item -> NearbyCandidate? in
                guard let place = place(from: item) else { return nil }
                return NearbyCandidate(
                    place: place,
                    distanceMeters: item.location.distance(from: location),
                    timeZone: item.timeZone,
                    area: item.addressRepresentations.flatMap { area(from: $0, timeZone: item.timeZone) }
                )
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map(\.self)
    }

    /// City, district, country and time zone for a coordinate, or nil when MapKit
    /// has nothing there.
    static func area(at location: CLLocation) async throws -> PlaceArea? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items: [MKMapItem]
        do {
            items = try await request.mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            return nil
        }
        for item in items {
            if let representations = item.addressRepresentations,
               let area = area(from: representations, timeZone: item.timeZone) {
                return area
            }
        }
        return nil
    }

    // MARK: - Mapping

    /// A contract `Place` for a map item, or nil when it has no name.
    static func place(from item: MKMapItem) -> Place? {
        guard let name = ContractText.clean(item.name, maxLength: 120) else { return nil }
        let countryCode = item.addressRepresentations?.region?.identifier.uppercased()
        let address = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            ?? item.address?.shortAddress
            ?? item.address?.fullAddress
        let coordinate = item.location.coordinate
        return Place(
            id: ContractText.clean(item.identifier?.rawValue, maxLength: 512),
            name: name,
            localName: localScriptName(name, countryCode: countryCode),
            category: PlaceCategoryMapping.slug(for: item.pointOfInterestCategory, name: name),
            address: ContractText.clean(address, maxLength: 240),
            coordinate: Coordinate(lat: coordinate.latitude, lon: coordinate.longitude)
        )
    }

    /// The map item's name doubles as the local-script name only when it's
    /// already in the local script (design §4.6). MapKit names follow the app's
    /// language (D1), so an English UI usually gets romanized names and the
    /// local name comes from the place card's `placeNameLocal` instead.
    static func localScriptName(_ name: String, countryCode: String?) -> String? {
        guard let countryCode else { return nil }
        let language = LocalLanguage.forRegion(countryCode).langCode
        let hasHan = name.unicodeScalars.contains { $0.properties.isIdeographic }
        let hasKana = name.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        switch language {
        case .zhHans, .zhHant: return hasHan ? name : nil
        case .ja: return hasHan || hasKana ? name : nil
        default: return nil
        }
    }

    /// City and district from MapKit's address representations.
    ///
    /// - Most places: `cityName` is the city.
    /// - Japan: `cityName` is the ward (`Shinjuku`) and the context is
    ///   `Shinjuku, Tokyo, Japan`, so the ward becomes the district and the
    ///   prefecture-level city the city.
    static func area(from representations: MKAddressRepresentations, timeZone: TimeZone?) -> PlaceArea? {
        guard let countryCode = representations.region?.identifier.uppercased(),
              countryCode.count == 2 else { return nil }
        let country = representations.regionName
        let context = (representations.cityWithContext(.full) ?? representations.cityWithContext ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != country }
        let cityName = ContractText.clean(representations.cityName, maxLength: 80) ?? context.first

        var city = cityName
        var district: String?
        if countryCode == "JP", let ward = cityName, let prefecture = context.last, prefecture != ward {
            city = prefecture
            district = ward
                .replacingOccurrences(of: "-Ku", with: "")
                .replacingOccurrences(of: "-ku", with: "")
                .replacingOccurrences(of: " City", with: "")
        }
        guard let city = ContractText.clean(city ?? timeZone.flatMap(cityFromTimeZone), maxLength: 80) else {
            return nil
        }
        return PlaceArea(
            city: city,
            district: ContractText.clean(district, maxLength: 80),
            countryCode: countryCode,
            subdivision: context.count > 1 ? context[1] : nil,
            timeZone: timeZone
        )
    }

    /// `Asia/Tokyo` → `Tokyo`, `America/Los_Angeles` → `Los Angeles`.
    static func cityFromTimeZone(_ zone: TimeZone) -> String? {
        guard let last = zone.identifier.split(separator: "/").last, zone.identifier.contains("/") else { return nil }
        return last.replacingOccurrences(of: "_", with: " ")
    }
}

/// Contract string limits (contracts/src/situation.ts): trimmed, non-empty and
/// within `maxLength`, or nil.
nonisolated enum ContractText {
    static func clean(_ text: String?, maxLength: Int) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) : trimmed
    }
}

/// MapKit point-of-interest categories → the contract's category slugs. MapKit
/// has no ramen, tea, convenience-store or temple categories, so a few name
/// patterns fill those in.
nonisolated enum PlaceCategoryMapping {
    static func slug(for category: MKPointOfInterestCategory?, name: String) -> CategorySlug {
        let lowered = name.lowercased()
        func nameHas(_ needles: [String]) -> Bool { needles.contains { lowered.contains($0) } }
        let isTea = nameHas(["tea", "茶"])

        // Names that MapKit files under broader categories.
        if nameHas(["ramen", "ラーメン", "らーめん", "らぁ麺", "拉面", "拉麵", "麺屋"]) { return .ramen }
        if nameHas(["7-eleven", "seven-eleven", "familymart", "family mart", "lawson", "ministop",
                    "セブン-イレブン", "ファミリーマート", "ローソン", "全家", "罗森", "羅森", "便利店"]) {
            return .convenienceStore
        }

        switch category {
        case .cafe?: return isTea ? .tea : .cafe
        case .restaurant?: return .restaurant
        case .bakery?: return .bakery
        case .nightlife?, .brewery?, .winery?, .distillery?: return .bar
        case .museum?, .planetarium?, .aquarium?: return .museum
        case .park?, .nationalPark?, .beach?, .zoo?: return .park
        case .publicTransport?, .airport?: return .transit
        case .hotel?: return .hotel
        case .store?, .pharmacy?, .foodMarket?: return .shopping
        default:
            // No category, or one Ryoko doesn't distinguish (landmark, …).
            if nameHas(["temple", "shrine", "神社", "寺", "庙", "廟"]) { return .templeShrine }
            return isTea ? .tea : .other
        }
    }
}
