import MapKit
import SwiftUI
import os

// MARK: - Header

/// The card's header (design §4.7): the place's name, its local-script name,
/// "Ramen · 350 m · 7:04 PM" (the place's own local time), and a close button
/// that goes back to the list at the size it had.
struct MapPlaceCardHeader: View {
    let place: MapPlace
    let languageTag: String?
    /// The local-script name: MapKit's, or the place card's once it's loaded.
    let localName: String?
    let timeZone: TimeZone?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.grid * 1.5) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.title)
                    .font(.title2.bold())
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                if let shownLocalName, let languageTag {
                    LocalText(shownLocalName, languageTag: languageTag)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                TimelineView(.everyMinute) { context in
                    Text(detailLine(at: context.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
                .accessibilityHint("Back to the list")
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, Theme.grid * 1.5)
    }

    private var shownLocalName: String? {
        guard let localName, localName != place.title else { return nil }
        return localName
    }

    /// "Ramen · 350 m · 7:04 PM", or a dropped pin's address and time.
    private func detailLine(at date: Date) -> String {
        var parts: [String] = []
        if case .droppedPin = place.source {
            parts.append(place.place.address ?? "Finding the address")
        } else {
            parts.append(place.place.category.displayName)
            if let distance = place.distanceMeters { parts.append(MapDistanceText.text(distance)) }
        }
        if let timeZone {
            var style = Date.FormatStyle.dateTime.hour().minute()
            style.timeZone = timeZone
            parts.append(date.formatted(style).replacing(/\s/, with: "\u{00A0}"))
        }
        return parts.joined(separator: "\u{00A0}· ")
    }
}

// MARK: - Card

/// A place's card in the Map's sheet (design §4.7). Top to bottom:
///
/// 0. A wide photo of the place from Foursquare (`PlacePhotoStore`, shared
///    with the list's thumbnail), with "Powered by Foursquare" under it and,
///    when Apple has imagery there, a Look Around button on it. With no photo,
///    a wide Look Around preview of the street (`PlaceThumbnailLoader`'s
///    scene); tap it for the full-screen viewer. With neither there's nothing
///    extra: the map above already shows the place.
/// 1. Directions, Taxi, Allergy and Ask Mimo, as round buttons. Allergy shows
///    only when the profile has allergies the local language has a card for,
///    and you don't speak it.
/// 2. **I'm here** within about 300 m of your live location (it makes this
///    the current place), otherwise **Preview** with the date and time picker.
/// 3. Mimo's why, for picks and From Mimo places.
/// 4. What to say: phrase cards with their "because…" line and Show.
/// 5. Tips.
///
/// Where the local language is one you speak: no phrases and no Allergy, tips
/// only. Loading is `.redacted`; an error has Try again; a failed load falls
/// back to this place's saved card (`PlaceCardCache`), marked as saved.
///
/// The card never changes the situation by itself: only I'm here and Preview do.
struct MapPlaceCard: View {
    let place: MapPlace
    let model: MapHomeModel
    /// The list's centre, to borrow the situation's city for places near it.
    let anchor: Coordinate?
    /// "I'm here": make this the current (live) place.
    let onHere: (MapPlace, PlaceArea?) -> Void

    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(APIStore.self) private var apiStore
    @Environment(AppRouter.self) private var router
    @Environment(\.ryokoAPI) private var api
    @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true

    @State private var area: PlaceArea?
    @State private var areaChecked = false
    @State private var load: CardLoad = .loading
    @State private var attempt = 0
    @State private var isPickingTime = false
    @State private var isPreparingTaxi = false
    @State private var allergy = AllergyCardPresenter()
    @State private var showCount = 0
    @State private var lookAround: MKLookAroundScene?
    @State private var isLookingAround = false
    /// The header photo once it's loaded, or `.noPhoto` once it's known there isn't one.
    @State private var headerPhoto: HeaderPhoto = .checking
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let situation = area.map(cardSituation)
        // Keyed by place, hour and profile, not by the second-stamped situation,
        // so re-renders don't restart a slow request.
        let cardTask = situation.map { CardTask(key: cardKey(for: $0), attempt: attempt) }
        let speaksLocal = situation.map { profileStore.profile.speaks($0.localLanguage) } ?? false
        // From memory when the list's thumbnail already found it, so it's
        // there as the card opens.
        let scene = lookAround ?? PlaceThumbnailLoader.shared.cachedScene(for: place.place).flatMap(\.self)
        let photo = shownHeaderPhoto
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                switch photo {
                case let .photo(image):
                    photoHeader(image, scene: scene)
                case .noPhoto:
                    if let scene { lookAroundPreview(scene) }
                case .checking:
                    // Usually known already from the list's thumbnail.
                    EmptyView()
                }
                MapPlaceActions(actions: actions(situation: situation, speaksLocal: speaksLocal))
                    .padding(.top, Theme.grid / 2)
                hereOrPreview(situation: situation)
                if let why = place.why {
                    whyCard(why)
                }
                cardSection(situation: situation, speaksLocal: speaksLocal)
                if case .droppedPin = place.source {} else if let address = place.place.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.grid)
                }
            }
            .padding(.horizontal, MapListLayout.sideMargin)
            .padding(.bottom, Theme.grid * 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .debugLaunchScrollAnchor()
        .lookAroundViewer(isPresented: $isLookingAround, initialScene: scene)
        .task(id: place.id) {
            guard lookAround == nil, let found = await PlaceThumbnailLoader.shared.scene(for: place.place) else { return }
            withAnimation(.smooth(duration: 0.35)) { lookAround = found }
        }
        .task(id: place.id) { await loadHeaderPhoto() }
        .task(id: place) {
            let found = await model.area(for: place, situation: situationStore.situation, anchor: anchor)
            area = found
            areaChecked = true
            if model.details?.id == place.id, let found { model.detailsArea = found }
        }
        .task(id: cardTask) {
            guard let cardTask, let area else { return }
            await loadCard(cardTask, situation: cardSituation(area: area))
        }
        .sheet(isPresented: $isPickingTime) {
            if let situation {
                PreviewTimeSheet(situation: previewSeed(from: situation))
            }
        }
        .allergyCardFailureAlert(allergy)
        .sensoryFeedback(.impact, trigger: showCount)
        #if DEBUG
        .task(id: area) { await runDebugAction(situation: area.map(cardSituation)) }
        #endif
    }

    // MARK: Photo

    private enum HeaderPhoto {
        case checking
        case photo(UIImage)
        case noPhoto
    }

    static let headerHeight: CGFloat = 150
    /// Wide enough for the card on any iPhone; the image is cropped to the card.
    private static let headerPhotoSize = CGSize(width: 440, height: headerHeight)

    /// No photo is looked up for a dropped pin: it's an address, not a listing.
    private var wantsPhoto: Bool {
        if case .droppedPin = place.source { false } else { true }
    }

    /// `headerPhoto`, or what memory already knows, so a card opened from a
    /// row with a photo shows it at once.
    private var shownHeaderPhoto: HeaderPhoto {
        guard case .checking = headerPhoto else { return headerPhoto }
        guard wantsPhoto else { return .noPhoto }
        switch PlacePhotoStore.shared.answer(for: place.place, api: api) {
        case .noPhoto: return .noPhoto
        case let .photo(url):
            let image = PlacePhotoImages.shared.cachedImage(at: url, filling: Self.headerPhotoSize, scale: displayScale)
            return image.map(HeaderPhoto.photo) ?? .checking
        case nil: return .checking
        }
    }

    private func loadHeaderPhoto() async {
        guard wantsPhoto else {
            headerPhoto = .noPhoto
            return
        }
        if case .photo = shownHeaderPhoto {
            // Kept, so the image stays if memory lets it go.
            headerPhoto = shownHeaderPhoto
            return
        }
        guard let url = await PlacePhotoStore.shared.url(for: place.place, api: api) else {
            if !Task.isCancelled { headerPhoto = .noPhoto }
            return
        }
        let image = await PlacePhotoImages.shared.image(at: url, filling: Self.headerPhotoSize, scale: displayScale)
        guard !Task.isCancelled else { return }
        withAnimation(.smooth(duration: 0.35)) {
            headerPhoto = image.map(HeaderPhoto.photo) ?? .noPhoto
        }
    }

    /// The place's photo, cropped to the card's width, with a Look Around
    /// button when Apple has imagery there and the credit Foursquare's terms
    /// ask for. The photo itself is decorative.
    private func photoHeader(_ image: UIImage, scene: MKLookAroundScene?) -> some View {
        VStack(alignment: .trailing, spacing: Theme.grid / 2) {
            Color.clear
                .frame(height: Self.headerHeight)
                .frame(maxWidth: .infinity)
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                }
                .clipShape(Theme.cardShape)
                .overlay(alignment: .bottomTrailing) {
                    if scene != nil {
                        Button("Look Around", systemImage: "binoculars.fill") {
                            isLookingAround = true
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(.primary)
                        .padding(Theme.grid)
                        .accessibilityHint("Opens the street-level view of this place")
                        .transition(.opacity)
                    }
                }
            Text("Powered by Foursquare")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.trailing, Theme.grid)
        }
        .transition(.opacity)
    }

    // MARK: Look Around

    /// The street in front of the place, not interactive itself: a tap opens
    /// the full viewer.
    private func lookAroundPreview(_ scene: MKLookAroundScene) -> some View {
        Button {
            isLookingAround = true
        } label: {
            LookAroundPreview(initialScene: scene, allowsNavigation: false, badgePosition: .bottomTrailing)
                .allowsHitTesting(false)
                .frame(height: Self.headerHeight)
                .clipShape(Theme.cardShape)
                .contentShape(Theme.cardShape)
        }
        .buttonStyle(MapRowButtonStyle())
        .transition(.opacity)
        .accessibilityLabel("Look Around")
        .accessibilityHint("Opens the street-level view of this place")
    }

    // MARK: Actions

    private func actions(situation: Situation?, speaksLocal: Bool) -> [MapPlaceActions.Action] {
        var actions: [MapPlaceActions.Action] = [
            .init(title: "Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                  hint: "Opens Apple Maps with directions here") {
                Task { await MapDirections.open(place) }
            },
            .init(title: "Taxi", systemImage: "car.fill", isBusy: isPreparingTaxi, isEnabled: situation != nil,
                  hint: "Opens the address in the local language, full screen, to show a driver") {
                Task { await openTaxiCard(situation: situation) }
            },
        ]
        if let language = situation?.localLanguage, showsAllergy(language: language, speaksLocal: speaksLocal) {
            actions.append(.init(title: "Allergy", systemImage: "allergens", isBusy: allergy.isLoading,
                                 hint: "Opens your allergy card in the local language, full screen") {
                openAllergyCard(language: language)
            })
        }
        actions.append(.init(title: "Ask Mimo", systemImage: "bubble.left", hint: "Asks Mimo about this place") {
            router.askMimo(about: place.place)
        })
        return actions
    }

    /// Only when the profile has allergies, the local language has a card,
    /// and it isn't a language you speak.
    private func showsAllergy(language: String, speaksLocal: Bool) -> Bool {
        !speaksLocal && AllergyCardStore.unavailability(profile: profileStore.profile, language: language) == nil
    }

    // MARK: I'm here / Preview

    private enum HereState {
        /// This is your live place already.
        case current
        /// You're within about 300 m: offer "I'm here".
        case near
        /// Further away, or no fix: offer Preview (`previewing` when this
        /// place is being previewed now).
        case far(previewing: Bool)
    }

    private var hereState: HereState {
        let isPreviewing = situationStore.previewSituation != nil
        if !isPreviewing, let live = situationStore.liveSituation?.place, MapPlace.key(for: live) == place.id {
            return .current
        }
        if let fix = situationStore.lastFix, fix.mapDistance(to: place.place.coordinate) <= MapHome.hereRadius {
            return .near
        }
        let previewed = situationStore.previewSituation?.place.map { MapPlace.key(for: $0) == place.id } ?? false
        return .far(previewing: previewed)
    }

    @ViewBuilder
    private func hereOrPreview(situation: Situation?) -> some View {
        switch hereState {
        case .current:
            Label("You're here", systemImage: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .accessibilityLabel("This is your place")
        case .near:
            Button {
                onHere(place, area)
            } label: {
                Label("I'm here", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.monochromeProminent)
            .controlSize(.large)
            .disabled(area == nil && !areaChecked)
            .accessibilityHint("Makes this your place")
        case let .far(previewing):
            if previewing, let clock = situationStore.previewSituation?.mapClockText() {
                Button {
                    isPickingTime = true
                } label: {
                    Label("Previewing \(clock)", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(situation == nil)
                .accessibilityHint("Pick another date and time")
            } else {
                Button {
                    isPickingTime = true
                } label: {
                    Label("Preview", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.monochromeProminent)
                .controlSize(.large)
                .disabled(situation == nil)
                .accessibilityHint("Pick a date and time to see this place then")
            }
        }
    }

    // MARK: Why

    private func whyCard(_ why: String) -> some View {
        HStack(alignment: .top, spacing: Theme.grid * 1.5) {
            MimoAvatarView(mood: .idle, size: 30)
            VStack(alignment: .leading, spacing: Theme.grid / 2) {
                Text(why)
                    .font(.body)
                if case let .pick(_, bestTime?) = place.source {
                    Text("Best time: \(bestTime)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardSurface(padding: Theme.grid * 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mimo: \(why)")
    }

    // MARK: Card

    @ViewBuilder
    private func cardSection(situation: Situation?, speaksLocal: Bool) -> some View {
        if areaChecked, situation == nil {
            Text("Can't tell which city this is in, so there's nothing to say here yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .cardSurface()
        } else {
            switch load {
            case .loading:
                MapCardSections(card: .placeholder, showsPhrases: !speaksLocal, showsRomanization: true)
                    .redacted(reason: .placeholder)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(speaksLocal ? "Loading tips" : "Loading phrases")
            case let .loaded(card):
                MapCardSections(card: card, showsPhrases: !speaksLocal, showsRomanization: showsRomanization, onShow: show)
            case let .saved(entry, message):
                SavedCardNotice(savedAt: entry.savedAt, message: message) { attempt += 1 }
                MapCardSections(card: entry.card, showsPhrases: !speaksLocal, showsRomanization: showsRomanization, onShow: show)
            case let .failed(message):
                VStack(alignment: .leading, spacing: Theme.grid) {
                    Label(speaksLocal ? "Can't load tips" : "Can't load phrases", systemImage: "exclamationmark.bubble")
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Try again") { attempt += 1 }
                        .buttonStyle(.bordered)
                        .padding(.top, Theme.grid / 2)
                }
                .cardSurface()
            }
        }
    }

    /// Show mode for a phrase (design §4.4). The sheet is a panel in the tab,
    /// so the root presents it.
    private func show(_ phrase: Phrase) {
        router.show = .phrase(phrase)
        showCount += 1
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
        if task.attempt == 0, let cached = model.cachedCard(task.key) {
            loaded(cached)
            return
        }
        load = .loading
        do {
            // Send the actual local time, not the hour the key was built in.
            let request = PlaceCardRequest(profile: profileStore.profile, situation: situation.stamped())
            let card = try await api.placeCard(request)
            model.storeCard(card, for: task.key)
            PlaceCardCache.shared.save(card, for: situation)
            loaded(card)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            RyokoLog.placeCards.error("Place card failed: \(message, privacy: .public)")
            if let saved = PlaceCardCache.shared.entry(for: situation) {
                load = .saved(saved, message)
                shareLocalName(saved.card)
            } else {
                load = .failed(message)
            }
        }
    }

    private func loaded(_ card: PlaceCardResponse) {
        load = .loaded(card)
        shareLocalName(card)
    }

    /// The header shows the place card's local-script name when MapKit has none.
    private func shareLocalName(_ card: PlaceCardResponse) {
        guard model.details?.id == place.id, place.place.localName == nil else { return }
        model.detailsLocalName = card.placeNameLocal
    }

    // MARK: Situations

    /// The situation the place card is written for: the active one when this
    /// is the current place, otherwise this place now (live) or at the
    /// preview's committed time (previewing).
    private func cardSituation(area: PlaceArea) -> Situation {
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

    // MARK: Taxi and allergy

    private func openTaxiCard(situation: Situation?) async {
        guard let situation, !isPreparingTaxi else { return }
        isPreparingTaxi = true
        defer { isPreparingTaxi = false }
        // The place's own local-script name (MapKit's, or the one Mimo gave
        // with a pick) first; otherwise the place card's.
        let placeNameLocal = place.place.localName ?? load.card?.placeNameLocal
        let card = await TaxiCardFactory.card(
            for: place.place,
            language: situation.localLanguage,
            placeNameLocal: placeNameLocal
        )
        router.show = .taxi(card)
        showCount += 1
    }

    private func openAllergyCard(language: String) {
        allergy.present(profile: profileStore.profile, language: language, api: api, router: router)
        showCount += 1
    }

    // MARK: DEBUG

    #if DEBUG
    /// `-RyokoMapCardAction`: presses one button, once the card has loaded.
    private func runDebugAction(situation: Situation?) async {
        guard let situation, let action = model.debugCardAction else { return }
        for _ in 0..<60 {
            if case .loading = load { try? await Task.sleep(for: .milliseconds(250)) } else { break }
        }
        model.debugCardAction = nil
        RyokoLog.places.info("Debug: card action \(action, privacy: .public)")
        switch action {
        case "preview": isPickingTime = true
        case "taxi": await openTaxiCard(situation: situation)
        case "allergy": openAllergyCard(language: situation.localLanguage)
        case "phrase": if let phrase = load.card?.phrases.first { show(phrase) }
        case "here", "current": onHere(place, area)
        case "mimo": router.askMimo(about: place.place)
        case "directions": await MapDirections.open(place)
        case "lookaround":
            for _ in 0..<40 where lookAround == nil { try? await Task.sleep(for: .milliseconds(250)) }
            isLookingAround = lookAround != nil
        case "close":
            try? await Task.sleep(for: .seconds(1.5))
            model.back()
        default: break
        }
    }
    #endif
}

private enum CardLoad {
    case loading
    case loaded(PlaceCardResponse)
    /// The load failed; this place's card from an earlier visit, with why.
    case saved(PlaceCardCache.Entry, String)
    case failed(String)

    /// The card on screen, fresh or saved.
    var card: PlaceCardResponse? {
        switch self {
        case let .loaded(card): card
        case let .saved(entry, _): entry.card
        case .loading, .failed: nil
        }
    }
}

// MARK: - Sections

/// "What to say" (phrase cards, each with Show) and the tips, in one solid card.
private struct MapCardSections: View {
    let card: PlaceCardResponse
    var showsPhrases = true
    let showsRomanization: Bool
    var onShow: ((Phrase) -> Void)?

    var body: some View {
        if showsPhrases, !card.phrases.isEmpty {
            Text("What to say")
                .font(.headline)
                .padding(.horizontal, Theme.grid)
                .padding(.top, Theme.grid)
                .accessibilityAddTraits(.isHeader)
            ForEach(card.phrases) { phrase in
                PhraseCardView(
                    phrase: phrase,
                    showsRomanization: showsRomanization,
                    onShow: onShow.map { show in { show(phrase) } }
                )
            }
        }
        if !card.tips.isEmpty {
            VStack(alignment: .leading, spacing: Theme.grid * 2) {
                Text("Tips")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(card.tips, id: \.text) { tip in
                    TipRow(tip: tip)
                }
            }
            .cardSurface()
        }
    }
}

/// The load failed but this place's card was saved earlier: say so, with
/// when it was saved, and offer Try again.
private struct SavedCardNotice: View {
    let savedAt: Date
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid) {
            Label("Saved card", systemImage: "icloud.slash")
                .font(.headline)
            Text("\(message) This is the card saved \(savedAt, format: .relative(presentation: .named)).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .padding(.top, Theme.grid / 2)
        }
        .cardSurface()
        .accessibilityElement(children: .contain)
    }
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
