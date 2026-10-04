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
/// 3. Accept only hits within 5 km whose name is the requested name or local
///    name, give or take area, branch and kind-of-place words
///    (`PlaceNameMatch`, word by word); the closest name wins, then the nearest.
/// 4. If no term finds a match: a local-name search hit within 5 km that has
///    every distinctive word of the English name and isn't part of a place
///    (`PlaceNameMatch.corroborates`). Several such hits must sit within
///    300 m of each other (one building's two observation decks); the nearest
///    wins. Hits further apart are different places, so none is taken. MapKit names places in the
///    device's language, so step 3 can't compare a hit with the local name:
///    "東京都庁" finds "Tokyo Metropolitan Government Office", which step 3
///    rejects for "Tokyo Metropolitan Government Building".
///
/// Answers, misses included, are cached by (normalized name, area). Places are
/// kept by `identifier.rawValue`, or normalized name plus the coordinate
/// rounded to 4 decimals when MapKit has no identifier (about 40% of Taipei
/// and Hong Kong POIs). Concurrent requests for the same name share one lookup.
///
/// MapKit allows about 50 requests a minute per app, so lookups go through a
/// sliding-window throttle of `requestsPerMinute`. A `loadingThrottled` error
/// pauses lookups for a minute, then the search is tried once more.
@MainActor
final class LivePlaceResolver: PlaceResolver {
    /// Hits further than this from the query's centre are dropped.
    static let maxDistance: CLLocationDistance = 5_000
    /// Local-name fallback hits further apart than this are different places.
    static let fallbackCluster: CLLocationDistance = 300
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
    /// Area cell → words naming the area ("shinjuku", "tokyo"), which may
    /// qualify a place's name (`PlaceNameMatch.areaWords`).
    private var areaWords: [String: Set<String>] = [:]
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
        /// The local-script name, when it differs from the name: its sole hit
        /// is the fallback (step 4).
        case localName(String)
        /// A category query: any hit must still match the name.
        case category(String)

        var description: String {
            switch self {
            case let .text(text), let .localName(text): "\"\(text)\""
            case let .category(text): "category \"\(text)\""
            }
        }
    }

    private func lookUp(_ query: PlaceQuery) async -> Outcome {
        let radius = min(max(query.radiusMeters, Self.regionRadius.lowerBound), Self.regionRadius.upperBound)
        let region = MKCoordinateRegion(around: query.near, meters: radius * 2)
        let inChina = await countryCode(near: query.near) == "CN"
        let centreArea = areaWords[Self.cell(query.near)] ?? []

        let name = ContractText.clean(query.name, maxLength: 120)
        let localName = ContractText.clean(query.localName, maxLength: 120).flatMap { $0 == name ? nil : $0 }
        var terms: [Term] = [name.map(Term.text), localName.map(Term.localName)].compactMap(\.self)
        if inChina { terms.reverse() }
        if let category = query.category, let categoryText = Self.searchText(for: category, inChina: inChina) {
            terms.append(.category(categoryText))
        }

        var failed = false
        var fallback: (hit: ResolvedPlace, item: MKMapItem)?
        for term in terms {
            var outcome = await search(term, in: region)
            if case .throttled = outcome {
                // `search` paused lookups for a minute; the retry waits it out.
                outcome = await search(term, in: region)
            }
            guard case let .items(items) = outcome else {
                failed = true
                continue
            }
            if let hit = bestHit(in: items, for: query, centreArea: centreArea) {
                RyokoLog.places.info(
                    "Resolved \(query.name, privacy: .public) → \(hit.place.name, privacy: .public), \(Int(hit.distanceMeters)) m, via \(term.description, privacy: .public)"
                )
                return .found(hit)
            }
            if case .localName = term {
                fallback = corroboratedHit(in: items, for: query, centreArea: centreArea)
            }
        }
        if let fallback {
            PlaceThumbnailLoader.shared.remember(fallback.item, for: fallback.hit.place)
            RyokoLog.places.info(
                "Resolved \(query.name, privacy: .public) → \(fallback.hit.place.name, privacy: .public), \(Int(fallback.hit.distanceMeters)) m, via its local name (loose match)"
            )
            return .found(fallback.hit)
        }
        if failed {
            RyokoLog.places.error("Couldn't resolve \(query.name, privacy: .public): MapKit failed")
            return .failed
        }
        RyokoLog.places.info("No match for \(query.name, privacy: .public) within 5 km")
        return .miss
    }

    private enum SearchOutcome {
        /// Empty for no results.
        case items([MKMapItem])
        /// MapKit throttled the app; lookups are paused for a minute.
        case throttled
        case failed
    }

    /// One `MKLocalSearch`.
    private func search(_ term: Term, in region: MKCoordinateRegion) async -> SearchOutcome {
        guard await waitForSlot() else { return .failed }
        let request = MKLocalSearch.Request()
        switch term {
        case let .text(text), let .localName(text), let .category(text):
            request.naturalLanguageQuery = text
        }
        request.region = region
        request.regionPriority = .required
        request.resultTypes = .pointOfInterest
        do {
            return .items(try await MKLocalSearch(request: request).start().mapItems)
        } catch let error as MKError where error.code == .placemarkNotFound {
            return .items([])
        } catch let error as MKError where error.code == .loadingThrottled {
            pausedUntil = .now + .seconds(60)
            RyokoLog.places.error("MapKit throttled the resolver; pausing for a minute")
            return .throttled
        } catch {
            if !Task.isCancelled {
                RyokoLog.places.error("MapKit search failed: \(String(describing: error), privacy: .public)")
            }
            return .failed
        }
    }

    /// Step 4's candidate from the local-name search's hits: the nearest one
    /// that `PlaceNameMatch.corroborates`, when every such hit is within
    /// `fallbackCluster` of it.
    private func corroboratedHit(in items: [MKMapItem], for query: PlaceQuery, centreArea: Set<String>) -> (hit: ResolvedPlace, item: MKMapItem)? {
        let center = query.near.mapKitLocation
        let candidates = items.filter { item in
            guard let name = item.name, item.location.distance(from: center) <= Self.maxDistance else { return false }
            return PlaceNameMatch.corroborates(name, wanted: query.name, areaWords: centreArea.union(Self.areaWords(of: item)))
        }
        guard let nearest = candidates.min(by: { $0.location.distance(from: center) < $1.location.distance(from: center) }),
              candidates.allSatisfy({ $0.location.distance(from: nearest.location) <= Self.fallbackCluster }),
              let place = NearbySearch.place(from: nearest)
        else { return nil }
        return (ResolvedPlace(query: query, place: place, distanceMeters: nearest.location.distance(from: center)), nearest)
    }

    /// The best-matching hit within 5 km: the same name first, then the name
    /// with qualifiers, then the name without the request's area words; the
    /// nearest within that. Area words come from the query's centre and the
    /// hit's own city and district.
    private func bestHit(in items: [MKMapItem], for query: PlaceQuery, centreArea: Set<String>) -> ResolvedPlace? {
        let center = query.near.mapKitLocation
        let best = items
            .compactMap { item -> (hit: ResolvedPlace, score: Int, item: MKMapItem)? in
                guard let itemName = item.name else { return nil }
                let area = centreArea.union(Self.areaWords(of: item))
                let score = max(
                    PlaceNameMatch.score(itemName, against: query.name, areaWords: area),
                    PlaceNameMatch.score(itemName, against: query.localName, areaWords: area)
                )
                if score == 0 {
                    RyokoLog.places.debug("Not \(query.name, privacy: .public): \(itemName, privacy: .public)")
                }
                guard score > 0, let place = NearbySearch.place(from: item) else { return nil }
                let distance = item.location.distance(from: center)
                guard distance <= Self.maxDistance else { return nil }
                return (ResolvedPlace(query: query, place: place, distanceMeters: distance), score, item)
            }
            .min { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.hit.distanceMeters < rhs.hit.distanceMeters
            }
        // So the place's thumbnail asks for its Look Around scene by item.
        if let best { PlaceThumbnailLoader.shared.remember(best.item, for: best.hit.place) }
        return best?.hit
    }

    // MARK: Country

    /// The country at `coordinate`, from one reverse geocode per ~10 km cell.
    /// The same lookup fills `areaWords` for the cell.
    private func countryCode(near coordinate: Coordinate) async -> String? {
        let cell = Self.cell(coordinate)
        if let known = countries[cell] { return known }
        guard await waitForSlot(), let request = MKReverseGeocodingRequest(location: coordinate.mapKitLocation) else {
            return nil
        }
        do {
            let items = try await request.mapItems
            let code = items.lazy.compactMap { $0.addressRepresentations?.region?.identifier.uppercased() }.first
            countries[cell] = .some(code)
            areaWords[cell] = items.prefix(1).reduce(into: Set<String>()) { $0.formUnion(Self.areaWords(of: $1)) }
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

    /// About 10 km.
    private static func cell(_ coordinate: Coordinate) -> String {
        String(format: "%.1f,%.1f", coordinate.lat, coordinate.lon)
    }

    /// City, ward and district names from a map item's address, not its street.
    private static func areaWords(of item: MKMapItem) -> Set<String> {
        let representations = item.addressRepresentations
        return PlaceNameMatch.areaWords(from: [
            representations?.cityName,
            representations?.cityWithContext(.full),
            representations?.cityWithContext,
        ])
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
