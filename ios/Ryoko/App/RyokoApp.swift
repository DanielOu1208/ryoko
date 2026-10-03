import SwiftUI

@main
struct RyokoApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

/// Placeholder shell. The shell workstream replaces this.
struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Now", systemImage: "location.fill") {
                PlaceholderTab(title: "Now")
            }
            Tab("Map", systemImage: "map") {
                PlaceholderTab(title: "Map")
            }
            Tab("Translate", systemImage: "character.bubble") {
                PlaceholderTab(title: "Translate")
            }
            Tab("Mimo", systemImage: "bubble.left") {
                PlaceholderTab(title: "Mimo")
            }
            Tab("Me", systemImage: "person.crop.circle") {
                PlaceholderTab(title: "Me")
            }
        }
    }
}

private struct PlaceholderTab: View {
    let title: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("Coming soon"))
                .navigationTitle(title)
        }
    }
}

#Preview {
    RootTabView()
}
