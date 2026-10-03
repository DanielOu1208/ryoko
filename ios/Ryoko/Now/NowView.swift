import SwiftUI

/// The Now tab, minimal: it proves the pipeline from the active situation to
/// `api.placeCard` to phrase cards and tips over the time-of-day gradient.
/// W3 builds the real Now (design §4.3) on top of this.
struct NowView: View {
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

    @State private var load: CardLoad = .loading
    @State private var loadedKey: CardKey?
    @State private var attempt = 0

    var body: some View {
        let key = CardKey(
            request: PlaceCardRequest(profile: profileStore.profile, situation: situation),
            apiGeneration: apiStore.apiGeneration,
            attempt: attempt
        )
        // The header's clock ticks by the minute; `situation` itself only by the hour.
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if situation.mode == .preview {
                        PreviewBanner(situation: situation) { situationStore.endPreview() }
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
            .navigationSubtitle(Self.subtitle(for: situation.stamped(at: context.date)))
        }
        .toolbar {
            if situation.mode == .live {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Check again", systemImage: "arrow.clockwise") { situationStore.refresh() }
                        .disabled(situationStore.liveState.isBusy)
                }
            }
        }
        .task(id: key) { await loadCard(key) }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let place = situation.place {
            HStack(spacing: Theme.grid) {
                if let localName = place.localName {
                    LocalText(localName, languageTag: situation.localLanguage)
                        .font(.title3.weight(.semibold))
                }
                Label(place.category.displayName, systemImage: place.category.sfSymbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
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
        let area = [situation.district, situation.city].compactMap(\.self).joined(separator: ", ")
        guard let date = situation.date, let zone = situation.zone else { return area }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = zone
        return "\(area) · \(date.formatted(style))"
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

// MARK: - Preview banner

/// "Previewing · Tue 7:00 PM" with "Back to here" (design §4.2).
private struct PreviewBanner: View {
    let situation: Situation
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: Theme.grid * 1.5) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Previewing · \(timeText)")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Back to here", action: onBack)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .cardSurface(padding: Theme.grid * 1.5)
    }

    private var timeText: String {
        guard let date = situation.date, let zone = situation.zone else { return situation.localTime }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }
}

// MARK: - Nearby places (live)

/// The nearest places to confirm, closest first (design §4.2: one-tap confirm).
private struct NearbyPicker: View {
    @Environment(AppSituationStore.self) private var situationStore

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
                            .frame(width: 28)
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
            .navigationTitle("Now")
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
    NowView()
        .environment(AppSituationStore.preview(Fixtures.tokyo))
        .environment(ProfileStore.preview())
        .environment(APIStore())
}

#Preview("No place yet") {
    NowView()
        .environment(AppSituationStore(usesLocation: false))
        .environment(ProfileStore.preview())
        .environment(APIStore())
}
