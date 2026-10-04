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
struct RootTabView: View {
    @Environment(AppRouter.self) private var router

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
        .tint(Theme.tint)
        .fullScreenCover(item: $router.show) { content in
            ShowModeView(content: content)
        }
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
}
