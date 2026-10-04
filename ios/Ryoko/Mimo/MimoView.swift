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

    @State private var chat: MimoChat
    @State private var draft = ""
    /// The places around `nearbyAnchor`, once MapKit has answered.
    @State private var nearby: [NearbyPlace]?
    /// Goes up each time Show mode opens, for the haptic.
    @State private var showCount = 0
    /// True for a moment after a reply finishes, so the avatar's happy beat
    /// plays even while the composer keeps focus.
    @State private var celebrating = false
    @State private var showsHistory = false
    /// How far a swipe has moved the chat while opening or closing the sidebar.
    @GestureState private var sidebarDrag: CGFloat = 0
    /// The saved chats, read when the sidebar opens.
    @State private var history: [MimoChatSummary] = []
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
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.7, 300)
            let offset = min(max((showsHistory ? width : 0) + sidebarDrag, 0), width)
            ZStack(alignment: .leading) {
                MimoHistorySidebar(
                    chats: history,
                    currentID: chat.isEmpty ? nil : chat.sessionId,
                    onOpen: openChat,
                    onNewChat: {
                        startNewChat()
                        showsHistory = false
                    },
                    onDelete: deleteChat
                )
                .frame(width: width)
                .accessibilityHidden(!showsHistory)

                chatScreen
                    .overlay {
                        // The chat dims as it slides aside; tap it to come back.
                        Color.black
                            .opacity(0.12 * offset / width)
                            .ignoresSafeArea()
                            .allowsHitTesting(showsHistory)
                            .onTapGesture { showsHistory = false }
                            .accessibilityHidden(true)
                    }
                    .offset(x: offset)
                    .simultaneousGesture(sidebarSwipe(width: width))

                // The sidebar fades gently into the chat instead of ending at a hard edge.
                LinearGradient(
                    colors: [MimoHistorySidebar.background, MimoHistorySidebar.background.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 48)
                .ignoresSafeArea()
                .offset(x: offset)
                .opacity(offset / width)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .animation(.smooth(duration: 0.3), value: showsHistory)
        .onChange(of: showsHistory, initial: true) { _, shows in
            guard shows else { return }
            isComposing = false
            history = chat.history()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: showCount)
        .onChange(of: chat.turns.last?.status) { old, new in
            guard old == .streaming, case .done = new else { return }
            celebrating = true
        }
        .task(id: celebrating) {
            guard celebrating else { return }
            try? await Task.sleep(for: .seconds(2.5))
            celebrating = false
        }
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
        if celebrating { return .happy }
        if isComposing { return .listening }
        return .idle
    }

    /// The chat itself: header, transcript and composer.
    private var chatScreen: some View {
        NavigationStack {
        transcript
            .background { SituationGradient() }
            .safeAreaBar(edge: .top) {
                VStack(spacing: Theme.grid) {
                    TimelineView(.everyMinute) { context in
                        header(at: context.date)
                    }
                    subjectBar
                }
            }
            .safeAreaBar(edge: .bottom) { composer }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Mimo")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Swipe right on the chat to open the sidebar, left to close it.
    private func sidebarSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($sidebarDrag) { value, drag, _ in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                drag = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                let projected = (showsHistory ? width : 0) + value.predictedEndTranslation.width
                showsHistory = projected > width / 2
            }
    }

    // MARK: Header

    /// Mimo centred at the top, as a contact in Messages: the animated avatar
    /// with its name and where you are under it. History on the left, New chat
    /// on the right.
    private func header(at date: Date) -> some View {
        HStack(alignment: .top) {
            MimoHeaderButton(title: "History", systemImage: "sidebar.leading") { showsHistory = true }
            Spacer(minLength: Theme.grid)
            // The pill tucks up under the avatar, whose canvas has room around the body.
            VStack(spacing: -Theme.grid) {
                MimoAvatarView(mood: avatarMood, size: 82)
                    .accessibilityHidden(true)
                // In a glass pill, like a contact's name in Messages, so it
                // stays readable over the chat scrolling under it.
                VStack(spacing: 0) {
                    Text("Mimo")
                        .font(.subheadline.weight(.semibold))
                    if !dynamicTypeSize.isAccessibilitySize, let subtitle = subtitle(at: date) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Theme.grid * 1.75)
                .padding(.vertical, Theme.grid / 2)
                .glassEffect(.regular, in: .capsule)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.grid)
            MimoHeaderButton(title: "New chat", systemImage: "square.and.pencil", action: startNewChat)
                .disabled(chat.isEmpty && router.mimoSubject == nil)
        }
        .pageMargins()
        // Up into the status bar's band, clear of the Dynamic Island, to leave the chat more room.
        .padding(.top, -Theme.grid * 1.5)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.grid * 3) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.topID)
                        .accessibilityHidden(true)
                    if chat.isEmpty {
                        MimoIntro()
                        if situationStore.situation == nil {
                            noPlace
                        } else {
                            starters
                        }
                    }
                    ForEach(chat.turns) { turn in
                        MimoTurnView(
                            turn: turn,
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
                .padding(.top, Theme.grid)
                .padding(.bottom, Theme.grid * 2)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(chat.isEmpty ? .top : .bottom, for: .initialOffset)
            // When the keyboard comes up, keep the end of the chat above the
            // composer instead of under its glass.
            .defaultScrollAnchor(chat.isEmpty ? .top : .bottom, for: .sizeChanges)
            #if DEBUG
            .onChange(of: debugScrollTarget) {
                guard let debugScrollTarget else { return }
                proxy.scrollTo(debugScrollTarget, anchor: .top)
            }
            #endif
            // Follow the reply as it streams in, and as its places are found.
            .onChange(of: isComposing) { _, composing in
                guard composing, !chat.isEmpty else { return }
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: chat.sessionId) {
                proxy.scrollTo(chat.isEmpty ? Self.topID : Self.bottomID, anchor: chat.isEmpty ? .top : .bottom)
            }
            // A new message scrolls to it.
            .onChange(of: chat.turns.last?.id) {
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            // Stick to the bottom: as the reply grows (text easing in, a places
            // card, the sources), follow it if you were at the end. Scroll up to
            // read and it leaves you there.
            .onScrollGeometryChange(for: MimoScrollPosition.self) { geometry in
                MimoScrollPosition(geometry)
            } action: { old, new in
                guard new.contentHeight > old.contentHeight, old.isAtBottom else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private static let topID = "mimo-top"
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
        VStack(spacing: Theme.grid) {
            if let status = chat.turns.last?.statusLine {
                MimoStatusPill(text: status)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composerField
        }
        .pageMargins()
        .padding(.bottom, Theme.grid)
        .animation(.smooth(duration: 0.3), value: chat.turns.last?.statusLine == nil)
    }

    private var composerField: some View {
        MimoComposer(
            draft: $draft,
            isComposing: $isComposing,
            isReplying: chat.isReplying,
            canSend: chat.canSend && situationStore.situation != nil,
            onSend: { send(draft) },
            onStop: { chat.stop() }
        )
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

    private func openChat(_ sessionId: String) {
        chat.open(sessionId: sessionId)
        draft = ""
        // Like a new chat, another chat drops the subject and the From Mimo layer.
        router.mimoSubject = nil
        router.clearFromMimo()
        showsHistory = false
    }

    private func deleteChat(_ sessionId: String) {
        chat.delete(sessionId: sessionId)
        history.removeAll { $0.id == sessionId }
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
            focusComposer: { isComposing = true },
            openHistory: { showsHistory = true },
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

/// The start of a new chat: a one-line intro under the header.
private struct MimoIntro: View {
    var body: some View {
        Text("Ask me what to order, how to say it, or where to go next.")
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A round glass button in the header, the size of a navigation bar button.
private struct MimoHeaderButton: View {
    let title: String
    let systemImage: String
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .buttonStyle(.plain)
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .glassEffect(.regular.interactive(isEnabled), in: .circle)
    }
}

/// The transcript's height and whether it's scrolled to the end, for sticking
/// to the bottom while a reply grows.
private struct MimoScrollPosition: Equatable {
    var contentHeight: CGFloat
    var isAtBottom: Bool

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        let maxOffset = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
        isAtBottom = maxOffset - geometry.contentOffset.y < 80
    }
}

/// What Mimo is doing while a reply streams, in one place just above the
/// composer: a small thinking Mimo and a line ("Searching the web…").
private struct MimoStatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.grid * 0.75) {
            MimoAvatarView(mood: .thinking, size: 22)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.smooth, value: text)
        }
        .padding(.leading, Theme.grid)
        .padding(.trailing, Theme.grid * 1.5)
        .padding(.vertical, Theme.grid / 2)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
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

#Preview("Tokyo") {
    MimoView(chat: MimoChat(store: .inMemory))
        .environment(AppSituationStore.preview(Fixtures.tokyo))
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppRouter(selectedTab: .mimo))
}
