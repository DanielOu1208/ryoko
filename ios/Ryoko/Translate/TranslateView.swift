import SwiftUI

/// Placeholder for the Translate tab. The Translate workstream replaces it.
struct TranslateView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Translate",
                systemImage: "character.bubble",
                description: Text("Live two-way translation for the place you're at.")
            )
            .navigationTitle("Translate")
        }
    }
}

#Preview {
    TranslateView()
}
