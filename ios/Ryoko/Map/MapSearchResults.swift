import SwiftUI

/// Places matching a submitted search, in one solid card. A row opens that
/// place's card.
struct MapSearchResultsList: View {
    let results: [MapPlace]
    let languageTag: String?
    let onSelect: (MapPlace) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MapListCard {
                    if results.isEmpty {
                        Text("No places found. Try another name, in English or the local script.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(MapListLayout.inset)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, place in
                        if index > 0 { MapListDivider() }
                        MapPlaceRow(place: place, languageTag: languageTag) { onSelect(place) }
                    }
                }
                FoursquareCredit(places: results.map(\.place), keepsSpace: true)
                    .padding(.horizontal, Theme.margin)
                    .padding(.top, Theme.grid)
            }
            .padding(.bottom, Theme.grid * 3)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// "Results for “ramen”" with Back to the list.
struct MapResultsHeader: View {
    let query: String
    let count: Int
    let onBack: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.grid * 1.5) {
            Button("Back", systemImage: "chevron.backward", action: onBack)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Back to the list")
            VStack(alignment: .leading, spacing: 2) {
                Text("Results for \u{201C}\(query)\u{201D}")
                    .font(.headline)
                Text(count == 1 ? "1 place" : "\(count) places")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, Theme.grid * 1.5)
    }
}
