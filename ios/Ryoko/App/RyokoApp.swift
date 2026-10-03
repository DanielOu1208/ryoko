import SwiftUI

/// The app shell (W2.1). It owns the stores and services and puts them in the
/// environment:
///
///     @Environment(AppSituationStore.self) private var situationStore
///     @Environment(ProfileStore.self) private var profileStore
///     @Environment(APIStore.self) private var apiStore     // fixture vs live, base URL
///     @Environment(AppRouter.self) private var router       // tabs, cross-tab hand-offs, Show mode
///     @Environment(\.ryokoAPI) private var api              // the API to call
///     @Environment(\.placeResolver) private var resolver    // the one shared MapKit resolver
///     @Environment(\.speechService) private var speech
///
/// Previews: `.environment(AppSituationStore.preview())`,
/// `.environment(ProfileStore.preview())`, `.environment(APIStore())`,
/// `.environment(AppRouter())`. `\.ryokoAPI`, `\.placeResolver` and
/// `\.speechService` default to fixtures.
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
    @State private var situationStore = AppSituationStore()
    @State private var profileStore = ProfileStore()
    @State private var apiStore = APIStore()
    @State private var router = AppRouter(selectedTab: RootTabView.launchTab)
    /// One resolver for the app (MapKit's throttle is per app). W4 replaces the
    /// fixture with its MapKit resolver here, and nowhere else.
    @State private var placeResolver: any PlaceResolver = LivePlaceResolver()
    /// The Speech workstream replaces the fixture here.
    @State private var speechService: any SpeechService = FixtureSpeechService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        FixtureSelfCheck.runAtLaunch()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(situationStore)
                .environment(profileStore)
                .environment(apiStore)
                .environment(router)
                .environment(\.ryokoAPI, apiStore.api)
                .environment(\.placeResolver, placeResolver)
                .environment(\.speechService, speechService)
                #if DEBUG
                .task { await DebugLaunchOptions.apply(to: situationStore) }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Timers don't run while the app is suspended: catch up on the local hour.
            if phase == .active { situationStore.refreshClock() }
        }
    }
}

#if DEBUG
/// DEBUG launch arguments, for exercising the app from the command line:
///
///     xcrun simctl launch booted com.danielou.ryoko \
///       -RyokoAPIMode fixture -RyokoSamplePreview 19 -RyokoInitialTab now
///
/// - `-RyokoAPIMode fixture|live`: which API to use, for this launch only.
/// - `-RyokoSamplePreview <hour>`: preview the sample Tokyo ramen shop at that
///   local hour.
/// - `-RyokoInitialTab now|map|translate|mimo|me`: the tab to open on.
/// - `-RyokoScrollToBottom 1`: open scrolling screens at the end (screenshots).
/// - `-RyokoAutoConfirm 1`: in live mode, confirm the nearest place once found.
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
        UserDefaults.standard.string(forKey: initialTabKey).flatMap(AppTab.init(rawValue:))
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
