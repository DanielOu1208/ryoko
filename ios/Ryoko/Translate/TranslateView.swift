import SwiftUI
import UIKit

/// The Translate tab (design §4.8): live two-way translation, nothing else.
///
/// - The pair is your home language ⇄ the active situation's local language,
///   or a pick from the pair menu. It can't change while listening.
/// - The panes show the latest turn, upright or face to face. The layout
///   follows the phone's tilt, or the toolbar toggle forces one.
/// - History lists every turn of this run of the app.
/// - Type mode (the keyboard button) and editing your turns (tap your words,
///   here or in History) go through `TranslateComposer` (T2.4). Listening
///   pauses while the composer is open and picks up again after.
/// - The model is the app's (`RyokoApp`), so listening carries on in other
///   tabs, where the tab bar's Listening accessory shows it (T2.5).
struct TranslateView: View {
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(TranslateModel.self) private var model
    @Environment(\.ryokoAPI) private var api
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var composer = TranslateComposer()
    @State private var tilt = TiltMonitor()
    @State private var layoutChoice: LayoutChoice
    @State private var manualHome: String?
    @State private var manualOther: String?
    @State private var showsHistory = false
    /// A turn picked in History, edited once the sheet has gone.
    @State private var pendingEdit: Turn?
    /// Counts committed typed turns and edits, for the haptic.
    @State private var commits = 0
    #if DEBUG
    @State private var appliedDebugOptions = false
    #endif

    /// Automatic follows the tilt; the toolbar toggle forces a layout.
    enum LayoutChoice: Hashable {
        case automatic
        case forced(TranslateLayout)
    }

    init() {
        #if DEBUG
        _layoutChoice = State(initialValue: TranslateDebug.forcedLayout.map(LayoutChoice.forced) ?? .automatic)
        _manualHome = State(initialValue: TranslateDebug.manualHome)
        _manualOther = State(initialValue: TranslateDebug.manualOther)
        #else
        _layoutChoice = State(initialValue: .automatic)
        #endif
    }

    // MARK: Derived

    /// The running session's pair, or the one a new session would use.
    private var pair: TranslatePair? {
        if model.isActive || model.isPaused, let running = model.sessionPair { return running }
        return PairChoice.resolve(
            homeTag: profileStore.profile.homeLanguage,
            situationLanguage: situationStore.situation?.localLanguage,
            manualHome: manualHome,
            manualOther: manualOther
        )
    }

    private var layout: TranslateLayout {
        switch layoutChoice {
        case .automatic: tilt.layout
        case .forced(let layout): layout
        }
    }

    /// Hong Kong and Macau speak Cantonese, which Translate can't hear yet.
    private var speechNote: String? {
        guard manualOther == nil, situationStore.language?.speechSupported == false else { return nil }
        return "People here mostly speak Cantonese. Translate listens for Mandarin."
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if composer.isOpen {
                    TranslateComposerView(composer: composer, submit: commitComposer)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    TranslateControls(
                        model: model,
                        pair: pair,
                        note: speechNote,
                        options: PairChoice.options(situationLanguage: situationStore.situation?.localLanguage),
                        homeTag: profileStore.profile.homeLanguage,
                        situationLanguage: situationStore.situation?.localLanguage,
                        manualHome: $manualHome,
                        manualOther: $manualOther,
                        toggle: toggleListening,
                        type: openTyping
                    )
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: composer.isOpen)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(composer.isOpen ? composerTitle : "Translate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showsHistory, onDismiss: editPendingTurn) {
                TranslateHistorySheet(turns: model.history) { turn in
                    pendingEdit = turn
                    showsHistory = false
                }
            }
        }
        .onAppear { tilt.start() }
        .onDisappear { tilt.stop() }
        .sensoryFeedback(.impact(weight: .medium), trigger: layout)
        .sensoryFeedback(trigger: model.phase) { old, new in
            // A pause for the composer is quiet: you didn't stop anything.
            if model.isPaused { return nil }
            if new == .listening, old != .listening { return .start }
            if new == .idle, old == .listening || old == .finishing { return .stop }
            return nil
        }
        .sensoryFeedback(.success, trigger: commits)
        #if DEBUG
        .task { await applyDebugLaunchOptions() }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let problem = model.problem, model.display == nil {
            problemView(problem)
        } else if pair == nil, model.display == nil {
            ContentUnavailableView {
                Label("Choose their language", systemImage: "character.bubble")
            } description: {
                Text("Pick the language the other person speaks from the menu below, or preview a place.")
            }
        } else {
            ZStack {
                TranslatePanes(turn: model.display, pair: pair, layout: layout, editMine: editShownTurn)
                    // Under Reduce Motion the layouts crossfade instead of rotating.
                    .id(reduceMotion ? layout.rawValue : "panes")
                    .transition(.opacity)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth, value: layout)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if composer.isOpen {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: closeComposer)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: commitComposer)
                    .disabled(composer.isFinishing || TypedText.request(composer.text) == nil)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { layoutMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .editing = composer.purpose { true } else { false }
    }

    private var composerTitle: String {
        isEditing ? "Edit" : "Type"
    }

    private func problemView(_ problem: TranslateProblem) -> some View {
        ContentUnavailableView {
            Label(problem.title, systemImage: problem.systemImage)
        } description: {
            Text(problem.detail)
        } actions: {
            if problem == .microphoneDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
            } else if problem.isRetryable {
                Button("Try again", action: toggleListening)
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Tap: switch to the other layout and keep it. Touch and hold: back to
    /// following the tilt.
    private var layoutMenu: some View {
        Menu {
            Picker("Layout", selection: $layoutChoice) {
                Label("Follow the tilt", systemImage: "gyroscope").tag(LayoutChoice.automatic)
                Label("Upright", systemImage: "iphone.gen3").tag(LayoutChoice.forced(.upright))
                Label("Face to face", systemImage: "person.line.dotted.person").tag(LayoutChoice.forced(.faceToFace))
            }
        } label: {
            Label(
                layout == .faceToFace ? "Face to face" : "Upright",
                systemImage: layout == .faceToFace ? "person.line.dotted.person" : "iphone.gen3"
            )
        } primaryAction: {
            layoutChoice = .forced(layout == .faceToFace ? .upright : .faceToFace)
        }
        .accessibilityLabel(layout == .faceToFace ? "Layout: face to face" : "Layout: upright")
        .accessibilityHint("Switches the layout. Touch and hold to follow the phone's tilt.")
    }

    // MARK: Listening

    private func toggleListening() {
        if model.isActive {
            model.stopAndForgetPause(.user)
        } else if let pair {
            Task { await model.start(pair: pair, api: api) }
        }
    }

    // MARK: Type mode and editing (T2.4)

    /// Opens Type mode with the pair on screen, pausing listening first.
    private func openTyping() {
        guard let pair, !composer.isOpen else { return }
        Task {
            await model.pause()
            composer.openTyping(pair: pair, api: api, situation: { situationStore.currentSituation() })
        }
    }

    /// The panes' turn, when it's yours: tapping your words edits them.
    private var editShownTurn: (() -> Void)? {
        guard let shown = model.display, shown.speaker == .me else { return nil }
        return { beginEditing(turnId: shown.id) }
    }

    /// Opens the editor on turn `turnId`, pausing listening first so the
    /// turn is final.
    private func beginEditing(turnId: Int) {
        guard !composer.isOpen else { return }
        Task {
            await model.pause()
            guard let turn = model.turn(id: turnId), turn.isEditable else {
                await model.resume()
                return
            }
            composer.openEditing(turn, api: api, situation: { situationStore.currentSituation() })
        }
    }

    private func editPendingTurn() {
        guard let turn = pendingEdit else { return }
        pendingEdit = nil
        beginEditing(turnId: turn.id)
    }

    /// Done: adds the typed turn or applies the edit, then the panes show it
    /// full size (flipped toward them if face to face). If the translation
    /// failed, the composer stays open with the error.
    private func commitComposer() {
        guard let purpose = composer.purpose, !composer.isFinishing else { return }
        Task {
            guard let result = await composer.finish() else {
                // Nothing to add (empty, or an unchanged edit), unless it failed.
                if composer.failure == nil { closeComposer() }
                return
            }
            switch purpose {
            case .typing(let pair):
                model.addTyped(pair: pair, text: result.text, translation: result.translation)
            case .editing(let turn):
                model.applyEdit(id: turn.id, original: result.text, translation: result.translation)
            }
            commits += 1
            closeComposer()
        }
    }

    /// Closes the composer and picks listening up again if it paused for it.
    private func closeComposer() {
        composer.close()
        Task { await model.resume() }
    }

    #if DEBUG
    /// Each hook is timed from when Translate appears, independently.
    private func applyDebugLaunchOptions() async {
        guard !appliedDebugOptions else { return }
        appliedDebugOptions = true
        TranslateDebug.runSelfCheckIfAsked()
        if let delay = TranslateDebug.historyDelay {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                showsHistory = true
            }
        }
        if let text = TranslateDebug.typeText {
            Task { await debugType(text) }
        }
        if let delay = TranslateDebug.editDelay {
            Task { await debugEdit(after: delay) }
        }
    }

    private func debugType(_ text: String) async {
        try? await Task.sleep(for: .seconds(TranslateDebug.typeDelay))
        openTyping()
        try? await Task.sleep(for: .milliseconds(600))
        composer.debugType(text)
        if let done = TranslateDebug.typeDoneDelay {
            try? await Task.sleep(for: .seconds(done))
            commitComposer()
        }
    }

    private func debugEdit(after delay: Double) async {
        try? await Task.sleep(for: .seconds(delay))
        await model.pause()
        guard let turn = model.latestEditable else {
            await model.resume()
            return
        }
        beginEditing(turnId: turn.id)
        if let text = TranslateDebug.editText {
            try? await Task.sleep(for: .milliseconds(600))
            composer.debugType(text)
        }
        if let done = TranslateDebug.editDoneDelay {
            try? await Task.sleep(for: .seconds(done))
            commitComposer()
        }
    }
    #endif
}

#Preview("Translate") {
    TranslateView()
        .environment(AppSituationStore.preview())
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppRouter())
        .environment(TranslateModel())
}
