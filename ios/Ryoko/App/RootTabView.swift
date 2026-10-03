import SwiftUI

/// The five tabs (design §3).
enum AppTab: String, CaseIterable, Hashable {
    case now
    case map
    case translate
    case mimo
    case me

    var title: String {
        switch self {
        case .now: "Now"
        case .map: "Map"
        case .translate: "Translate"
        case .mimo: "Mimo"
        case .me: "Me"
        }
    }

    /// `translate` is reserved for Apple's Translate app, so Translate uses `character.bubble`.
    var systemImage: String {
        switch self {
        case .now: "location.fill"
        case .map: "map"
        case .translate: "character.bubble"
        case .mimo: "bubble.left"
        case .me: "person.crop.circle"
        }
    }
}

/// The native `TabView` (iOS 18+ `Tab` API). On iOS 26 and later it renders as
/// the standard Liquid Glass tab bar; no custom tab bar. Each feature view owns
/// its `NavigationStack`, with a large title.
struct RootTabView: View {
    @State private var selection: AppTab = RootTabView.launchTab

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppTab.now.title, systemImage: AppTab.now.systemImage, value: AppTab.now) {
                NowView()
            }
            Tab(AppTab.map.title, systemImage: AppTab.map.systemImage, value: AppTab.map) {
                MapView()
            }
            Tab(AppTab.translate.title, systemImage: AppTab.translate.systemImage, value: AppTab.translate) {
                TranslateView()
            }
            Tab(AppTab.mimo.title, systemImage: AppTab.mimo.systemImage, value: AppTab.mimo) {
                MimoView()
            }
            Tab(AppTab.me.title, systemImage: AppTab.me.systemImage, value: AppTab.me) {
                MeView()
            }
        }
        .tint(Theme.tint)
    }

    private static var launchTab: AppTab {
        #if DEBUG
        DebugLaunchOptions.initialTab ?? .now
        #else
        .now
        #endif
    }
}

#Preview {
    RootTabView()
        .environment(AppSituationStore.preview())
        .environment(ProfileStore.preview())
        .environment(APIStore())
}
