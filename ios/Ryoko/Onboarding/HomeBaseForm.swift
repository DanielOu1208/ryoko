import MapKit
import os
import SwiftUI

// MARK: - 7. Where you're staying

/// The home base page (design §4.1) and Me's home base editor (§4.10): search
/// with `MKLocalSearchCompleter`, or pick a spot on the map. Optional.
struct HomeBaseForm<Intro: View, Extra: View>: View {
    @Binding var home: HomeBase?
    let homeLanguage: String
    let context: SurveyFormContext
    @ViewBuilder var intro: () -> Intro
    @ViewBuilder var extra: () -> Extra

    @State private var search = HomeBaseSearch()

    var body: some View {
        Form {
            if search.isSearching {
                suggestions
            } else {
                intro()
                if let home {
                    chosen(home)
                }
                Section {
                    NavigationLink {
                        HomeBaseMapPicker(start: home?.coordinate, homeLanguage: homeLanguage) { picked in
                            self.home = picked
                        }
                    } label: {
                        Label("Pick on map", systemImage: "mappin.and.ellipse")
                    }
                } footer: {
                    if let failure = search.failure { Text(failure) }
                }
                extra()
            }
        }
        .searchable(
            text: $search.text,
            isPresented: $search.isPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: home == nil ? "Hotel, address or area" : "Change your home base"
        )
        .autocorrectionDisabled()
        .preference(key: SurveyHidesContinueKey.self, value: search.isPresented || search.isSearching)
        .overlay {
            if search.isResolving {
                ProgressView()
                    .controlSize(.large)
                    .padding(Theme.grid * 3)
                    .background(.regularMaterial, in: .rect(cornerRadius: Theme.grid * 2, style: .continuous))
            }
        }
        #if DEBUG
        .task { await runDebugSearch() }
        #endif
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestions: some View {
        Section {
            ForEach(search.suggestions, id: \.self) { completion in
                Button {
                    Task { await choose(completion) }
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
                    .contentShape(.rect)
                }
                .disabled(search.isResolving)
            }
        } footer: {
            if search.hasNoResults {
                Text("No matches. Try the hotel's name with its city, or pick it on the map.")
            }
        }
    }

    private func choose(_ completion: MKLocalSearchCompletion) async {
        guard let picked = await search.homeBase(for: completion, homeLanguage: homeLanguage) else { return }
        home = picked
        search.finish()
    }

    // MARK: The chosen place

    @ViewBuilder
    private func chosen(_ home: HomeBase) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(home.name)
                    .font(.headline)
                if let localName = home.localName, localName != home.name {
                    LocalText(localName, languageTag: ProfileWording.scriptTag(localName))
                        .foregroundStyle(.secondary)
                }
                if let address = home.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let addressLocal = ProfileWording.distinctLocalAddress(of: home) {
                    LocalText(addressLocal, languageTag: ProfileWording.scriptTag(addressLocal))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            HomeBaseMapTile(home: home)
                .listRowInsets(EdgeInsets())

            if context == .editor {
                TextField("Name in the local script (optional)", text: localNameBinding)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Your home base")
        } footer: {
            if context == .editor {
                Text("If you know the hotel's name in the local script, add it here and the taxi card shows it.")
            }
        }
    }

    private var localNameBinding: Binding<String> {
        Binding {
            home?.localName ?? ""
        } set: { text in
            let capped = String(text.prefix(SurveyOptions.maxHomeBaseNameLength))
            home?.localName = capped.trimmingCharacters(in: .whitespaces).isEmpty ? nil : capped
        }
    }

    #if DEBUG
    /// `-RyokoOnboardingSearch "<query>"` types a query on this page; with
    /// `-RyokoOnboardingPick 1` (or the auto run) the first suggestion is picked too.
    private func runDebugSearch() async {
        guard let query = OnboardingDebugOptions.homeBaseQuery, home == nil || context == .editor else { return }
        search.isPresented = true
        search.text = query
        guard OnboardingDebugOptions.picksHomeBase else { return }
        for _ in 0..<40 where search.suggestions.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let first = search.suggestions.first else {
            RyokoLog.onboarding.error("Auto run: no suggestions for the home base query")
            return
        }
        await choose(first)
    }
    #endif
}

/// A small, still map of the home base.
private struct HomeBaseMapTile: View {
    let home: HomeBase

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: home.coordinate.lat, longitude: home.coordinate.lon)
        Map(
            initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 700, longitudinalMeters: 700)),
            interactionModes: []
        ) {
            Marker(home.name, coordinate: center)
                .tint(.primary)
        }
        .frame(height: 160)
        .id("\(home.coordinate.lat),\(home.coordinate.lon)")
        .accessibilityLabel("Map of \(home.name)")
    }
}

/// "Pick on map": move the map until the pin sits on the place, then use it.
struct HomeBaseMapPicker: View {
    let homeLanguage: String
    let onPick: (HomeBase) -> Void

    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D?
    @State private var isResolving = false
    @Environment(\.dismiss) private var dismiss

    init(start: Coordinate?, homeLanguage: String, onPick: @escaping (HomeBase) -> Void) {
        self.homeLanguage = homeLanguage
        self.onPick = onPick
        if let start {
            let center = CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon)
            _position = State(initialValue: .region(MKCoordinateRegion(center: center, latitudinalMeters: 800, longitudinalMeters: 800)))
            _center = State(initialValue: center)
        } else {
            _position = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            center = context.region.center
        }
        .overlay {
            // The pin's tip marks the centre of the map.
            Image(systemName: "mappin")
                .font(.largeTitle)
                .foregroundStyle(.primary)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .alignmentGuide(VerticalAlignment.center) { $0[.bottom] }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .bottom) {
            SurveyContinueButton(title: isResolving ? "Finding the address…" : "Use this spot") {
                Task { await pick() }
            }
            .disabled(center == nil || isResolving)
        }
        .navigationTitle("Pick on map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func pick() async {
        guard let center else { return }
        isResolving = true
        defer { isResolving = false }
        guard let home = await HomeBaseLocalizer.homeBase(at: center, homeLanguage: homeLanguage) else { return }
        onPick(home)
        dismiss()
    }
}
