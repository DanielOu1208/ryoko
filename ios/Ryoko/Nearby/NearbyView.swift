import SwiftUI
import os

/// The Nearby tab (design §4.3): the place you're at, or previewing. Top to
/// bottom: the header, phrase cards with Show, one or two tips, the quick cards
/// (allergy, taxi) and a mini map, over the time-of-day gradient.
///
/// Special cases:
/// - **No place known:** "Where are you?" with a way to the Map. A city-only
///   live situation lists the nearest places to confirm and the city's tips.
/// - **The local language is one you speak:** no phrase cards, no quick cards;
///   the header, tips and a prominent Preview a place.
/// - **Loading** is `.redacted`; an **error** has Try again; when the load fails
///   and this place's card was saved before, that card shows, marked as saved.
struct NearbyView: View {
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            if let situation = situationStore.situation {
                NearbySituationView(situation: situation)
            } else {
                NearbyNoSituationView()
            }
        }
        .task {
            situationStore.startLiveIfAuthorized()
            #if DEBUG
            NearbyDebugOptions.applySamplePlace(to: situationStore)
            NearbyDebugOptions.runTemplateCheckOnce()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings with location turned on.
            if phase == .active { situationStore.startLiveIfAuthorized() }
        }
        #if DEBUG
        .modifier(NearbyDebugAPIOverride())
        #endif
    }

    /// Whether the profile speaks `language`: the home language or a spoken one,
    /// compared by primary subtag (`en-CA` speaks `en`; `zh-Hans` speaks `zh-Hant`).
    static func speaks(_ profile: Profile, language: String) -> Bool {
        let target = primarySubtag(language)
        return ([profile.homeLanguage] + (profile.spokenLanguages ?? [])).contains { primarySubtag($0) == target }
    }

    private static func primarySubtag(_ tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}

// MARK: - With a situation

/// Header, preview banner, nearby places to confirm (live), phrases, tips,
/// quick cards and the mini map.
private struct NearbySituationView: View {
    let situation: Situation

    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(APIStore.self) private var apiStore
    @Environment(AppRouter.self) private var router
    @Environment(\.ryokoAPI) private var api
    @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var load: CardLoad = .loading
    @State private var loadedKey: CardKey?
    @State private var attempt = 0
    @State private var isPickingTime = false

    var body: some View {
        let key = CardKey(
            request: PlaceCardRequest(profile: profileStore.profile, situation: situation),
            apiGeneration: apiStore.apiGeneration,
            attempt: attempt
        )
        // At accessibility sizes the one-line navigation subtitle would truncate
        // the local time, so the city and time move into the page, one per line.
        let clockInPage = dynamicTypeSize.isAccessibilitySize
        let speaksLocal = NearbyView.speaks(profileStore.profile, language: situation.localLanguage)
        // The header's clock ticks by the minute; `situation` itself only by the hour.
        TimelineView(.everyMinute) { context in
            let clocked = situation.stamped(at: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if clockInPage {
                        AreaClockLines(situation: clocked)
                    }
                    if situation.mode == .preview {
                        PreviewBanner(
                            situation: situation,
                            onChangeTime: { isPickingTime = true },
                            onBack: { situationStore.endPreview() }
                        )
                    }
                    header
                    if situation.mode == .live, situation.place == nil || situationStore.candidates.count > 1 {
                        NearbyPicker()
                    }
                    if speaksLocal {
                        SpeaksLocalCard(language: situation.localLanguage)
                    }
                    cardContent(showsPhrases: !speaksLocal && situation.place != nil)
                    if !speaksLocal {
                        NearbyQuickCards(
                            situation: situation,
                            placeNameLocal: load.card?.placeNameLocal,
                            cardSettled: load.isSettled
                        )
                        if let place = situation.place {
                            NearbyMiniMap(coordinate: place.coordinate, title: place.name, systemImage: place.category.sfSymbol)
                        } else if let fix = situationStore.lastFix {
                            NearbyMiniMap(coordinate: fix, title: situation.city, systemImage: "location")
                        }
                    }
                }
                .pageMargins()
                .padding(.top, Theme.grid)
                .padding(.bottom, Theme.grid * 4)
            }
            .debugLaunchScrollAnchor()
            .background {
                TimeOfDayGradient(date: situation.date ?? .now, timeZone: situation.zone ?? .current)
            }
            .navigationTitle(situation.place?.name ?? "Where are you?")
            .navigationSubtitle(ifPresent: clockInPage ? nil : Self.subtitle(for: clocked))
        }
        .toolbar {
            if situation.mode == .live {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Check again", systemImage: "arrow.clockwise") { situationStore.refresh() }
                        .disabled(situationStore.liveState.isBusy)
                }
            }
        }
        .sheet(isPresented: $isPickingTime) {
            PreviewTimeSheet(situation: situation)
        }
        .task(id: key) { await loadCard(key) }
    }

    // MARK: Header

    /// The local name and category side by side, or stacked when they don't fit
    /// on one line (large text, long names), so neither breaks mid-word.
    @ViewBuilder
    private var header: some View {
        if let place = situation.place {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.grid) { headerLines(place) }
                VStack(alignment: .leading, spacing: Theme.grid / 2) { headerLines(place) }
            }
        }
    }

    @ViewBuilder
    private func headerLines(_ place: Place) -> some View {
        if let localName = place.localName {
            LocalText(localName, languageTag: situation.localLanguage)
                .font(.title3.weight(.semibold))
        }
        Label(place.category.displayName, systemImage: place.category.sfSymbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: Card

    @ViewBuilder
    private func cardContent(showsPhrases: Bool) -> some View {
        switch load {
        case .loading:
            CardSections(card: .placeholder, showsPhrases: showsPhrases, showsRomanization: true)
                .redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(showsPhrases ? "Loading phrases" : "Loading tips")
        case let .loaded(card):
            CardSections(card: card, showsPhrases: showsPhrases, showsRomanization: showsRomanization, onShow: show)
        case let .saved(entry, message):
            SavedCardNotice(savedAt: entry.savedAt, message: message) { attempt += 1 }
            CardSections(card: entry.card, showsPhrases: showsPhrases, showsRomanization: showsRomanization, onShow: show)
        case let .failed(message):
            ContentUnavailableView {
                Label(showsPhrases ? "Can't load phrases" : "Can't load tips", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.bordered)
            }
            .cardSurface()
        }
    }

    /// Show mode for a phrase (design §4.4).
    private func show(_ phrase: Phrase) {
        router.show = .phrase(phrase)
    }

    private func loadCard(_ key: CardKey) async {
        if key == loadedKey, case .loaded = load { return }
        load = .loading
        // The key's situation is only as fresh as its hour: send the actual local time.
        var request = key.request
        request.situation = request.situation.stamped()
        do {
            let card = try await api.placeCard(request)
            load = .loaded(card)
            loadedKey = key
            PlaceCardCache.shared.save(card, for: key.request.situation)
            #if DEBUG
            runPhraseLaunchHook(card)
            #endif
        } catch is CancellationError {
            // A newer situation or profile took over.
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            RyokoLog.nearby.error("Place card failed: \(message, privacy: .public)")
            if let saved = PlaceCardCache.shared.entry(for: key.request.situation) {
                load = .saved(saved, message)
            } else {
                load = .failed(message)
            }
        }
    }

    #if DEBUG
    /// `-RyokoShow phrase`: open the first phrase in Show mode once.
    private func runPhraseLaunchHook(_ card: PlaceCardResponse) {
        guard ShowDebugOptions.showAtLaunch == .phrase, !NearbyDebugOptions.didRunShowHook,
              let phrase = card.phrases.first else { return }
        NearbyDebugOptions.didRunShowHook = true
        show(phrase)
    }
    #endif

    /// `Shinjuku, Tokyo · Tue 7:00 PM`, in the place's time zone.
    static func subtitle(for situation: Situation) -> String {
        let area = situation.nearbyAreaText
        guard let clock = situation.nearbyClockText else { return area }
        return "\(area) · \(clock)"
    }
}

/// The city and local time in the page, one per line, for accessibility text
/// sizes (where the navigation subtitle truncates). Each line wraps between words.
private struct AreaClockLines: View {
    let situation: Situation

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid / 2) {
            Text(situation.nearbyAreaText)
            if let clock = situation.nearbyClockText {
                Text(clock)
            }
        }
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The navigation subtitle, or none when `subtitle` is nil.
    @ViewBuilder
    func navigationSubtitle(ifPresent subtitle: String?) -> some View {
        if let subtitle {
            navigationSubtitle(subtitle)
        } else {
            self
        }
    }
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

    /// Done loading, one way or another.
    var isSettled: Bool {
        if case .loading = self { false } else { true }
    }
}

private struct CardKey: Equatable {
    var request: PlaceCardRequest
    var apiGeneration: Int
    var attempt: Int
}

/// Phrase cards (each with Show), then one or two tips in one solid card.
private struct CardSections: View {
    let card: PlaceCardResponse
    var showsPhrases = true
    let showsRomanization: Bool
    var onShow: ((Phrase) -> Void)?

    var body: some View {
        if showsPhrases {
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
                ForEach(card.tips.prefix(2), id: \.text) { tip in
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

/// The local language is one you speak (design §4.3): nothing to translate here.
private struct SpeaksLocalCard: View {
    let language: String

    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
            Text("You speak \(NearbyQuickCards.languageName(language)) here")
                .font(.headline)
            Text("No phrases needed. Preview a place abroad to see what to say there.")
                .foregroundStyle(.secondary)
            Button("Preview a place", systemImage: "map") { router.selectedTab = .map }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, Theme.grid / 2)
        }
        .cardSurface()
    }
}

private extension PlaceCardResponse {
    /// Shape-only content for the `.redacted` loading state.
    static let placeholder = PlaceCardResponse(
        language: "en",
        phrases: (1...2).map { index in
            Phrase(
                id: "placeholder-\(index)",
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

// MARK: - Nearby places (live)

/// The nearest places to confirm, closest first (design §4.2: one-tap confirm).
private struct NearbyPicker: View {
    @Environment(AppSituationStore.self) private var situationStore
    /// The icon column grows with the text.
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid) {
            Text(situationStore.confirmedPlace == nil ? "Pick the place you're at" : "Somewhere else?")
                .font(.headline)
            if situationStore.liveState.isBusy {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if situationStore.candidates.isEmpty {
                Text("No places within \(Int(NearbySearch.radiusMeters)) m.")
                    .foregroundStyle(.secondary)
            }
            ForEach(situationStore.candidates) { candidate in
                Button {
                    situationStore.confirm(candidate.place)
                } label: {
                    HStack(spacing: Theme.grid * 1.5) {
                        Image(systemName: candidate.place.category.sfSymbol)
                            .foregroundStyle(.secondary)
                            .frame(width: iconWidth)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.place.name)
                            Text("\(candidate.place.category.displayName) · \(Int(candidate.distanceMeters.rounded())) m")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if candidate.place == situationStore.confirmedPlace {
                            Image(systemName: "checkmark")
                                .accessibilityLabel("Confirmed")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, Theme.grid / 2)
            }
            if situationStore.confirmedPlace == nil {
                // The Map's sheet lists more places nearby (design §4.3).
                Button("Find it on the map", systemImage: "map") { router.selectedTab = .map }
                    .buttonStyle(.bordered)
                    .padding(.top, Theme.grid / 2)
            }
        }
        .cardSurface()
        .sensoryFeedback(.selection, trigger: situationStore.confirmedPlace)
    }
}

// MARK: - No situation yet

/// No place or city known: "Where are you?", with the Map (where a place can be
/// picked or previewed) and location.
private struct NearbyNoSituationView: View {
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .navigationTitle("Nearby")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch situationStore.liveState {
        case .locating, .searching:
            ProgressView("Finding places near you")
        case .denied:
            ContentUnavailableView {
                Label("Location is off", systemImage: "location.slash")
            } description: {
                Text("Turn on location for Ryoko in Settings, or preview a place from the map.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
                mapButton(prominent: false)
                sampleButton
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Can't find where you are", systemImage: "location.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { situationStore.refresh() }
                    .buttonStyle(.bordered)
                mapButton(prominent: false)
                sampleButton
            }
        case .idle, .ready:
            ContentUnavailableView {
                Label("Where are you?", systemImage: "location")
            } description: {
                Text("Pick a place on the map, or use your location, to see what to say there.")
            } actions: {
                mapButton(prominent: true)
                Button("Use my location") { situationStore.refresh() }
                    .buttonStyle(.bordered)
                sampleButton
            }
        }
    }

    /// Opens the Map, whose sheet lists the places nearby.
    @ViewBuilder
    private func mapButton(prominent: Bool) -> some View {
        let button = Button("Open the map") { router.selectedTab = .map }
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var sampleButton: some View {
        #if DEBUG
        Button("Preview a sample place") { situationStore.previewSample() }
            .buttonStyle(.bordered)
        #endif
    }
}

#Preview("Previewing Tokyo") {
    NearbyView()
        .environment(AppSituationStore.preview(Fixtures.tokyo))
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppRouter())
}

#Preview("No place yet") {
    NearbyView()
        .environment(AppSituationStore(usesLocation: false))
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppRouter())
}
