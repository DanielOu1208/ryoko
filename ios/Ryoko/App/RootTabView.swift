import SwiftUI

/// The five tabs, in tab-bar order (design §3). The app opens on Map, in the centre.
enum AppTab: String, CaseIterable, Hashable {
    case translate
    case nearby
    case map
    case mimo
    case me

    var title: String {
        switch self {
        case .nearby: "Nearby"
        case .map: "Map"
        case .translate: "Translate"
        case .mimo: "Mimo"
        case .me: "Me"
        }
    }

    /// `translate` is reserved for Apple's Translate app, so Translate uses `character.bubble`.
    var systemImage: String {
        switch self {
        case .nearby: "location.fill"
        case .map: "map"
        case .translate: "character.bubble"
        case .mimo: "bubble.left"
        case .me: "person.crop.circle"
        }
    }
}

/// The native `TabView` (iOS 18+ `Tab` API). On iOS 26 and later it renders as
/// the standard Liquid Glass tab bar; no custom tab bar. Each feature view owns
/// its `NavigationStack`, with a large title. The selected tab and Show mode
/// live in `AppRouter`, so any feature can switch tabs or open Show mode.
///
/// Tier 2 (design §3, T2.5):
/// - The tab bar minimizes when you scroll down (`tabBarMinimizeBehavior`), in
///   every tab with a scroll view. It's a TabView modifier, so no tab opts in.
/// - While Translate listens, the bottom accessory shows "Listening · English
///   ⇄ Japanese" with a stop button on the other tabs (`ListeningAccessory`).
struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(TranslateModel.self) private var translate
    #if DEBUG
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.ryokoAPI) private var api
    #endif

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab(AppTab.translate.title, systemImage: AppTab.translate.systemImage, value: AppTab.translate) {
                TranslateView()
            }
            Tab(AppTab.nearby.title, systemImage: AppTab.nearby.systemImage, value: AppTab.nearby) {
                NearbyView()
            }
            Tab(AppTab.map.title, systemImage: AppTab.map.systemImage, value: AppTab.map) {
                MapView()
            }
            Tab(value: AppTab.mimo) {
                MimoView()
            } label: {
                Label { Text(AppTab.mimo.title) } icon: { MimoAvatarIcon.image() }
            }
            Tab(AppTab.me.title, systemImage: AppTab.me.systemImage, value: AppTab.me) {
                MeView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: ListeningAccessory.isShown(for: translate, on: router.selectedTab)) {
            ListeningAccessory(model: translate) { router.selectedTab = .translate }
        }
        .tint(Theme.tint)
        .fullScreenCover(item: $router.show) { content in
            ShowModeView(content: content)
        }
        #if DEBUG
        .task {
            await TranslateDebug.autoStartIfAsked(
                model: translate,
                homeTag: { profileStore.profile.homeLanguage },
                situationLanguage: { situationStore.situation?.localLanguage },
                api: api
            )
        }
        #endif
    }

    /// The tab to open on: Map, or `-RyokoInitialTab` in DEBUG.
    static var launchTab: AppTab {
        #if DEBUG
        DebugLaunchOptions.initialTab ?? .map
        #else
        .map
        #endif
    }
}

#Preview {
    RootTabView()
        .environment(AppSituationStore.preview())
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppRouter())
        .environment(TranslateModel())
}
