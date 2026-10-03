import SwiftUI
import UIKit

/// The Translate tab (design §4.8): live two-way translation, nothing else.
///
/// - The pair is your home language ⇄ the active situation's local language,
///   or a pick from the pair menu. It can't change while listening.
/// - The panes show the latest turn, upright or face to face. The layout
///   follows the phone's tilt, or the toolbar toggle forces one.
/// - History lists every turn of this run of the app.
struct TranslateView: View {
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var model: TranslateModel
    @State private var tilt = TiltMonitor()
    @State private var layoutChoice: LayoutChoice
    @State private var manualHome: String?
    @State private var manualOther: String?
    @State private var showsHistory = false
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
        let silence = TranslateDebug.silenceSeconds.map { Duration.seconds($0) } ?? .seconds(120)
        _model = State(initialValue: TranslateModel(source: TranslateDebug.source, silenceLimit: silence))
        _layoutChoice = State(initialValue: TranslateDebug.forcedLayout.map(LayoutChoice.forced) ?? .automatic)
        _manualHome = State(initialValue: TranslateDebug.manualHome)
        _manualOther = State(initialValue: TranslateDebug.manualOther)
        #else
        _model = State(initialValue: TranslateModel())
        _layoutChoice = State(initialValue: .automatic)
        #endif
    }

    // MARK: Derived

    /// The running session's pair, or the one a new session would use.
    private var pair: TranslatePair? {
        if model.isActive, let running = model.sessionPair { return running }
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
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TranslateControls(
                    model: model,
                    pair: pair,
                    note: speechNote,
                    options: PairChoice.options(situationLanguage: situationStore.situation?.localLanguage),
                    homeTag: profileStore.profile.homeLanguage,
                    situationLanguage: situationStore.situation?.localLanguage,
                    manualHome: $manualHome,
                    manualOther: $manualOther,
                    toggle: toggleListening
                )
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { layoutMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsHistory = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .sheet(isPresented: $showsHistory) {
                TranslateHistorySheet(turns: model.history)
            }
        }
        .onAppear { tilt.start() }
        .onDisappear { tilt.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop(.background) }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: layout)
        .sensoryFeedback(trigger: model.phase) { old, new in
            if new == .listening, old != .listening { return .start }
            if new == .idle, old == .listening || old == .finishing { return .stop }
            return nil
        }
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
                TranslatePanes(turn: model.display, pair: pair, layout: layout)
                    // Under Reduce Motion the layouts crossfade instead of rotating.
                    .id(reduceMotion ? layout.rawValue : "panes")
                    .transition(.opacity)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth, value: layout)
        }
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

    private func toggleListening() {
        if model.isActive {
            model.stop(.user)
        } else if let pair {
            Task { await model.start(pair: pair) }
        }
    }

    #if DEBUG
    private func applyDebugLaunchOptions() async {
        guard !appliedDebugOptions else { return }
        appliedDebugOptions = true
        TranslateDebug.runSelfCheckIfAsked()
        if TranslateDebug.autoStart, !model.isActive, model.history.isEmpty, let pair {
            await model.start(pair: pair)
        }
        if let delay = TranslateDebug.historyDelay {
            try? await Task.sleep(for: .seconds(delay))
            showsHistory = true
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
}
