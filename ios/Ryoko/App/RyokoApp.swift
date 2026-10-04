import SwiftUI

/// The app shell (W2.1). It owns the stores and services and puts them in the
/// environment:
///
///     @Environment(AppSituationStore.self) private var situationStore
///     @Environment(ProfileStore.self) private var profileStore
///     @Environment(APIStore.self) private var apiStore     // fixture vs live, base URL
///     @Environment(AppRouter.self) private var router       // tabs, cross-tab hand-offs, Show mode
///     @Environment(TranslateModel.self) private var translate // listening, turns (one per app, T2.5)
///     @Environment(\.ryokoAPI) private var api              // the API to call
///     @Environment(\.placeResolver) private var resolver    // the one shared MapKit resolver
///     @Environment(\.speechService) private var speech
///     @Environment(\.tripMemory) private var tripMemory     // what you did, for Mimo's trip memory
///
/// Previews: `.environment(AppSituationStore.preview())`,
/// `.environment(ProfileStore.preview())`, `.environment(APIStore())`,
/// `.environment(AppRouter())`, `.environment(TranslateModel())`. `\.ryokoAPI`, `\.placeResolver` and
/// `\.speechService` default to fixtures; `\.tripMemory` keeps nothing.
///
/// **The situation's clock (W3, W4, W6).** `situationStore.situation` changes
/// with the place, the preview and the local hour, so key `.task(id:)` work on
/// it. Its live `localTime` is only as fresh as that hour, so build every
/// request body (place card, discover, Mimo) from
/// `situationStore.currentSituation()`, which re-stamps a live situation to now
/// and leaves a preview at its committed time. Show a live clock with
/// `TimelineView(.everyMinute)` and `currentSituation(at: context.date)`.
@main
struct RyokoApp: App {
    @State private var situationStore: AppSituationStore
    @State private var profileStore = ProfileStore()
    @State private var apiStore: APIStore
    @State private var router = AppRouter(selectedTab: RootTabView.launchTab)
    /// Translate's listening and turns. App-wide, so listening carries on when
    /// you switch tabs and the tab bar's Listening accessory can stop it (T2.5).
    @State private var translateModel: TranslateModel
    /// One resolver for the app (MapKit's throttle is per app). W4 replaces the
    /// fixture with its MapKit resolver here, and nowhere else.
    @State private var placeResolver: any PlaceResolver = LivePlaceResolver()
    /// Speak (design §8.1): ElevenLabs, or the on-device voice without a key.
    @State private var speechService: any SpeechService
    /// Trip memory (design §8.3): batches of what you did, through the current API.
    @State private var tripMemory: TripMemoryLog
    /// The Live Activity for the active place (design §4.11), and its `ryoko://` links.
    @State private var liveActivities = LiveActivityCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let situationStore = AppSituationStore()
        let apiStore = APIStore()
        _situationStore = State(initialValue: situationStore)
        _apiStore = State(initialValue: apiStore)
        _tripMemory = State(initialValue: TripMemoryLog(api: { apiStore.api }, situation: { situationStore.currentSituation() }))
        let translate = TranslateModel.forLaunch()
        _translateModel = State(initialValue: translate)
        _speechService = State(initialValue: LiveSpeechService(beforeSpeaking: { await translate.stopForSpeech() }))
        #if DEBUG
        FixtureSelfCheck.runAtLaunch()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .onboardingOnFirstLaunch() // the survey, full screen on first launch (ios/Ryoko/Onboarding/)
                .environment(situationStore)
                .environment(profileStore)
                .environment(apiStore)
                .environment(router)
                .environment(translateModel)
                .environment(\.ryokoAPI, apiStore.api)
                .environment(\.placeResolver, placeResolver)
                .environment(\.speechService, speechService)
                .environment(\.tripMemory, tripMemory)
                .task {
                    liveActivities.start(situationStore: situationStore, profileStore: profileStore, apiStore: apiStore)
                    #if DEBUG
                    if let url = LiveActivityDebugOptions.openURLAtLaunch { liveActivities.open(url, router: router) }
                    if LiveActivityDebugOptions.runsScript { await LiveActivityDebugOptions.runScript(on: situationStore) }
                    #endif
                }
                // The Live Activity's taps (`ryoko://show?phrase=<id>`), on a cold start too.
                .onOpenURL { url in liveActivities.open(url, router: router) }
                #if DEBUG
                .task { await DebugLaunchOptions.apply(to: situationStore) }
                .overlay { if MimoAvatarGallery.launchRequested { MimoAvatarGallery().background(.background) } }
                .overlay { if LiveActivityGallery.launchRequested { LiveActivityGallery() } }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Timers don't run while the app is suspended: catch up on the local hour.
            if phase == .active { situationStore.refreshClock() }
            // Listening stops when Ryoko leaves the screen (design §4.8), whichever tab is open.
            if phase == .background {
                translateModel.stopAndForgetPause(.background)
                tripMemory.flush() // don't leave a batch waiting while suspended
            }
        }
    }
}

#if DEBUG
/// DEBUG launch arguments, for exercising the app from the command line:
///
///     xcrun simctl launch booted com.danielou.ryoko \
///       -RyokoAPIMode fixture -RyokoSamplePreview 19 -RyokoInitialTab map
///
/// - `-RyokoAPIMode fixture|live`: which API to use, for this launch only.
/// - `-RyokoSamplePreview <hour>`: preview the sample Tokyo ramen shop at that
///   local hour.
/// - `-RyokoInitialTab map|translate|mimo|me`: the tab to open on. The old
///   `nearby` and `now` open the Map, where Nearby's place card now lives.
/// - Map (`-RyokoMapCard`, `-RyokoMapDetails`, …): see `MapDebugOptions`.
/// - `-RyokoScrollToBottom 1`: open scrolling screens at the end (screenshots).
/// - `-RyokoAutoConfirm 1`: in live mode, confirm the nearest place once found.
/// - Live Activity (`-RyokoOpenURL`, `-RyokoActivityGallery`): see
///   `LiveActivityDebugOptions`.
enum DebugLaunchOptions {
    static let samplePreviewKey = "RyokoSamplePreview"
    static let initialTabKey = "RyokoInitialTab"

    static func apply(to situationStore: AppSituationStore) async {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: samplePreviewKey) != nil, situationStore.previewSituation == nil {
            situationStore.previewSample(hour: defaults.integer(forKey: samplePreviewKey))
        }
        if defaults.bool(forKey: "RyokoAutoConfirm") {
            // Wait up to 30 s for live mode to list places, then confirm the nearest.
            for _ in 0..<120 where situationStore.liveState != .ready {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let nearest = situationStore.candidates.first { situationStore.confirm(nearest.place) }
        }
    }

    static var initialTab: AppTab? {
        guard let name = UserDefaults.standard.string(forKey: initialTabKey) else { return nil }
        // Nearby was merged into the Map: its place card is the Map's sheet.
        if name == "nearby" || name == "now" { return .map }
        return AppTab(rawValue: name)
    }

    static var scrollAnchor: UnitPoint? {
        UserDefaults.standard.bool(forKey: "RyokoScrollToBottom") ? .bottom : nil
    }
}
#endif

extension View {
    /// DEBUG: honours `-RyokoScrollToBottom 1`. Does nothing in release builds.
    func debugLaunchScrollAnchor() -> some View {
        #if DEBUG
        defaultScrollAnchor(DebugLaunchOptions.scrollAnchor)
        #else
        self
        #endif
    }
}
