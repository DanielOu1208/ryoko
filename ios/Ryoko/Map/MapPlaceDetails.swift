import SwiftUI

// MARK: - Header

/// Back to the list, the place's name, its local name, and what and where it is.
struct MapPlaceDetailsHeader: View {
    let place: MapPlace
    let languageTag: String?
    let onBack: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.grid * 1.5) {
            Button("Back", systemImage: "chevron.backward", action: onBack)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Back to the list")
            VStack(alignment: .leading, spacing: 2) {
                Text(place.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                if let localName, let languageTag {
                    LocalText(localName, languageTag: languageTag)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(detailLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, Theme.grid * 1.5)
    }

    private var localName: String? {
        guard let local = place.place.localName, local != place.title else { return nil }
        return local
    }

    private var detailLine: String {
        if case .droppedPin = place.source {
            return place.place.address ?? "Finding the address"
        }
        var parts = [place.place.category.displayName]
        if let distance = place.distanceMeters { parts.append(MapDistanceText.text(distance)) }
        return parts.joined(separator: "\u{00A0}· ")
    }
}

// MARK: - Details

/// A place's details in the Map's panel (design §4.7): Mimo's why, Make this my
/// place, Preview, Taxi card, Ask Mimo, then the same phrase cards and tips as
/// Nearby, generated on open and cached per place and hour.
///
/// Show mode (phrases, the taxi card) is presented from here with its own
/// `fullScreenCover`, as a view that may sit in a sheet must (`AppRouter.show`).
struct MapPlaceDetails: View {
    let place: MapPlace
    let model: MapHomeModel
    /// The list's centre, to borrow the situation's city for places near it.
    let anchor: Coordinate?
    let onMakeCurrent: (MapPlace, PlaceArea?) -> Void

    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(APIStore.self) private var apiStore
    @Environment(AppRouter.self) private var router
    @Environment(\.ryokoAPI) private var api
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true

    @State private var area: PlaceArea?
    @State private var areaChecked = false
    @State private var load: DetailsCardLoad = .loading
    @State private var attempt = 0
    @State private var isPickingTime = false
    @State private var showContent: ShowContent?
    @State private var isPreparingTaxi = false

    var body: some View {
        let situation = area.map(detailsSituation)
        // Keyed by place, hour and profile, not by the second-stamped situation,
        // so re-renders don't restart a slow request.
        let cardTask = situation.map { CardTask(key: cardKey(for: $0), attempt: attempt) }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                if let why = place.why {
                    whyLine(why)
                }
                actions(situation: situation)
                if case .droppedPin = place.source {} else if let address = place.place.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                cardSection(situation: situation)
            }
            .pageMargins()
            .padding(.top, Theme.grid / 2)
            .padding(.bottom, Theme.grid * 3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: place) {
            area = await model.area(for: place, situation: situationStore.situation, anchor: anchor)
            areaChecked = true
        }
        .task(id: cardTask) {
            guard let cardTask, let area else { return }
            await loadCard(cardTask, situation: detailsSituation(area: area))
        }
        .sheet(isPresented: $isPickingTime) {
            if let situation {
                PreviewTimeSheet(situation: previewSeed(from: situation))
            }
        }
        .fullScreenCover(item: $showContent) { content in
            ShowModeView(content: content)
        }
        .sensoryFeedback(.impact, trigger: showContent?.id) { _, new in new != nil }
        #if DEBUG
        .task(id: area) { await runDebugAction(situation: area.map(detailsSituation)) }
        #endif
    }

    #if DEBUG
    /// `-RyokoMapDetailsAction`: presses one button, once the card has loaded.
    private func runDebugAction(situation: Situation?) async {
        guard let situation, let action = model.debugDetailsAction else { return }
        for _ in 0..<40 {
            if case .loading = load { try? await Task.sleep(for: .milliseconds(250)) } else { break }
        }
        model.debugDetailsAction = nil
        switch action {
        case "preview": isPickingTime = true
        case "taxi": await openTaxiCard(situation: situation)
        case "current": onMakeCurrent(place, area)
        case "mimo": router.askMimo(about: place.place)
        default: break
        }
    }
    #endif

    // MARK: Why

    private func whyLine(_ why: String) -> some View {
        Label {
            Text(why)
        } icon: {
            Image(systemName: "bubble.left")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .accessibilityLabel("Mimo: \(why)")
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(situation: Situation?) -> some View {
        VStack(spacing: Theme.grid * 1.5) {
            Button {
                onMakeCurrent(place, area)
            } label: {
                Label("Make this my place", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
                    // The tint is the label colour (white in dark mode), so the
                    // text takes the background colour to stay readable.
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Theme.grid))
                : AnyLayout(HStackLayout(spacing: Theme.grid))
            layout {
                actionButton("Preview", systemImage: "calendar.badge.clock") {
                    isPickingTime = true
                }
                .disabled(situation == nil)
                .accessibilityHint("Pick a date and time to see this place then")

                actionButton("Taxi card", systemImage: "car.fill", isBusy: isPreparingTaxi) {
                    Task { await openTaxiCard(situation: situation) }
                }
                .disabled(situation == nil || isPreparingTaxi)

                actionButton("Ask Mimo", systemImage: "bubble.left") {
                    router.askMimo(about: place.place)
                }
                .accessibilityLabel("Ask Mimo about this place")
            }
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.grid / 2) {
                ZStack {
                    Image(systemName: systemImage)
                        .opacity(isBusy ? 0 : 1)
                    if isBusy { ProgressView() }
                }
                .font(.title3)
                .frame(height: 28)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.grid / 2)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }

    // MARK: Card

    @ViewBuilder
    private func cardSection(situation: Situation?) -> some View {
        if areaChecked, situation == nil {
            Text("Can't tell which city this is in, so there's nothing to say here yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            switch load {
            case .loading:
                cards(.placeholder, showsRomanization: true)
                    .redacted(reason: .placeholder)
                    .accessibilityLabel("Loading phrases")
            case let .loaded(card):
                cards(card, showsRomanization: showsRomanization)
            case let .failed(message):
                VStack(alignment: .leading, spacing: Theme.grid) {
                    Label("Can't load phrases", systemImage: "exclamationmark.bubble")
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Try again") { attempt += 1 }
                        .buttonStyle(.bordered)
                }
                .cardSurface()
            }
        }
    }

    @ViewBuilder
    private func cards(_ card: PlaceCardResponse, showsRomanization: Bool) -> some View {
        if !card.phrases.isEmpty, !speaksLocalLanguage(card.language) {
            Text("What to say")
                .font(.headline)
                .padding(.top, Theme.grid)
                .accessibilityAddTraits(.isHeader)
            ForEach(card.phrases) { phrase in
                PhraseCardView(phrase: phrase, showsRomanization: showsRomanization) {
                    showContent = .phrase(phrase)
                }
            }
        }
        if !card.tips.isEmpty {
            VStack(alignment: .leading, spacing: Theme.grid * 2) {
                Text("Tips")
                    .font(.headline)
                ForEach(card.tips, id: \.text) { tip in
                    TipRow(tip: tip)
                }
            }
            .cardSurface()
        }
    }

    /// Design §4.3: no phrase cards where the local language is one you speak.
    private func speaksLocalLanguage(_ tag: String) -> Bool {
        let profile = profileStore.profile
        let spoken = (profile.spokenLanguages ?? []) + [profile.homeLanguage]
        let primary = { (code: String) in code.split(separator: "-").first.map(String.init)?.lowercased() ?? code }
        return spoken.contains { primary($0) == primary(tag) }
    }

    // MARK: Loading

    private struct CardTask: Hashable {
        var key: MapHomeModel.CardKey
        var attempt: Int
    }

    private func cardKey(for situation: Situation) -> MapHomeModel.CardKey {
        MapHomeModel.CardKey(
            place: place.id,
            hourBucket: situation.hourBucket,
            mode: situation.mode,
            localLanguage: situation.localLanguage,
            profileVersion: profileStore.profile.version,
            apiGeneration: apiStore.apiGeneration
        )
    }

    private func loadCard(_ task: CardTask, situation: Situation) async {
        if let cached = model.cachedCard(task.key) {
            load = .loaded(cached)
            return
        }
        load = .loading
        do {
            // Send the actual local time, not the hour the key was built in.
            let request = PlaceCardRequest(profile: profileStore.profile, situation: situation.stamped())
            let card = try await api.placeCard(request)
            model.storeCard(card, for: task.key)
            load = .loaded(card)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            load = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
        }
    }

    // MARK: Situations

    /// The situation the place card is written for: the active one when this
    /// is the current place, otherwise this place now (live) or at the
    /// preview's committed time (previewing).
    private func detailsSituation(area: PlaceArea) -> Situation {
        let active = situationStore.situation
        if let active, let current = active.place, MapPlace.key(for: current) == place.id {
            return active
        }
        let zone = place.timeZone ?? area.timeZone ?? active?.zone ?? .current
        let previewDate = active?.mode == .preview ? active?.date : nil
        return Situation(
            mode: previewDate == nil ? .live : .preview,
            date: previewDate ?? .now,
            timeZone: zone,
            place: place.place,
            city: area.city,
            district: area.district,
            countryCode: area.countryCode,
            localLanguage: LocalLanguage.forRegion(area.countryCode, subdivision: area.subdivision).tag
        )
    }

    /// What `PreviewTimeSheet` starts from: this place, at the active
    /// preview's time or now. Its Preview button starts the preview in the store.
    private func previewSeed(from situation: Situation) -> Situation {
        var seed = situation
        seed.mode = .preview
        return seed
    }

    // MARK: Taxi

    private func openTaxiCard(situation: Situation?) async {
        guard let situation else { return }
        isPreparingTaxi = true
        defer { isPreparingTaxi = false }
        // The place's own local-script name (MapKit's, or the one Mimo gave
        // with a pick) first; otherwise the place card's.
        var placeNameLocal = place.place.localName
        if placeNameLocal == nil, case let .loaded(card) = load { placeNameLocal = card.placeNameLocal }
        let card = await TaxiCardFactory.card(
            for: place.place,
            language: situation.localLanguage,
            placeNameLocal: placeNameLocal
        )
        showContent = .taxi(card)
    }
}

private enum DetailsCardLoad {
    case loading
    case loaded(PlaceCardResponse)
    case failed(String)
}

private extension PlaceCardResponse {
    /// Shape-only content for the `.redacted` loading state.
    static let placeholder = PlaceCardResponse(
        language: "en",
        phrases: (1...2).map { index in
            Phrase(
                id: "map-placeholder-\(index)",
                lang: "en",
                local: "A phrase to say here",
                romanization: "How it sounds, spelled out",
                gloss: "What it means in your language",
                because: "Because of something about you",
                basis: nil
            )
        },
        tips: [Tip(text: "A short tip about how things work at this place.", basis: [])],
        placeNameLocal: nil,
        addressLocal: nil,
        generatedAt: ""
    )
}

// MARK: - Search results

/// Places matching a submitted search. A row opens that place's details.
struct MapSearchResultsList: View {
    let results: [MapPlace]
    let languageTag: String?
    let onDetails: (MapPlace) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if results.isEmpty {
                    Text("No places found. Try another name, in English or the local script.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.margin)
                        .padding(.vertical, Theme.grid)
                }
                ForEach(results) { place in
                    MapPlaceRow(
                        place: place,
                        languageTag: languageTag,
                        selectHint: "Shows this place's details",
                        onSelect: { onDetails(place) },
                        onDetails: { onDetails(place) }
                    )
                    Divider()
                        .padding(.leading, Theme.margin + MapPlaceRow.iconColumn + Theme.grid * 1.5)
                }
            }
            .padding(.bottom, Theme.grid * 2)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// "Results for “ramen”" with Back to the list.
struct MapResultsHeader: View {
    let query: String
    let count: Int
    let onBack: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.grid * 1.5) {
            Button("Back", systemImage: "chevron.backward", action: onBack)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Back to the list")
            VStack(alignment: .leading, spacing: 2) {
                Text("Results for \u{201C}\(query)\u{201D}")
                    .font(.headline)
                Text(count == 1 ? "1 place" : "\(count) places")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, Theme.grid * 1.5)
    }
}
