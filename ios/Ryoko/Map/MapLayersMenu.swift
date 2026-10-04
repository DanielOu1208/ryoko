import SwiftUI

/// The layer toggles in a native menu (design §4.7), behind a glass button
/// under the location button: Food & drink and Washrooms filter the map's
/// points of interest; Hidden gems pins Mimo's picks; From Mimo shows what the
/// Mimo tab sent, with a clear action.
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
            Image(systemName: isFiltered ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
                .font(.body.weight(.medium))
                // A fixed 44 pt control like MapKit's location button above
                // it: the glyph mustn't outgrow it at accessibility sizes
                // (the large content viewer shows it bigger instead).
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .menuActionDismissBehavior(.disabled)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Layers")
        .accessibilityShowsLargeContentViewer {
            Label("Layers", systemImage: "square.3.layers.3d")
        }
    }

    /// The same size as MapKit's location button above it.
    private static let size: CGFloat = 44

    private var fromMimoTitle: String {
        fromMimoCount == 0 ? "From Mimo" : "From Mimo (\(fromMimoCount))"
    }

    private var isFiltered: Bool {
        layers.foodAndDrink || layers.washrooms || layers.hiddenGems
    }
}
