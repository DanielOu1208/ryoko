import MapKit
import SwiftUI

/// The Map's search field (design §4.7): a glass capsule floating over the map
/// with the panel's side margins. Native `.searchable` sits in the navigation
/// bar, with wider margins than the panel and an empty bar row above it.
///
/// `search.isPresented` is the search mode: focusing the field starts it, and
/// the cancel button, a picked suggestion or a submitted query ends it. Hiding
/// the keyboard alone (scrolling the suggestions) keeps it.
///
/// At rest the field is a compact "Search" pill on the leading side, with the
/// map buttons (`trailing`: your location, Layers) on the same row. Tapping it
/// widens it to the full field, and the buttons step aside until search ends.
struct MapSearchBar<Trailing: View>: View {
    @Bindable var search: MapSearch
    let onSubmit: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var pillWidth: CGFloat = 132

    var body: some View {
        GlassEffectContainer(spacing: Theme.grid) {
            HStack(spacing: Theme.grid) {
                field
                    // At rest the pill sits centred, with the buttons on the trailing side.
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        if !search.isPresented {
                            trailing()
                                .transition(.blurReplace)
                        }
                    }
                if search.isPresented {
                    Button("Cancel search", systemImage: "xmark") { search.end() }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.medium))
                        .frame(width: height, height: height)
                        .contentShape(.circle)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .buttonStyle(.plain)
                        .transition(.blurReplace)
                }
            }
        }
        .animation(.smooth, value: search.isPresented)
        .onChange(of: isFocused) { _, focused in
            if focused { search.isPresented = true }
        }
        .onChange(of: search.isPresented, initial: true) { _, presented in
            isFocused = presented
        }
    }

    private var field: some View {
        HStack(spacing: Theme.grid) {
            Image(systemName: "magnifyingglass")
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            TextField("Search places", text: $search.text, prompt: Text(""))
                .fontWeight(.medium)
                // Its own placeholder in the label colour: the system one is too
                // faint over the glass and the map, and ignores a colour.
                .overlay(alignment: .leading) {
                    if search.text.isEmpty {
                        Text(search.isPresented ? "Search places" : "Search")
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit(onSubmit)
            if !search.text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { search.text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: height)
        // A pill at rest; the full width while searching (or with a query).
        .frame(width: search.isPresented || !search.text.isEmpty ? nil : pillWidth)
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Suggestions under the search field while typing: a card sized to its rows
/// that scrolls once they reach the keyboard.
struct MapSearchSuggestions: View {
    let suggestions: [MKLocalSearchCompletion]
    let onPick: (MKLocalSearchCompletion) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
                    .scrollDismissesKeyboard(.immediately)
            }
            .background(.regularMaterial, in: Theme.cardShape)
            .clipShape(Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 18, y: 4)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, completion in
                if index > 0 {
                    Divider().padding(.leading, 20)
                }
                Button {
                    onPick(completion)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(completion.title)
                            .foregroundStyle(.primary)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
