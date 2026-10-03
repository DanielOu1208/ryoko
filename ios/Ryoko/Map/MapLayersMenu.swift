import SwiftUI

/// The layer toggles in a native menu (design §4.7): Food & drink and
/// Washrooms filter the map's points of interest; Hidden gems pins Mimo's
/// picks; From Mimo shows what the Mimo tab sent, with a clear action.
struct MapLayersMenu: View {
    @Binding var layers: MapLayers
    /// How many places the Mimo tab sent.
    let fromMimoCount: Int
    let onClearFromMimo: () -> Void

    var body: some View {
        Menu {
            Section("Show only") {
                Toggle("Food & drink", systemImage: "fork.knife", isOn: $layers.foodAndDrink)
                Toggle("Washrooms", systemImage: "toilet", isOn: $layers.washrooms)
            }
            Section("Mimo") {
                Toggle("Hidden gems", systemImage: "binoculars", isOn: $layers.hiddenGems)
                // Unchecked while there's nothing from Mimo to show.
                Toggle(isOn: Binding(
                    get: { layers.fromMimo && fromMimoCount > 0 },
                    set: { layers.fromMimo = $0 }
                )) {
                    Label(fromMimoTitle, systemImage: "bubble.left")
                }
                .disabled(fromMimoCount == 0)
                if fromMimoCount > 0 {
                    Button("Clear From Mimo", systemImage: "xmark.circle", action: onClearFromMimo)
                }
            }
        } label: {
            Label("Layers", systemImage: isFiltered ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Layers")
    }

    private var fromMimoTitle: String {
        fromMimoCount == 0 ? "From Mimo" : "From Mimo (\(fromMimoCount))"
    }

    private var isFiltered: Bool {
        layers.foodAndDrink || layers.washrooms || layers.hiddenGems
    }
}
