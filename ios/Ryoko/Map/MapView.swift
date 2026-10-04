import MapKit
import os
import SwiftUI

/// The Map tab, the app's home screen and the one place for places (design
/// §3, §4.7, W4): MapKit with your location, search, POI taps, long-press
/// pins, layers, and the bottom panel: "You're at …", Mimo picks and nearest
/// places, and any place's card.
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
/// While a card is open at full height, the search field and map buttons step
/// aside so the strip of map above it shows just the place.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Namespace private var mapScope
    /// The space between the status bar and the tab bar (global), keyboard or not.
    @State private var screenFrame = CGRect(x: 0, y: 0, width: 400, height: 700)
    /// `screenFrame` has been measured (not the placeholder above).
    @State private var isMeasured = false
    @State private var searchBarHeight: CGFloat = 48
    @State private var headerHeight: CGFloat = 56
    @State private var confirmations = 0
    @State private var debugApplied = false

    /// Space between the status bar and the search field.
    private static let searchTop: CGFloat = 4

    var body: some View {
        // Where the panel's space starts: under the search field.
        let belowSearch = Self.searchTop + searchBarHeight
        let isCard = model.details != nil
        let metrics = MapSheetMetrics(
            screen: screenFrame.height,
            belowSearch: belowSearch,
            header: headerHeight,
            pinned: isCard ? model.cardActionsHeight : 0,
            isCard: isCard
        )
        let anchor = MapHome.listAnchor(situationStore)
        let cardIsFull = model.details != nil && model.detent == .large && !search.isPresented

        ZStack(alignment: .top) {
            map(anchor: anchor)
                .safeAreaPadding(.top, belowSearch + Theme.grid)
                .safeAreaPadding(.bottom, metrics.mapBottomPadding(for: model.detent))
                .ignoresSafeArea(.keyboard)
            if !cardIsFull {
                mapButtons
                    .padding(.top, belowSearch + Theme.grid)
                    .padding(.trailing, MapSheetMetrics.sideInset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
            if !search.isPresented {
                panel(metrics: metrics, anchor: anchor)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !cardIsFull {
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
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .mapScope(mapScope)
        .animation(.smooth, value: search.isPresented)
        .animation(.smooth, value: cardIsFull)
        .background {
            Color.clear
                .ignoresSafeArea(.keyboard)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    screenFrame = frame
                    isMeasured = true
                }
        }
        .onChange(of: cardGeometry(belowSearch: belowSearch, metrics: metrics), initial: true) { _, geometry in
            // Only real measurements: a card that opened before them is
            // framed again once they arrive.
            guard let geometry else { return }
            model.setMapGeometry(safeArea: geometry.safeArea, cardViewports: geometry.viewports)
        }
        .onChange(of: model.detent) {
            // The map follows the card: its place stays centred in the map
            // above it at every size. The list leaves the camera alone.
            model.followCard()
        }
        .onChange(of: situationStore.lastFix, initial: true) { _, fix in
            model.userLocation = fix
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
            // A card keeps the map where it put it.
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

    private struct CardGeometry: Equatable {
        var safeArea: CGRect
        var viewports: MapHomeModel.CardViewports
    }

    /// In global coordinates, once the screen is measured:
    /// - the map's safe area: the screen minus the padding for the search
    ///   field and the resting list. Camera positions are framed in it, and
    ///   its middle is the camera's centre;
    /// - the map visible above a card at each size: under the search field
    ///   (or, at large, where the search field steps aside, under the status
    ///   bar) down to the top of the panel.
    private func cardGeometry(belowSearch: CGFloat, metrics: MapSheetMetrics) -> CardGeometry? {
        guard isMeasured else { return nil }
        let top = belowSearch + Theme.grid
        let card = MapSheetMetrics(
            screen: screenFrame.height,
            belowSearch: belowSearch,
            header: headerHeight,
            pinned: model.cardActionsHeight,
            isCard: true
        )
        func viewport(_ detent: MapSheetDetent) -> CGRect {
            let minY = screenFrame.minY + (detent == .large ? 0 : top)
            let maxY = screenFrame.maxY - MapSheetMetrics.bottomGap - card.height(for: detent)
            return CGRect(x: screenFrame.minX, y: minY, width: screenFrame.width, height: max(maxY - minY, 44))
        }
        return CardGeometry(
            safeArea: CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY + top,
                width: screenFrame.width,
                height: max(screenFrame.height - top - metrics.mapBottomPadding(for: model.detent), 1)
            ),
            viewports: MapHomeModel.CardViewports(
                small: viewport(.small),
                medium: viewport(.medium),
                large: viewport(.large)
            )
        )
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

    /// The card's place when nothing else on the map marks it (opened from
    /// the list, the header or another tab). Tapped map features are
    /// highlighted by MapKit; the other markers are selected by the card
    /// (`MapHomeModel.markerTag(for:)`).
    private var focusMarker: MapPlace? {
        guard let details = model.details else { return nil }
        return model.markerTag(for: details) == MapMarkerTag.focus.tag(details.id) ? details : nil
    }

    // MARK: Panel

    /// A card replaces the list in place, at the same size (Apple Maps
    /// style): a calm crossfade with a small rise, or only the crossfade
    /// with Reduce Motion.
    private var swapAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.35)
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16))
    }

    @ViewBuilder
    private func panel(metrics: MapSheetMetrics, anchor: Coordinate?) -> some View {
        let situation = situationStore.situation
        let card = model.card
        // At accessibility text sizes a pinned title would fill the panel, so
        // the list's header and the card's title scroll with their content
        // (only Back stays pinned).
        let scrollsTitles = dynamicTypeSize.isAccessibilitySize
        let listHeader = MapListHeader(
            situation: situation,
            liveState: situationStore.liveState,
            onOpenPlace: openCurrentPlaceCard,
            onRefresh: { situationStore.refresh() },
            onBackToHere: { situationStore.endPreview() }
        )
        let cardTitle = card.map { card in
            MapPlaceCardTitle(
                place: card,
                languageTag: languageTag(for: card),
                localName: card.place.localName ?? model.detailsLocalName,
                timeZone: card.timeZone ?? model.detailsArea?.timeZone
            )
        }
        MapSheetPanel(detent: $model.detent, metrics: metrics) {
            // Overlapping while they crossfade, so the panel never stacks two
            // headers; the panel measures whichever is showing.
            ZStack(alignment: .topLeading) {
                if let card {
                    MapPlaceCardHeader(
                        title: scrollsTitles ? nil : cardTitle,
                        backTo: model.base == .list ? "the list" : "the results",
                        onBack: model.back
                    )
                    .id(card.id)
                    .transition(.opacity)
                } else {
                    switch model.base {
                    case .list:
                        if !scrollsTitles {
                            listHeader
                                .transition(.opacity)
                        }
                    case let .results(query):
                        MapResultsHeader(query: query, count: model.searchResults.count, onBack: model.back)
                            .transition(.opacity)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            .animation(swapAnimation, value: card?.id)
        } content: {
            // The list (or results) stays alive under a card, so Back finds
            // it at the scroll position it had.
            ZStack(alignment: .top) {
                Group {
                    switch model.base {
                    case .list:
                        MapPlaceList(
                            picks: model.picks,
                            nearby: model.nearby,
                            languageTag: situation?.localLanguage,
                            hasSituation: situation != nil && anchor != nil,
                            liveState: situationStore.liveState,
                            onSelect: { model.showDetails($0) },
                            onRetryPicks: { model.picksAttempt += 1 },
                            onFindMe: { situationStore.refresh() },
                            header: scrollsTitles ? listHeader : nil
                        )
                        .debugListScroll(ready: isListSettled)
                    case .results:
                        MapSearchResultsList(
                            results: model.searchResults,
                            languageTag: nil,
                            onSelect: { model.showDetails($0) }
                        )
                    }
                }
                .opacity(card == nil ? 1 : 0)
                .allowsHitTesting(card == nil)
                .accessibilityHidden(card != nil)

                if let card {
                    MapPlaceCard(
                        place: card,
                        title: scrollsTitles ? cardTitle : nil,
                        model: model,
                        anchor: anchor,
                        onHere: { place, area in makeHere(place, area: area, anchor: anchor) }
                    )
                    .id(card.id)
                    .debugCardAPIOverride()
                    .transition(cardTransition)
                }
            }
            .animation(swapAnimation, value: card?.id)
        }
    }

    /// The list has its picks and nearby places (for `-RyokoMapScrollList`).
    private var isListSettled: Bool {
        guard case .loaded = model.nearby else { return false }
        if case .loading = model.picks { return false }
        return true
    }

    /// The tag for a place's local name: the situation's language for places
    /// around it, otherwise the place's own country's.
    private func languageTag(for place: MapPlace) -> String? {
        if let area = place.area ?? model.detailsArea {
            return LocalLanguage.forRegion(area.countryCode, subdivision: area.subdivision).tag
        }
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

    /// The card's "I'm here": you're within about 300 m, so this becomes your
    /// live place (design §4.7), which Mimo, Translate and the Live Activity
    /// follow. A preview ends first. You stay on the card.
    private func makeHere(_ place: MapPlace, area knownArea: PlaceArea?, anchor: Coordinate?) {
        Task {
            var area = knownArea
            if area == nil {
                area = await model.area(for: place, situation: situationStore.situation, anchor: anchor)
            }
            if situationStore.previewSituation != nil { situationStore.endPreview() }
            situationStore.makeCurrent(NearbyCandidate(
                place: place.place,
                distanceMeters: situationStore.lastFix.map { place.place.coordinate.mapDistance(to: $0) } ?? 0,
                timeZone: place.timeZone ?? area?.timeZone,
                area: area
            ))
            confirmations += 1
        }
    }

    /// The header's tap: the current place's card.
    private func openCurrentPlaceCard() {
        guard let place = MapHome.currentPlace(situationStore) else { return }
        model.showDetails(place)
    }

    /// A tapped point of interest or marker opens its card (replacing an open
    /// one); a tap on empty map goes back to the list.
    ///
    /// MapKit clears the selection when you tap empty map. Code clears it
    /// only in `MapHomeModel.back()`, after the card has gone, so a nil
    /// selection with a card still open is always a tap.
    private func handleSelection(_ selection: MapSelection<String>?, anchor: Coordinate?) {
        #if DEBUG
        RyokoLog.places.info("Selection: \(String(describing: selection?.value), privacy: .public) feature \(selection?.feature != nil), card \(model.details?.title ?? "none", privacy: .public)")
        #endif
        guard let selection else {
            if model.details != nil { model.back() }
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
            model.showDetails(placeholder)
            Task {
                guard let item = try? await MKMapItemRequest(feature: feature).mapItem,
                      let place = MapPlace(item: item, source: .feature, from: anchor?.mapKitLocation, name: name)
                else { return }
                model.refineDetails(place, replacing: placeholder)
            }
        } else if let tag = selection.value, let place = markerPlace(for: tag, anchor: anchor) {
            // The card selected its own marker: nothing more to do.
            guard place.id != model.details?.id else { return }
            model.showDetails(place)
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
            model.detent = .medium
            model.focus(on: coordinate, meters: 600)
        case let .place(place):
            model.showDetails(
                MapPlace(
                    place: place,
                    source: .focus,
                    distanceMeters: anchor.map { place.coordinate.mapDistance(to: $0) }
                )
            )
        case .fromMimo:
            model.layers.fromMimo = true
            if model.details != nil { model.back() }
            model.detent = .medium
            model.fit(router.fromMimo.map(\.resolved.place.coordinate))
        case .currentPlace:
            openCurrentPlaceCard()
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
        MapDebugOptions.runTemplateCheckOnce()
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

        let opensCard = options.detailsName != nil || options.card != nil
        if opensCard { model.debugCardAction = options.cardAction }
        let needsAnchor = opensCard || options.fromMimoSample || !options.resolverCheck.isEmpty
        var anchor = MapHome.listAnchor(situationStore)
        if needsAnchor {
            for _ in 0..<120 where anchor == nil {
                try? await Task.sleep(for: .milliseconds(250))
                anchor = MapHome.listAnchor(situationStore)
            }
        }
        if opensCard {
            // Let the map settle at your location first.
            try? await Task.sleep(for: .seconds(1))
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
                // Through the router, as another tab would ("Show on map").
                router.openMap(selecting: resolved.place)
            }
        }
        if let card = options.card {
            await openDebugCard(card)
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

    /// `-RyokoMapCard here|pick|nearby`, once there's such a place (up to 30 s).
    private func openDebugCard(_ which: String) async {
        if MapDebugOptions.listScroll != nil {
            // Let the list fill and scroll first (`MapListDebugScroll`).
            for _ in 0..<120 where !isListSettled { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(4))
        }
        for _ in 0..<120 {
            let place: MapPlace? = switch which {
            case "here": MapHome.currentPlace(situationStore)
            case "pick": isPicksSettled ? model.picks.places.first : nil
            case "nearby": model.nearby.places.first
            default: nil
            }
            if let place {
                RyokoLog.places.info("Debug: opening the card for \(place.title, privacy: .public)")
                model.showDetails(place)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        RyokoLog.places.info("Debug: no \(which, privacy: .public) card to open")
    }

    private var isPicksSettled: Bool {
        if case .loaded = model.picks { true } else { false }
    }
    #endif
}

private extension View {
    /// DEBUG: `-RyokoMapScrollList`. Does nothing in release builds.
    func debugListScroll(ready: Bool) -> some View {
        #if DEBUG
        modifier(MapListDebugScroll(ready: ready))
        #else
        self
        #endif
    }

    /// DEBUG: `-RyokoMapCardFailure` and `-RyokoMapCardLatency`. Does nothing
    /// in release builds.
    func debugCardAPIOverride() -> some View {
        #if DEBUG
        modifier(MapCardDebugAPIOverride())
        #else
        self
        #endif
    }
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
