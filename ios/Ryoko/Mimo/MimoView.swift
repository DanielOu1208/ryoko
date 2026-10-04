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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var sidebarDrag: CGFloat = 0
    /// When a sideways swipe last moved the chat (`isSwipingSidebar`).
    @State private var sidebarSwipedAt = Date.distantPast
    /// Whether the swipe's pan is under way (`MimoSidebarSwipe`).
    @State private var sidebarSwipe = MimoSidebarSwipe.Tracker()
    /// Goes up with each move of a swipe, for the stuck-swipe watchdog.
    @State private var sidebarSwipeTick = 0
    /// The saved chats, read when the sidebar opens.
    @State private var history: [MimoChatSummary] = []
    @FocusState private var isComposing: Bool
    /// Whether the composer is open as the text field rather than tucked into
    /// the corner button (`showsComposerField`). Coming to rest at the end of
    /// the chat opens it; scrolling back, or closing the keyboard, tucks it away.
    @State private var isComposerOpen = false
    /// The corner button was tapped: focus the field once it's on screen.
    @State private var focusesComposerOnOpen = false
    /// Where the chat was when your drag started, for measuring a scroll back.
    /// Nil when no drag is under way.
    @State private var composerScrollMark: CGFloat?
    /// The composer already tucked away during this drag: once per drag.
    @State private var composerChangedThisDrag = false
    @State private var scrollPhase: ScrollPhase = .idle
    /// Whether the chat keeps to its end as it grows (`transcript`): on when
    /// you send, open a chat or start typing; off while you drag, and after a
    /// drag only if you let go away from the end.
    @State private var followsEnd = true
    /// Until when scroll changes only move the mark: the composer opening or
    /// closing shifts the chat by itself, which mustn't count as a scroll.
    @State private var composerSettlesAt = Date.distantPast
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
                    .gesture(MimoSidebarSwipe(
                        tracker: sidebarSwipe,
                        onChange: sidebarSwipeChanged,
                        onEnd: { settleSidebar(at: $0, width: width) }
                    ))

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
            // Watchdog: a swipe that stops moving without an end (the view went
            // away mid-swipe, say) mustn't leave the chat partway across.
            .task(id: sidebarSwipeTick) {
                guard sidebarDrag != 0 else { return }
                try? await Task.sleep(for: .seconds(0.35))
                guard !Task.isCancelled, sidebarDrag != 0 else { return }
                if sidebarSwipe.isActive {
                    // A finger resting mid-swipe: give it longer.
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled, sidebarDrag != 0 else { return }
                    sidebarSwipe.isActive = false
                }
                settleSidebar(at: sidebarDrag, width: width)
            }
        }
        .animation(.smooth(duration: 0.3), value: showsHistory)
        .onChange(of: showsHistory, initial: true) { _, shows in
            guard shows else { return }
            isComposing = false
            history = chat.history()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: showCount)
        .onChange(of: router.mimoQuestion, initial: true) { _, place in
            if let place { ask(about: place) }
        }
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
            .background { SituationGradient(mood: chat.turns.last?.isStreaming == true ? .working : .calm) }
            .safeAreaBar(edge: .top) {
                VStack(spacing: Theme.grid) {
                    TimelineView(.everyMinute) { context in
                        header(at: context.date)
                    }
                    subjectBar
                }
            }
            .safeAreaBar(edge: .bottom) {
                if showsComposerField {
                    composer
                        .transition(composerTransition(scale: 0.9))
                }
            }
            // Tucked away, the composer is a button in the corner, so the chat
            // runs down to the tab bar (design §4.9).
            .overlay(alignment: .bottom) {
                if !showsComposerField {
                    collapsedComposer
                        .transition(composerTransition(scale: 0.6))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3), value: showsComposerField)
            .onChange(of: showsComposerField) { composerSettlesAt = Date.now + 0.4 }
            .onChange(of: isComposing) { _, composing in
                // Closing the keyboard with nothing typed tucks the composer away.
                if !composing, draft.isEmpty { isComposerOpen = false }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Mimo")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Swipe right on the chat to open the sidebar, left to close it
    /// (`MimoSidebarSwipe`). It runs alongside the chat's own gestures, so a
    /// swipe that starts on a place or a phrase would also tap it when the
    /// finger lifts there: taps in the chat check `isSwipingSidebar`
    /// (`unlessSwiping`).
    private func sidebarSwipeChanged(_ distance: CGFloat) {
        sidebarDrag = distance
        sidebarSwipedAt = .now
        sidebarSwipeTick &+= 1
    }

    /// Ends a swipe: open or closed by where it would come to rest
    /// (`projected`), or back where it was when it was cancelled (nil).
    private func settleSidebar(at projected: CGFloat?, width: CGFloat) {
        sidebarSwipedAt = .now
        withAnimation(.smooth(duration: 0.3)) {
            if let projected {
                showsHistory = (showsHistory ? width : 0) + projected > width / 2
            }
            sidebarDrag = 0
        }
    }

    /// True while a sideways swipe moves the chat, and for a moment after: the
    /// finger lifting over a place or phrase at the end of a swipe isn't a tap.
    private var isSwipingSidebar: Bool {
        sidebarDrag != 0 || Date.now.timeIntervalSince(sidebarSwipedAt) < 0.4
    }

    /// `action`, unless it fires as part of a sidebar swipe.
    private func unlessSwiping(_ action: @escaping () -> Void) -> () -> Void {
        { if !isSwipingSidebar { action() } }
    }

    /// `action` with its argument, unless it fires as part of a sidebar swipe.
    private func unlessSwiping<Value>(_ action: @escaping (Value) -> Void) -> (Value) -> Void {
        { value in if !isSwipingSidebar { action(value) } }
    }

    // MARK: Header

    /// Mimo centred at the top, as a contact in Messages: the animated avatar
    /// with where you are and the local time under it, in one line (only the
    /// avatar before there's a place). History on the left and New chat on the
    /// right, level with the avatar.
    private func header(at date: Date) -> some View {
        let here = whereAndWhen(at: date)
        return HStack(alignment: .mimoAvatarMiddle) {
            MimoHeaderButton(title: "History", systemImage: "sidebar.leading", action: unlessSwiping { showsHistory = true })
            Spacer(minLength: Theme.grid)
            // The pill tucks up under the avatar, whose canvas has room around the body.
            VStack(spacing: -Theme.grid) {
                MimoAvatarView(mood: avatarMood, size: 64)
                    .alignmentGuide(.mimoAvatarMiddle) { $0[VerticalAlignment.center] }
                // In a glass pill, like a contact's name in Messages, so it
                // stays readable over the chat scrolling under it. The avatar
                // and the tab already say Mimo, so the pill says only where and
                // when, and there's none before there's a place (the Where are
                // you card covers that); a long place name gives way before
                // the time does.
                if let here {
                    HStack(spacing: 0) {
                        Text(here.place)
                            .lineLimit(1)
                        if let time = here.time {
                            Text(" · \(time)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    // Like a navigation bar's title, it stops growing at the
                    // accessibility sizes, so the place still fits beside the time.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(.horizontal, Theme.grid * 1.75)
                    .padding(.vertical, Theme.grid / 2)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            // One heading for VoiceOver, which still names Mimo.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(["Mimo", here?.place, here?.time].compactMap(\.self).joined(separator: ", "))
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.grid)
            MimoHeaderButton(title: "New chat", systemImage: "square.and.pencil", action: unlessSwiping(startNewChat))
                .disabled(chat.isEmpty && router.mimoSubject == nil)
        }
        .pageMargins()
        // A little into the status bar's band, to leave the chat more room,
        // with clear space between the avatar and the Dynamic Island.
        .padding(.top, -Theme.grid)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
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
                                onShowPhrase: unlessSwiping(openShow),
                                onSelectPlace: unlessSwiping(openOnMap),
                                onShowOnMap: unlessSwiping(showOnMap),
                                onRetry: unlessSwiping { retry(turn.id) }
                            )
                            .id(turn.id)
                        }
                    }
                    .pageMargins()
                    .padding(.top, Theme.grid)
                    // The end marker is the bottom margin itself, so scrolling to it
                    // shows the whole reply (sources last) clear of the composer, or,
                    // with the composer tucked away, of the corner button.
                    Color.clear
                        .frame(height: Theme.grid * 2 + (showsComposerField ? 0 : MimoComposeButton.size + Theme.grid))
                        .id(Self.bottomID)
                        .accessibilityHidden(true)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(chat.isEmpty ? .top : .bottom, for: .initialOffset)
            // No `.sizeChanges` anchor: it shifted the chat whenever the composer
            // came or went mid-scroll. `followsEnd` keeps the end in view instead
            // (the keyboard included).
            #if DEBUG
            .onChange(of: debugScrollTarget) {
                guard let debugScrollTarget else { return }
                followsEnd = false
                proxy.scrollTo(debugScrollTarget, anchor: .top)
            }
            #endif
            .onChange(of: isComposing) { _, composing in
                guard composing, !chat.isEmpty else { return }
                followsEnd = true
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: chat.sessionId) {
                followsEnd = !chat.isEmpty
                proxy.scrollTo(chat.isEmpty ? Self.topID : Self.bottomID, anchor: chat.isEmpty ? .top : .bottom)
            }
            // A new message scrolls to it, and the chat follows the reply.
            .onChange(of: chat.turns.last?.id) {
                followsEnd = true
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            // Follow the end: as the reply grows (text easing in, a places card,
            // the sources) or the bottom edge moves (keyboard, composer), keep
            // the end in view, unless you're scrolling. The app's own animated
            // scrolls don't pause it: one cut short by the keyboard can leave
            // the phase at `.animating` for good.
            .onScrollGeometryChange(for: MimoScrollExtent.self) { geometry in
                MimoScrollExtent(geometry)
            } action: { old, new in
                guard followsEnd, !isScrollingByHand else { return }
                if new.bottomInset != old.bottomInset {
                    // The keyboard or the composer moved the bottom edge: glide with it.
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onScrollPhaseChange { old, phase, context in
                scrollPhase = phase
                switch phase {
                case .interacting:
                    // You're scrolling: the chat stops following until you let go at the end.
                    followsEnd = false
                    composerScrollMark = context.geometry.contentOffset.y
                    composerChangedThisDrag = false
                    // A sidebar swipe left partway (one that never ended) gives way to the scroll.
                    if sidebarDrag != 0, !sidebarSwipe.isActive {
                        withAnimation(.smooth(duration: 0.3)) { sidebarDrag = 0 }
                    }
                case .idle:
                    composerScrollMark = nil
                    if old == .interacting || old == .decelerating {
                        let atEnd = MimoScrollExtent.distanceFromEnd(context.geometry) < 40
                        followsEnd = atEnd
                        // Coming to rest at the end (a pull past it bounces back
                        // here too) opens the composer.
                        if atEnd { setComposerOpen(true) }
                    } else if followsEnd {
                        // An animated scroll aims where the end was when it
                        // started; the reply may have grown since.
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                default:
                    break
                }
            }
            // Scrolling back to read tucks the composer away; the chat following a reply doesn't.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                composerFollowsScroll(to: y)
            }
            // Safeguard: once a reply ends (and when the tab comes back), check
            // twice more that its end, sources included, is in view, after the
            // text has caught up and the sources have faded in.
            .task(id: lastTurnState) {
                guard let turn = chat.turns.last, !turn.isStreaming else { return }
                for delay in [0.3, 1.0] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    if followsEnd, !isScrollingByHand {
                        withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
            }
        }
    }

    /// Whether you're dragging the chat or it's still gliding from your flick.
    private var isScrollingByHand: Bool {
        scrollPhase == .interacting || scrollPhase == .decelerating
    }

    /// The last turn and whether it's still streaming, for the end safeguard.
    private var lastTurnState: String {
        guard let turn = chat.turns.last else { return "" }
        return "\(turn.id.uuidString)-\(turn.isStreaming)"
    }

    /// How far you scroll back before the composer tucks away.
    private static let composerScrollDistance: CGFloat = 40

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
                Button(action: unlessSwiping { send(starter) }) {
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
            Button("Open Map", systemImage: "map", action: unlessSwiping { router.selectedTab = .map })
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
        .task {
            // The corner button opened it: the field takes focus once it exists.
            guard focusesComposerOnOpen else { return }
            focusesComposerOnOpen = false
            isComposing = true
        }
    }

    /// The composer shows as the text field while you type or have a draft, in
    /// a new chat (the first thing you do is ask), and once opened. Otherwise
    /// it's the corner button, so the chat gets the room.
    private var showsComposerField: Bool {
        isComposerOpen || isComposing || !draft.isEmpty || chat.isEmpty
    }

    /// The composer tucked away: the corner button (Stop while Mimo replies),
    /// with the status pill centred beside it.
    private var collapsedComposer: some View {
        MimoComposeButton(isReplying: chat.isReplying, onOpen: unlessSwiping(openComposer), onStop: unlessSwiping { chat.stop() })
            .frame(maxWidth: .infinity, alignment: .trailing)
            .overlay {
                // Centred, and clear of the button on both sides.
                if let status = chat.turns.last?.statusLine {
                    MimoStatusPill(text: status)
                        .padding(.horizontal, MimoComposeButton.size + Theme.grid)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .pageMargins()
            .padding(.bottom, Theme.grid)
            .animation(.smooth(duration: 0.3), value: chat.turns.last?.statusLine == nil)
    }

    /// The field grows out of the corner button, and shrinks back into it.
    private func composerTransition(scale: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: scale, anchor: .bottomTrailing))
    }

    /// The corner button: open the field with the keyboard up. A field that's
    /// already showing takes focus now; a new one once it's on screen.
    private func openComposer() {
        if showsComposerField {
            isComposing = true
        } else {
            focusesComposerOnOpen = true
        }
        isComposerOpen = true
    }

    /// Scrolling back to read (away from the end) by `composerScrollDistance`
    /// tucks the composer away, at most once per drag and never while you
    /// type. It only opens again when a scroll comes to rest at the end
    /// (`transcript`) or from the corner button, so it never changes size
    /// under your finger mid-chat. Only your own scrolls count.
    private func composerFollowsScroll(to y: CGFloat) {
        guard isScrollingByHand, !composerChangedThisDrag, let mark = composerScrollMark else { return }
        guard Date.now >= composerSettlesAt else {
            composerScrollMark = y
            return
        }
        if y < mark - Self.composerScrollDistance, isComposerOpen {
            composerChangedThisDrag = true
            setComposerOpen(false)
        }
    }

    /// Opens or tucks the composer, unless it changed in the last moment.
    private func setComposerOpen(_ open: Bool) {
        guard open != isComposerOpen, Date.now >= composerSettlesAt else { return }
        isComposerOpen = open
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

    /// "Ask Mimo" from a place's card: a new chat about the place, asked at
    /// once, with the place as its subject. The Map's From Mimo layer stays:
    /// you're looking at it. With no situation yet, the question waits in the
    /// composer.
    private func ask(about place: Place) {
        router.mimoQuestion = nil
        chat.newChat()
        router.mimoSubject = place
        let question = "Tell me more about \(place.name)."
        if sendContext() == nil {
            draft = question
        } else {
            draft = ""
            send(question)
        }
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

    /// Where you are and the time there ("Menya Kaze", "8:00 PM"), in the
    /// place's time zone: nil before there's a situation, no time without a zone.
    private func whereAndWhen(at date: Date) -> (place: String, time: String?)? {
        guard let situation = situationStore.situation else { return nil }
        let clocked = situation.stamped(at: date)
        let name = situation.place?.name ?? situation.city
        guard let instant = clocked.date, let zone = clocked.zone else { return (name, nil) }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return (name, instant.formatted(style))
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
            focusComposer: openComposer,
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

private extension VerticalAlignment {
    /// The middle of the header's avatar, which the header buttons line up with.
    nonisolated enum MimoAvatarMiddle: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let mimoAvatarMiddle = VerticalAlignment(MimoAvatarMiddle.self)
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
            // A bar button's symbol stops growing at the accessibility sizes,
            // so it stays inside its 44 pt circle.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .buttonStyle(.plain)
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .glassEffect(.regular.interactive(isEnabled), in: .circle)
    }
}

/// What decides where the chat's end is: its content's height and the space
/// it scrolls in (the keyboard and composer change the bottom inset). When one
/// changes, a following chat scrolls to its end.
private struct MimoScrollExtent: Equatable {
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var bottomInset: CGFloat

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        bottomInset = geometry.contentInsets.bottom
    }

    /// How far the chat is scrolled above its end, in points.
    static func distanceFromEnd(_ geometry: ScrollGeometry) -> CGFloat {
        let maxOffset = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
        return maxOffset - geometry.contentOffset.y
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

/// The composer tucked into the bottom-right corner: tap to open it with the
/// keyboard up. While Mimo replies it's Stop, as the open composer's button is.
private struct MimoComposeButton: View {
    static let size: CGFloat = 50

    let isReplying: Bool
    var onOpen: () -> Void
    var onStop: () -> Void

    var body: some View {
        if isReplying {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.bold))
                    .frame(width: Self.size, height: Self.size)
            }
            .buttonStyle(.monochromeProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Stop")
        } else {
            Button("Ask Mimo", systemImage: "text.bubble", action: onOpen)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.medium))
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityHint("Opens the message field")
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
