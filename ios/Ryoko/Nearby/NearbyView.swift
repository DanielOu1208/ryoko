import SwiftUI

/// The Nearby tab, minimal: it proves the pipeline from the active situation to
/// `api.placeCard` to phrase cards and tips over the time-of-day gradient.
/// W3 builds the real Nearby (design §4.3) on top of this.
struct NearbyView: View {
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            if let situation = situationStore.situation {
                NowSituationView(situation: situation)
            } else {
                NowNoSituationView()
            }
        }
        .task { situationStore.startLiveIfAuthorized() }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings with location turned on.
            if phase == .active { situationStore.startLiveIfAuthorized() }
        }
    }
}

// MARK: - With a situation

/// Header, preview banner, nearby places to confirm (live), phrases and tips.
private struct NowSituationView: View {
    let situation: Situation

    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(APIStore.self) private var apiStore
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
                    cardContent
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
    private var cardContent: some View {
        switch load {
        case .loading:
            CardSections(card: .placeholder, showsRomanization: true)
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading phrases")
        case let .loaded(card):
            CardSections(card: card, showsRomanization: showsRomanization)
        case let .failed(message):
            ContentUnavailableView {
                Label("Can't load phrases", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.bordered)
            }
            .cardSurface()
        }
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
        } catch is CancellationError {
            // A newer situation or profile took over.
        } catch {
            load = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
        }
    }

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
    case failed(String)
}

private struct CardKey: Equatable {
    var request: PlaceCardRequest
    var apiGeneration: Int
    var attempt: Int
}

/// Phrase cards, then tips in one solid card.
private struct CardSections: View {
    let card: PlaceCardResponse
    let showsRomanization: Bool

    var body: some View {
        ForEach(card.phrases) { phrase in
            PhraseCardView(phrase: phrase, showsRomanization: showsRomanization)
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
        }
        .cardSurface()
        .sensoryFeedback(.selection, trigger: situationStore.confirmedPlace)
    }
}

// MARK: - No situation yet

/// No place or city known: ask for location, or explain why there's none.
private struct NowNoSituationView: View {
    @Environment(AppSituationStore.self) private var situationStore
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
                sampleButton
            }
        case .idle, .ready:
            ContentUnavailableView {
                Label("Where are you?", systemImage: "location")
            } description: {
                Text("Ryoko uses your location to show what to say where you are.")
            } actions: {
                Button("Find places near me") { situationStore.refresh() }
                    .buttonStyle(.borderedProminent)
                sampleButton
            }
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
}

#Preview("No place yet") {
    NearbyView()
        .environment(AppSituationStore(usesLocation: false))
        .environment(ProfileStore.preview())
        .environment(APIStore())
}
