import MapKit
import os
import SwiftUI

/// The Map tab, the app's home screen (design §3, §4.7, W4): MapKit with your
/// location, search, POI taps, long-press pins, layers, and the bottom panel of
/// Mimo picks and nearest places, which also shows a place's details.
struct MapView: View {
    @State private var model = MapHomeModel()
    @State private var search = MapSearch()

    var body: some View {
        MapHomeScreen(model: model, search: search)
    }
}

// MARK: - Screen

/// The map, the floating search field and map buttons, and the panel over it.
/// No navigation bar: the search field floats with the panel's side margins.
private struct MapHomeScreen: View {
    @Bindable var model: MapHomeModel
    let search: MapSearch

    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(APIStore.self) private var apiStore
    @Environment(AppRouter.self) private var router
    @Environment(\.ryokoAPI) private var api
    @Environment(\.placeResolver) private var resolver
    @Environment(\.scenePhase) private var scenePhase

    @Namespace private var mapScope
    /// The height between the status bar and the tab bar, keyboard or not.
    @State private var screenHeight: CGFloat = 700
    @State private var searchBarHeight: CGFloat = 48
    @State private var headerHeight: CGFloat = 56
    /// Measured by the list: where its third row ends.
    @State private var threeRowsHeight: CGFloat?
    @State private var confirmations = 0
    @State private var debugApplied = false
    /// About one list row, growing with the text size.
    @ScaledMetric(relativeTo: .body) private var rowEstimate: CGFloat = 64
    @ScaledMetric(relativeTo: .headline) private var sectionTitleEstimate: CGFloat = 30

    /// Space between the status bar and the search field.
    private static let searchTop: CGFloat = 4

    var body: some View {
        // Where the panel's space starts: under the search field.
        let belowSearch = Self.searchTop + searchBarHeight
        let metrics = MapSheetMetrics(
            available: screenHeight - belowSearch,
            smallContent: 20 + headerHeight + (threeRowsHeight ?? sectionTitleEstimate + rowEstimate * 3)
        )
        let anchor = MapHome.listAnchor(situationStore)

        ZStack(alignment: .top) {
            map(anchor: anchor)
                .safeAreaPadding(.top, belowSearch + Theme.grid)
                .safeAreaPadding(.bottom, metrics.mapBottomPadding)
                .ignoresSafeArea(.keyboard)
            mapButtons
                .padding(.top, belowSearch + Theme.grid)
                .padding(.trailing, MapSheetMetrics.sideInset)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if !search.isPresented {
                panel(metrics: metrics, anchor: anchor)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            VStack(spacing: Theme.grid) {
                MapSearchBar(search: search, onSubmit: submit)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchBarHeight = $0 }
                if search.isPresented {
                    MapSearchSuggestions(suggestions: search.suggestions, onPick: pick)
                }
            }
            .padding(.horizontal, MapSheetMetrics.sideInset)
            .padding(.top, Self.searchTop)
            .padding(.bottom, MapSheetMetrics.bottomGap)
        }
        .mapScope(mapScope)
        .animation(.smooth, value: search.isPresented)
        .background {
            Color.clear
                .ignoresSafeArea(.keyboard)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        }
        .sensoryFeedback(.selection, trigger: confirmations)
        .task { situationStore.startLiveIfAuthorized() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { situationStore.startLiveIfAuthorized() }
        }
        .task(id: picksKey(anchor: anchor)) {
            guard let key = picksKey(anchor: anchor), let anchor,
                  let situation = situationStore.currentSituation() else {
                model.clearPicks()
                return
            }
            await model.loadPicks(
                key,
                origin: anchor,
                profile: profileStore.profile,
                situation: situation,
                api: api,
                resolver: resolver
            )
        }
        .task(id: anchor) {
            if let anchor {
                await model.loadNearby(around: anchor)
            } else {
                model.clearNearby()
            }
        }
        .onChange(of: model.selection) { _, selection in
            handleSelection(selection, anchor: anchor)
        }
        .onChange(of: router.mapFocus, initial: true) { _, focus in
            guard let focus else { return }
            apply(focus, anchor: anchor)
            router.mapFocus = nil
        }
        .onChange(of: situationStore.previewSituation?.place, initial: true) { _, place in
            // Follow a preview started anywhere; back to you when it ends.
            guard model.details == nil else { return }
            if let place {
                model.focus(on: place.coordinate, meters: 1_200)
            } else {
                withAnimation(.smooth) { model.camera = .userLocation(fallback: .automatic) }
            }
        }
        #if DEBUG
        .task { await applyDebugOptions() }
        #endif
    }

    // MARK: Map

    private func map(anchor: Coordinate?) -> some View {
        MapReader { proxy in
            Map(position: $model.camera, selection: $model.selection, scope: mapScope) {
                UserAnnotation()
                markers
            }
            .mapStyle(model.layers.mapStyle)
            .mapControls {
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                model.visibleRegion = context.region
                search.setRegion(context.region)
            }
            .gesture(MapLongPress { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                Task { await model.dropPin(at: Coordinate(mapKit: coordinate), origin: anchor) }
            })
        }
    }

    /// Under the search field on the trailing side: your location, then
    /// Layers, then the compass while the map is rotated.
    private var mapButtons: some View {
        VStack(spacing: Theme.grid) {
            MapUserLocationButton(scope: mapScope)
            MapLayersMenu(
                layers: $model.layers,
                fromMimoCount: router.fromMimo.count,
                onClearFromMimo: { router.clearFromMimo() }
            )
            MapCompass(scope: mapScope)
        }
        .buttonBorderShape(.circle)
    }

    @MapContentBuilder
    private var markers: some MapContent {
        if model.layers.hiddenGems {
            ForEach(hiddenGems) { place in
                Marker(place.title, systemImage: place.place.category.sfSymbol, coordinate: place.coordinate)
                    .tint(.orange)
                    .tag(MapSelection(MapMarkerTag.gem.tag(place.id)))
            }
        }
        if model.layers.fromMimo, !router.fromMimo.isEmpty {
            if router.fromMimo.isPlan, router.fromMimo.count > 1 {
                MapPolyline(coordinates: planCoordinates)
                    .stroke(.teal.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 7]))
            }
            ForEach(router.fromMimo) { pin in
                fromMimoMarker(pin)
                    .tint(.teal)
                    .tag(MapSelection(MapMarkerTag.mimo.tag(pin.id)))
            }
        }
        ForEach(model.searchResults) { place in
            Marker(place.title, coordinate: place.coordinate)
                .tag(MapSelection(MapMarkerTag.search.tag(place.id)))
        }
        if let pin = model.droppedPin {
            Marker("Dropped pin", systemImage: "mappin", coordinate: pin.coordinate)
                .tag(MapSelection(MapMarkerTag.pin.tag(pin.id)))
        }
        if let focused = focusMarker {
            Marker(focused.title, systemImage: focused.place.category.sfSymbol, coordinate: focused.coordinate)
                .tag(MapSelection(MapMarkerTag.focus.tag(focused.id)))
        }
    }

    /// Picks, minus any already pinned by the From Mimo layer.
    private var hiddenGems: [MapPlace] {
        guard model.layers.fromMimo, !router.fromMimo.isEmpty else { return model.picks.places }
        let pinned = Set(router.fromMimo.map { MapPlace.key(for: $0.resolved.place) })
        return model.picks.places.filter { !pinned.contains($0.id) }
    }

    private func fromMimoMarker(_ pin: FromMimoPin) -> Marker<Label<Text, Text>> {
        Marker(
            pin.shown.name,
            monogram: Text(pin.shown.order.map(String.init) ?? "M"),
            coordinate: pin.resolved.place.coordinate.mapKitCoordinate
        )
    }

    /// A plan's stops in order.
    private var planCoordinates: [CLLocationCoordinate2D] {
        router.fromMimo
            .sorted { ($0.shown.order ?? 0) < ($1.shown.order ?? 0) }
            .map(\.resolved.place.coordinate.mapKitCoordinate)
    }

    /// The place in details when nothing else on the map marks it (opened from
    /// the list or another tab). Tapped map features are highlighted by MapKit.
    private var focusMarker: MapPlace? {
        guard let details = model.details else { return nil }
        switch details.source {
        case .feature, .search, .droppedPin, .fromMimo: return nil
        case .pick: return model.layers.hiddenGems ? nil : details
        case .nearby, .focus: return details
        }
    }

    // MARK: Panel

    @ViewBuilder
    private func panel(metrics: MapSheetMetrics, anchor: Coordinate?) -> some View {
        let situation = situationStore.situation
        MapSheetPanel(detent: $model.detent, metrics: metrics) {
            switch model.panel {
            case .list:
                MapListHeader(
                    situation: situation,
                    liveState: situationStore.liveState,
                    onRefresh: { situationStore.refresh() },
                    onBackToHere: { situationStore.endPreview() }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            case let .results(query):
                MapResultsHeader(query: query, count: model.searchResults.count, onBack: model.back)
            case let .details(place):
                MapPlaceDetailsHeader(place: place, languageTag: languageTag(for: place), onBack: model.back)
            }
        } content: {
            switch model.panel {
            case .list:
                MapPlaceList(
                    picks: model.picks,
                    nearby: model.nearby,
                    languageTag: situation?.localLanguage,
                    hasSituation: situation != nil && anchor != nil,
                    liveState: situationStore.liveState,
                    onSelect: { makeCurrent($0, area: nil, anchor: anchor) },
                    onDetails: { model.showDetails($0, fromMap: false) },
                    onRetryPicks: { model.picksAttempt += 1 },
                    onFindMe: { situationStore.refresh() },
                    onThreeRowsHeight: { threeRowsHeight = $0 }
                )
            case .results:
                MapSearchResultsList(
                    results: model.searchResults,
                    languageTag: nil,
                    onDetails: { model.showDetails($0, fromMap: false) }
                )
            case let .details(place):
                MapPlaceDetails(
                    place: place,
                    model: model,
                    anchor: anchor,
                    onMakeCurrent: { place, area in makeCurrent(place, area: area, anchor: anchor) }
                )
                .id(place.id)
            }
        }
    }

    /// The tag for a place's local name: the situation's language for places
    /// around it, otherwise the place's own country's.
    private func languageTag(for place: MapPlace) -> String? {
        if let area = place.area { return LocalLanguage.forRegion(area.countryCode, subdivision: area.subdivision).tag }
        return situationStore.situation?.localLanguage
    }

    // MARK: Search

    /// A picked suggestion: its place, on the map and in the panel.
    private func pick(_ completion: MKLocalSearchCompletion) {
        let title = completion.title
        search.end()
        let origin = MapHome.listAnchor(situationStore)?.mapKitLocation
        Task {
            guard let item = await search.item(for: completion),
                  let place = MapPlace(item: item, source: .search, from: origin, name: title) else { return }
            model.showResults([place], for: title)
        }
    }

    /// A submitted query: matching places near what's on screen.
    private func submit() {
        let query = search.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        search.end()
        let origin = MapHome.listAnchor(situationStore)?.mapKitLocation
            ?? model.visibleRegion.map { CLLocation(latitude: $0.center.latitude, longitude: $0.center.longitude) }
        Task {
            let items = await search.items(for: query, near: model.visibleRegion)
            var seen = Set<String>()
            let places = items
                .compactMap { MapPlace(item: $0, source: .search, from: origin) }
                .filter { seen.insert($0.id).inserted }
                .prefix(MapHome.nearbyLimit)
            model.showResults(Array(places), for: query)
        }
    }

    // MARK: Actions

    /// Makes `place` the current place, then opens Nearby (design §4.7).
    private func makeCurrent(_ place: MapPlace, area knownArea: PlaceArea?, anchor: Coordinate?) {
        Task {
            var area = knownArea
            if area == nil {
                area = await model.area(for: place, situation: situationStore.situation, anchor: anchor)
            }
            situationStore.makeCurrent(NearbyCandidate(
                place: place.place,
                distanceMeters: place.distanceMeters ?? 0,
                timeZone: place.timeZone ?? area?.timeZone,
                area: area
            ))
            confirmations += 1
            router.openNearby()
        }
    }

    /// A tapped point of interest or marker opens its details; tapping away closes them.
    private func handleSelection(_ selection: MapSelection<String>?, anchor: Coordinate?) {
        guard let selection else {
            if model.detailsFromMap, model.details != nil { model.back() }
            return
        }
        if let feature = selection.feature {
            let name = feature.title ?? "Place"
            let coordinate = Coordinate(mapKit: feature.coordinate)
            let placeholder = MapPlace(
                place: Place(
                    id: nil,
                    name: name,
                    localName: nil,
                    category: PlaceCategoryMapping.slug(for: feature.pointOfInterestCategory, name: name),
                    address: nil,
                    coordinate: coordinate
                ),
                source: .feature,
                distanceMeters: anchor.map { coordinate.mapDistance(to: $0) }
            )
            model.showDetails(placeholder, fromMap: true)
            Task {
                guard let item = try? await MKMapItemRequest(feature: feature).mapItem,
                      let place = MapPlace(item: item, source: .feature, from: anchor?.mapKitLocation, name: name)
                else { return }
                model.refineDetails(place, replacing: placeholder)
            }
        } else if let tag = selection.value, let place = markerPlace(for: tag, anchor: anchor) {
            model.showDetails(place, fromMap: true)
        }
    }

    private func markerPlace(for tag: String, anchor: Coordinate?) -> MapPlace? {
        guard let (kind, id) = MapMarkerTag.parse(tag) else { return nil }
        switch kind {
        case .gem: return model.picks.places.first { $0.id == id }
        case .search: return model.searchResults.first { $0.id == id }
        case .pin: return model.droppedPin
        case .focus: return model.details
        case .mimo:
            guard let pin = router.fromMimo.first(where: { $0.id == id }) else { return nil }
            return MapPlace(
                place: pin.resolved.place,
                source: .fromMimo(pin.shown),
                distanceMeters: anchor.map { pin.resolved.place.coordinate.mapDistance(to: $0) },
                displayName: pin.shown.name
            )
        }
    }

    /// `router.mapFocus` from another tab.
    private func apply(_ focus: MapFocus, anchor: Coordinate?) {
        switch focus {
        case let .coordinate(coordinate):
            if model.details != nil { model.back() }
            model.detent = .small
            model.focus(on: coordinate, meters: 600)
        case let .place(place):
            model.showDetails(
                MapPlace(
                    place: place,
                    source: .focus,
                    distanceMeters: anchor.map { place.coordinate.mapDistance(to: $0) }
                ),
                fromMap: false
            )
        case .fromMimo:
            model.layers.fromMimo = true
            if model.details != nil { model.back() }
            model.detent = .small
            model.fit(router.fromMimo.map(\.resolved.place.coordinate))
        }
    }

    private func picksKey(anchor: Coordinate?) -> MapHomeModel.PicksKey? {
        guard let situation = situationStore.situation, let anchor else { return nil }
        // About 100 m: a fresh fix a few metres away doesn't ask again.
        let rounded = Coordinate(
            lat: (anchor.lat * 1_000).rounded() / 1_000,
            lon: (anchor.lon * 1_000).rounded() / 1_000
        )
        return MapHomeModel.PicksKey(
            center: rounded,
            city: situation.city,
            district: situation.district,
            hourBucket: situation.hourBucket,
            localLanguage: situation.localLanguage,
            profileVersion: profileStore.profile.version,
            apiGeneration: apiStore.apiGeneration,
            attempt: model.picksAttempt
        )
    }

    // MARK: DEBUG

    #if DEBUG
    private func applyDebugOptions() async {
        guard !debugApplied else { return }
        debugApplied = true
        let options = MapDebugOptions.self
        let layers = options.layers
        if layers.contains("food") { model.layers.foodAndDrink = true }
        if layers.contains("washrooms") { model.layers.washrooms = true }
        if layers.contains("gems") { model.layers.hiddenGems = true }
        if let detent = options.detent { model.detent = detent }
        if let text = options.searchText {
            search.isPresented = true
            search.text = text
        }

        let needsAnchor = options.detailsName != nil || options.fromMimoSample || !options.resolverCheck.isEmpty
        var anchor = MapHome.listAnchor(situationStore)
        if needsAnchor {
            for _ in 0..<120 where anchor == nil {
                try? await Task.sleep(for: .milliseconds(250))
                anchor = MapHome.listAnchor(situationStore)
            }
        }
        if let anchor {
            for entry in options.resolverCheck {
                // "name" or "name;localName;category", as discover sends them.
                let parts = entry.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                let name = parts[0]
                let query = PlaceQuery(
                    name: name,
                    localName: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil,
                    category: parts.count > 2 ? CategorySlug(rawValue: parts[2]) : nil,
                    near: anchor
                )
                let result = await resolver.resolve(query)
                if let result {
                    RyokoLog.places.info("Resolver check: \(name, privacy: .public) → \(result.place.name, privacy: .public) [\(result.place.id ?? "no id", privacy: .public)] \(Int(result.distanceMeters)) m")
                } else {
                    RyokoLog.places.info("Resolver check: \(name, privacy: .public) → no match")
                }
            }
            if options.fromMimoSample {
                var pins: [FromMimoPin] = []
                for shown in MapDebugOptions.samplePlan {
                    let query = PlaceQuery(name: shown.name, localName: shown.localName, near: anchor)
                    if let resolved = await resolver.resolve(query) {
                        pins.append(FromMimoPin(shown: shown, resolved: resolved))
                    }
                }
                router.showOnMap(pins)
            }
            if let name = options.detailsName,
               let resolved = await resolver.resolve(PlaceQuery(name: name, near: anchor)) {
                model.debugDetailsAction = options.detailsAction
                // Through the router, as another tab would ("Show on map").
                router.openMap(selecting: resolved.place)
            }
        }
        if let pin = options.dropPin {
            await model.dropPin(at: pin, origin: anchor)
        }
        if let detent = options.detent { model.detent = detent }
        if options.opensLayers {
            try? await Task.sleep(for: .seconds(1))
            let path = MapDebugOptions.openTrailingBarMenu() ?? "not found"
            RyokoLog.places.info("Debug: layers menu: \(path, privacy: .public)")
        }
    }
    #endif
}

/// Map marker tags: a kind and the place's id, so a tapped marker finds its place.
enum MapMarkerTag: String {
    case gem
    case mimo
    case search
    case pin
    case focus

    func tag(_ id: String) -> String { "\(rawValue)|\(id)" }

    static func parse(_ tag: String) -> (MapMarkerTag, String)? {
        guard let bar = tag.firstIndex(of: "|"), let kind = MapMarkerTag(rawValue: String(tag[..<bar])) else { return nil }
        return (kind, String(tag[tag.index(after: bar)...]))
    }
}

#Preview {
    MapView()
        .environment(AppSituationStore.preview(Fixtures.tokyo))
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppRouter())
}
