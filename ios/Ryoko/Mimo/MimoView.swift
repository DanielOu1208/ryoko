import SwiftUI
import os

/// The Mimo tab (design §4.9): a chat with Mimo about places, phrases and plans.
///
/// Every message carries the profile, the active situation (re-stamped to
/// now), up to 20 nearby MapKit places and, after "Ask Mimo about this place",
/// the subject place. Replies stream in as text, phrase blocks (tap for Show
/// mode), place chips (tap for the Map, or Show on map) and sources.
struct MimoView: View {
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(AppRouter.self) private var router
    @Environment(\.ryokoAPI) private var api
    @Environment(\.placeResolver) private var resolver
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true

    @State private var chat: MimoChat
    @State private var draft = ""
    /// The places around `nearbyAnchor`, once MapKit has answered.
    @State private var nearby: [NearbyPlace]?
    /// Goes up each time Show mode opens, for the haptic.
    @State private var showCount = 0
    @FocusState private var isComposing: Bool
    #if DEBUG
    /// A segment to scroll to (`-RyokoMimoScrollTo places`).
    @State private var debugScrollTarget: String?
    #endif

    /// - Parameter chat: the conversation; the app's one saved chat by default.
    ///   SwiftUI re-runs this initializer often, so the default is a shared
    ///   instance rather than a new chat that reads the disk each time.
    init(chat: MimoChat? = nil) {
        _chat = State(initialValue: chat ?? .shared)
    }

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                transcript
                    .navigationTitle("Mimo")
                    .mimoSubtitle(dynamicTypeSize.isAccessibilitySize ? nil : subtitle(at: context.date))
            }
            .background(Theme.pageBackground)
            .safeAreaBar(edge: .top) { subjectBar }
            .safeAreaBar(edge: .bottom) { composer }
            .toolbar {
                if !chat.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        MimoAvatarView(mood: avatarMood, size: 30)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil", action: startNewChat)
                        .disabled(chat.isEmpty && router.mimoSubject == nil)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: showCount)
        .task(id: nearbyAnchor) {
            nearby = nil
            guard let anchor = nearbyAnchor else { return }
            let places = await MimoNearby.places(around: anchor)
            if !Task.isCancelled { nearby = places }
        }
        .task {
            situationStore.startLiveIfAuthorized()
            chat.resumeLookups(resolver: resolver)
            #if DEBUG
            await MimoDebug.run(on: self.debugActions)
            #endif
        }
    }

    /// What the avatar shows (design §4.9): thinking while a tool runs or
    /// before any text arrives, talking while text streams, listening while you
    /// type, a brief happy beat after a reply, idle otherwise.
    private var avatarMood: MimoMood {
        if let turn = chat.turns.last, turn.isStreaming {
            return turn.toolLine != nil || turn.segments.isEmpty ? .thinking : .talking
        }
        if isComposing { return .listening }
        if let turn = chat.turns.last, case .done = turn.status { return .happy }
        return .idle
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.grid * 3) {
                    MimoIntro(mood: avatarMood)
                    if chat.isEmpty {
                        if situationStore.situation == nil {
                            noPlace
                        } else {
                            starters
                        }
                    }
                    ForEach(chat.turns) { turn in
                        MimoTurnView(
                            turn: turn,
                            showsRomanization: showsRomanization,
                            canRetry: chat.canSend && situationStore.situation != nil,
                            onShowPhrase: openShow,
                            onSelectPlace: openOnMap,
                            onShowOnMap: showOnMap,
                            onRetry: { retry(turn.id) }
                        )
                        .id(turn.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .accessibilityHidden(true)
                }
                .pageMargins()
                .padding(.vertical, Theme.grid * 2)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(chat.isEmpty ? .top : .bottom, for: .initialOffset)
            #if DEBUG
            .onChange(of: debugScrollTarget) {
                guard let debugScrollTarget else { return }
                proxy.scrollTo(debugScrollTarget, anchor: .top)
            }
            #endif
            // Follow the reply as it streams in, and as its places are found.
            .onChange(of: chat.turns.last) { old, new in
                guard let new else { return }
                let isNewTurn = old?.id != new.id
                withAnimation(isNewTurn ? .smooth : nil) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomID = "mimo-bottom"

    /// Starter questions for the current place's category (design §4.9): fixed
    /// templates, no model call.
    private var starters: some View {
        VStack(alignment: .leading, spacing: Theme.grid) {
            Text("You could ask")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(MimoStarters.list(for: starterCategory, situation: situationStore.situation), id: \.self) { starter in
                Button {
                    send(starter)
                } label: {
                    Text(starter)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(!chat.canSend)
            }
        }
    }

    /// No place or city yet: Mimo needs to know where you are.
    private var noPlace: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
            Text("Where are you?")
                .font(.headline)
            Text("Pick a place on the map so I know where you are, then ask me anything about it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Map", systemImage: "map") { router.selectedTab = .map }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .cardSurface()
    }

    // MARK: Subject and composer

    /// "Ask Mimo about this place" (design §4.9): the subject rides along with
    /// every message until it's closed or a new chat starts.
    @ViewBuilder
    private var subjectBar: some View {
        if let subject = router.mimoSubject {
            MimoSubjectChip(place: subject) { router.mimoSubject = nil }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pageMargins()
                .padding(.bottom, Theme.grid)
        }
    }

    private var composer: some View {
        MimoComposer(
            draft: $draft,
            isComposing: $isComposing,
            isReplying: chat.isReplying,
            canSend: chat.canSend && situationStore.situation != nil,
            onSend: { send(draft) },
            onStop: { chat.stop() }
        )
        .pageMargins()
        .padding(.bottom, Theme.grid)
    }

    // MARK: Actions

    private func send(_ text: String) {
        guard let context = sendContext() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, chat.canSend else { return }
        chat.send(trimmed, context: context)
        if text == draft { draft = "" }
    }

    private func retry(_ turnID: UUID) {
        guard let context = sendContext() else { return }
        chat.retry(turnID, context: context)
    }

    private func startNewChat() {
        chat.newChat()
        draft = ""
        // A new chat drops the subject and the Map's From Mimo layer (design §4.7, §4.9).
        router.mimoSubject = nil
        router.clearFromMimo()
    }

    /// A phrase block opens Show mode (design §6.2).
    private func openShow(_ phrase: Phrase) {
        router.show = .phrase(phrase)
        showCount += 1
        RyokoLog.mimo.info("router.show = .phrase(\(phrase.id, privacy: .public)) \(phrase.lang, privacy: .public)")
    }

    /// A place chip opens the Map on that place, selected.
    private func openOnMap(_ place: MimoFoundPlace) {
        router.openMap(selecting: place.place)
        RyokoLog.mimo.info("router.openMap(selecting: \(place.place.name, privacy: .public)) → tab \(router.selectedTab.rawValue, privacy: .public)")
    }

    /// "Show on map": the From Mimo layer, numbered for a plan.
    private func showOnMap(_ places: MimoPlaces) {
        let pins = places.pins
        guard !pins.isEmpty else { return }
        router.showOnMap(pins)
        RyokoLog.mimo.info(
            "router.showOnMap(\(pins.count) pins, plan: \(pins.isPlan)) → fromMimo \(router.fromMimo.count), tab \(router.selectedTab.rawValue, privacy: .public): \(pins.map(\.shown.name).joined(separator: ", "), privacy: .public)"
        )
    }

    // MARK: Context

    /// Everything a message carries, or nil while no situation is known.
    private func sendContext() -> MimoSendContext? {
        guard let situation = situationStore.currentSituation() else { return nil }
        return MimoSendContext(
            api: effectiveAPI,
            resolver: resolver,
            profile: profileStore.profile,
            situation: situation,
            nearby: nearby,
            subjectPlace: router.mimoSubject,
            anchor: router.mimoSubject?.coordinate ?? situation.place?.coordinate ?? situationStore.lastFix
        )
    }

    private var effectiveAPI: any RyokoAPI {
        #if DEBUG
        if let scripted = MimoDebug.scriptedAPI { return scripted }
        #endif
        return api
    }

    /// Where nearby places are looked up: the active place, or the last fix in
    /// city-only live mode.
    private var nearbyAnchor: Coordinate? {
        situationStore.situation?.place?.coordinate ?? situationStore.lastFix
    }

    /// Starters follow the subject place when there is one, else the active place.
    private var starterCategory: CategorySlug {
        router.mimoSubject?.category ?? situationStore.situation?.place?.category ?? .other
    }

    /// "Menya Kaze · 8:00 PM", in the place's time zone.
    private func subtitle(at date: Date) -> String? {
        guard let situation = situationStore.situation else { return nil }
        let clocked = situation.stamped(at: date)
        let name = situation.place?.name ?? situation.city
        guard let instant = clocked.date, let zone = clocked.zone else { return name }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return "\(name) · \(instant.formatted(style))"
    }
}

// MARK: - DEBUG hooks

#if DEBUG
extension MimoView {
    /// What the DEBUG launch hooks can do to this view (see `MimoDebug`).
    var debugActions: MimoDebug.Actions {
        MimoDebug.Actions(
            situationStore: situationStore,
            router: router,
            chat: chat,
            hasNearby: { nearby != nil },
            send: { send($0) },
            setDraft: { draft = $0 },
            scrollTo: { debugScrollTarget = $0 },
            starters: { MimoStarters.list(for: starterCategory, situation: situationStore.situation) },
            openShow: openShow,
            openOnMap: openOnMap,
            showOnMap: showOnMap
        )
    }
}
#endif

// MARK: - Pieces

/// The top of the conversation: Mimo's avatar (design §4.9) and a one-line intro.
private struct MimoIntro: View {
    var mood: MimoMood
    @ScaledMetric(relativeTo: .title) private var avatarSize: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
            MimoAvatarView(mood: mood, size: min(avatarSize, 88))
            Text("Ask me what to order, how to say it, or where to go next.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The subject place, with a close button.
private struct MimoSubjectChip: View {
    let place: Place
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: Theme.grid) {
            Image(systemName: place.category.sfSymbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("About \(place.name)")
                .lineLimit(2)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .padding(Theme.grid / 2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Stop asking about \(place.name)")
        }
        .font(.subheadline)
        .padding(.leading, Theme.grid * 2)
        .padding(.trailing, Theme.grid)
        .padding(.vertical, Theme.grid)
        .glassEffect(.regular, in: .capsule)
    }
}

/// The text field with Send, or Stop while a reply streams.
private struct MimoComposer: View {
    @Binding var draft: String
    var isComposing: FocusState<Bool>.Binding
    let isReplying: Bool
    let canSend: Bool
    var onSend: () -> Void
    var onStop: () -> Void

    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 36

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.grid) {
            TextField("Ask Mimo", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused(isComposing)
                .padding(.vertical, Theme.grid + 2)
                .padding(.leading, Theme.grid * 2)
                .onChange(of: draft) {
                    if draft.count > MimoFeature.messageLimit {
                        draft = String(draft.prefix(MimoFeature.messageLimit))
                    }
                }
            if isReplying {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.bold))
                        .frame(width: buttonSize, height: buttonSize)
                }
                .buttonStyle(.monochromeProminent)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Stop")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: buttonSize, height: buttonSize)
                }
                .buttonStyle(.monochromeProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend || !hasText)
                .accessibilityLabel("Send")
            }
        }
        .padding(Theme.grid / 2)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: buttonSize / 2 + Theme.grid / 2))
    }
}

private extension View {
    /// The navigation subtitle, when there is one.
    @ViewBuilder
    func mimoSubtitle(_ subtitle: String?) -> some View {
        if let subtitle {
            navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}

#Preview("Tokyo") {
    MimoView(chat: MimoChat(store: .inMemory))
        .environment(AppSituationStore.preview(Fixtures.tokyo))
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppRouter(selectedTab: .mimo))
}
