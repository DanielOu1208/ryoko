import SwiftUI

/// Placeholder for the Map tab. The Map workstream replaces it.
struct MapView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Map",
                systemImage: "map",
                description: Text("Search places, see layers and preview a place at a chosen time.")
            )
            .navigationTitle("Map")
        }
    }
}

#Preview {
    MapView()
}
