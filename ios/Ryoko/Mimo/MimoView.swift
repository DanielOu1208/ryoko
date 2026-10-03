import SwiftUI

/// Placeholder for the Mimo tab. The Mimo workstream replaces it.
struct MimoView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Mimo",
                systemImage: "bubble.left",
                description: Text("Ask Mimo about places, phrases and plans.")
            )
            .navigationTitle("Mimo")
        }
    }
}

#Preview {
    MimoView()
}
