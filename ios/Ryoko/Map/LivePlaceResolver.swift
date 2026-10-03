import CoreLocation
import Foundation
import MapKit
import os

/// The app's MapKit `PlaceResolver` (design §4.7, W4.4): turns the names Mimo
/// gives (picks, Hidden gems, `show_places`) into MapKit places. Mimo names
/// places; the device locates them, so every coordinate comes from MapKit.
///
/// For each name:
/// 1. Search with `MKLocalSearch`, always `regionPriority = .required`, in a
///    square region 3–6 km across (a radius of 1.5–3 km) around the query's
///    centre. `.default` returns places near the device instead (D1).
///    `placemarkNotFound` means no results.
/// 2. Search terms in order: in mainland China the local name, then the
///    English name; elsewhere the English name, then the local name; then a
///    category query (e.g. "ramen") whose results are filtered by name.
/// 3. Accept only hits within 5 km whose name is similar to the requested
///    name or local name (`PlaceNameMatch`), and take the nearest.
///
/// Answers, misses included, are cached by (normalized name, area). Places are
/// kept by `identifier.rawValue`, or normalized name plus the coordinate
/// rounded to 4 decimals when MapKit has no identifier (about 40% of Taipei
/// and Hong Kong POIs). Concurrent requests for the same name share one lookup.
///
/// MapKit allows about 50 requests a minute per app, so lookups go through a
/// sliding-window throttle of `requestsPerMinute`, and a `loadingThrottled`
/// error pauses lookups for a minute without caching a miss.
@MainActor
final class LivePlaceResolver: PlaceResolver {
    /// Hits further than this from the query's centre are dropped.
    static let maxDistance: CLLocationDistance = 5_000
    /// The search region's radius is clamped to this range.
    static let regionRadius: ClosedRange<Double> = 1_500...3_000
    /// MapKit requests this resolver makes per rolling minute. Under MapKit's
    /// ~50, leaving room for the Map's own searches.
    static let requestsPerMinute = 40

    private enum Outcome {
        case found(ResolvedPlace)
        case miss
        /// MapKit failed (network, throttle): don't cache.
        case failed
    }

    /// (normalized name | area) → place key, or nil for a miss.
    private var answers: [String: String?] = [:]
    /// Place key → the resolved place (distance as first found).
    private var places: [String: ResolvedPlace] = [:]
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    /// Area cell → ISO country code, or nil when reverse geocoding found nothing.
    private var countries: [String: String?] = [:]
    /// When each recent MapKit request started.
    private var requestLog: [ContinuousClock.Instant] = []
    /// After a `loadingThrottled` error: no requests before this.
    private var pausedUntil: ContinuousClock.Instant?

    init() {}

    func resolve(_ query: PlaceQuery) async -> ResolvedPlace? {
        let name = query.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let key = Self.answerKey(query)

        if let answer = answers[key] {
            return answer.flatMap { places[$0] }.map { relative($0, to: query) }
        }
        let task: Task<Outcome, Never>
        if let shared = inFlight[key] {
            task = shared
        } else {
            // Unstructured, so one caller giving up never cancels a lookup
            // another caller is waiting on.
            task = Task { await self.lookUp(query) }
            inFlight[key] = task
        }
        let outcome = await task.value
        inFlight[key] = nil

        switch outcome {
        case let .found(resolved):
            let placeKey = MapPlace.key(for: resolved.place)
            if places[placeKey] == nil { places[placeKey] = resolved }
            answers[key] = .some(placeKey)
            return relative(places[placeKey] ?? resolved, to: query)
        case .miss:
            answers[key] = .some(nil)
            return nil
        case .failed:
            return nil
        }
    }

    /// The cached place, re-measured from this query's centre and tagged with it.
    private func relative(_ resolved: ResolvedPlace, to query: PlaceQuery) -> ResolvedPlace {
        var copy = resolved
        copy.query = query
        copy.distanceMeters = resolved.place.coordinate.mapDistance(to: query.near)
        // Mimo's category is usually finer than MapKit's (ramen vs restaurant).
        if let category = query.category, category != .other { copy.place.category = category }
        if let localName = ContractText.clean(query.localName, maxLength: 120) { copy.place.localName = localName }
        return copy
    }

    // MARK: Lookup

    private enum Term: CustomStringConvertible {
        case text(String)
        /// A category query: any hit must still match the name.
        case category(String)

        var description: String {
            switch self {
            case let .text(text): "\"\(text)\""
            case let .category(text): "category \"\(text)\""
            }
        }
    }

    private func lookUp(_ query: PlaceQuery) async -> Outcome {
        let radius = min(max(query.radiusMeters, Self.regionRadius.lowerBound), Self.regionRadius.upperBound)
        let region = MKCoordinateRegion(around: query.near, meters: radius * 2)
        let inChina = await countryCode(near: query.near) == "CN"

        var texts = [query.name, query.localName].compactMap { ContractText.clean($0, maxLength: 120) }
        if inChina { texts.reverse() }
        var terms = texts.reduce(into: [Term]()) { terms, text in
            if !terms.contains(where: { if case let .text(existing) = $0 { existing == text } else { false } }) {
                terms.append(.text(text))
            }
        }
        if let category = query.category, let categoryText = Self.searchText(for: category, inChina: inChina) {
            terms.append(.category(categoryText))
        }

        var failed = false
        for term in terms {
            switch await search(term, in: region) {
            case let .some(items):
                if let hit = bestHit(in: items, for: query) {
                    RyokoLog.places.info(
                        "Resolved \(query.name, privacy: .public) → \(hit.place.name, privacy: .public), \(Int(hit.distanceMeters)) m, via \(term.description, privacy: .public)"
                    )
                    return .found(hit)
                }
            case .none:
                failed = true
            }
        }
        if failed {
            RyokoLog.places.error("Couldn't resolve \(query.name, privacy: .public): MapKit failed")
            return .failed
        }
        RyokoLog.places.info("No match for \(query.name, privacy: .public) within 5 km")
        return .miss
    }

    /// One `MKLocalSearch`. nil when MapKit failed; empty for no results.
    private func search(_ term: Term, in region: MKCoordinateRegion) async -> [MKMapItem]? {
        guard await waitForSlot() else { return nil }
        let request = MKLocalSearch.Request()
        switch term {
        case let .text(text), let .category(text):
            request.naturalLanguageQuery = text
        }
        request.region = region
        request.regionPriority = .required
        request.resultTypes = .pointOfInterest
        do {
            return try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch let error as MKError where error.code == .loadingThrottled {
            pausedUntil = .now + .seconds(60)
            RyokoLog.places.error("MapKit throttled the resolver; pausing for a minute")
            return nil
        } catch {
            if !Task.isCancelled {
                RyokoLog.places.error("MapKit search failed: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// The best-matching hit within 5 km: an exact name first, then one name
    /// containing the other, then a close spelling; the nearest within that.
    private func bestHit(in items: [MKMapItem], for query: PlaceQuery) -> ResolvedPlace? {
        let center = query.near.mapKitLocation
        return items
            .compactMap { item -> (hit: ResolvedPlace, score: Int)? in
                guard let itemName = item.name else { return nil }
                let score = max(
                    PlaceNameMatch.score(itemName, against: query.name),
                    PlaceNameMatch.score(itemName, against: query.localName)
                )
                guard score > 0, let place = NearbySearch.place(from: item) else { return nil }
                let distance = item.location.distance(from: center)
                guard distance <= Self.maxDistance else { return nil }
                return (ResolvedPlace(query: query, place: place, distanceMeters: distance), score)
            }
            .min { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.hit.distanceMeters < rhs.hit.distanceMeters
            }?
            .hit
    }

    // MARK: Country

    /// The country at `coordinate`, from one reverse geocode per ~10 km cell.
    private func countryCode(near coordinate: Coordinate) async -> String? {
        let cell = String(format: "%.1f,%.1f", coordinate.lat, coordinate.lon)
        if let known = countries[cell] { return known }
        guard await waitForSlot(), let request = MKReverseGeocodingRequest(location: coordinate.mapKitLocation) else {
            return nil
        }
        do {
            let items = try await request.mapItems
            let code = items.lazy.compactMap { $0.addressRepresentations?.region?.identifier.uppercased() }.first
            countries[cell] = .some(code)
            return code
        } catch let error as MKError where error.code == .placemarkNotFound {
            countries[cell] = .some(nil)
            return nil
        } catch {
            return nil // try again next time
        }
    }

    // MARK: Throttle

    /// Waits until a request fits in the rolling minute, then records it.
    /// False if the waiting task was cancelled.
    private func waitForSlot() async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let now = ContinuousClock.now
            if let pausedUntil, pausedUntil > now {
                guard (try? await Task.sleep(until: pausedUntil)) != nil else { return false }
                continue
            }
            requestLog.removeAll { now - $0 >= .seconds(60) }
            if requestLog.count < Self.requestsPerMinute {
                requestLog.append(now)
                return true
            }
            let wait = requestLog[0] + .seconds(60) - now
            RyokoLog.places.info("Resolver throttle: waiting \(wait.components.seconds) s")
            guard (try? await Task.sleep(for: wait)) != nil else { return false }
        }
    }

    // MARK: Keys

    /// (normalized name, area): the area is the query centre rounded to 2
    /// decimals (about 1 km), so nearby centres share answers.
    private static func answerKey(_ query: PlaceQuery) -> String {
        "\(PlaceNameMatch.normalized(query.name))|\(String(format: "%.2f,%.2f", query.near.lat, query.near.lon))"
    }

    /// What to search for a category, or nil when the category is too broad.
    private static func searchText(for category: CategorySlug, inChina: Bool) -> String? {
        switch category {
        case .cafe: "cafe"
        case .tea: "tea"
        case .restaurant: "restaurant"
        case .ramen: "ramen"
        case .bar: "bar"
        case .bakery: "bakery"
        case .convenienceStore: "convenience store"
        case .museum: "museum"
        case .park: "park"
        case .templeShrine: inChina ? "temple" : "shrine"
        case .shopping: nil
        case .transit: "station"
        case .hotel: "hotel"
        case .other: nil
        }
    }
}

// MARK: - Name similarity

/// Whether a MapKit name is the place that was asked for (design §4.7: short
/// brand queries match loosely, so every hit is checked).
nonisolated enum PlaceNameMatch {
    /// Lowercased, without diacritics, full-width forms or punctuation:
    /// "Omoide Yokochō" → "omoideyokocho", "ＣＯＣＯ都可" → "coco都可".
    static func normalized(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    /// 3: the same name. 2: one contains most of the other ("Blue Bottle
    /// Coffee" in "Blue Bottle Coffee Shinjuku Cafe"). 1: one contains the
    /// other but isn't a stray fragment of it ("Shinjuku Gyoen" in "Shinjuku
    /// Gyoen National Garden"), or a close spelling ("Fu-unji" / "Fuunji").
    /// 0: not the place.
    static func score(_ candidate: String, against wanted: String?) -> Int {
        guard let wanted else { return 0 }
        let a = normalized(candidate)
        let b = normalized(wanted)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 3 }

        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        let minimum = short.unicodeScalars.contains(where: \.properties.isIdeographic) ? 2 : 4
        let coverage = Double(short.count) / Double(long.count)
        if long.contains(short), short.count >= minimum, coverage >= 0.4 {
            return coverage >= 0.75 ? 2 : 1
        }
        return dice(a, b) >= 0.6 ? 1 : 0
    }

    /// Sørensen–Dice coefficient over character bigrams.
    static func dice(_ a: String, _ b: String) -> Double {
        let x = bigrams(a)
        let y = bigrams(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var remaining = y
        var shared = 0
        for gram in x {
            if let index = remaining.firstIndex(of: gram) {
                shared += 1
                remaining.remove(at: index)
            }
        }
        return 2 * Double(shared) / Double(x.count + y.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 1 else { return characters.map(String.init) }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }
}
