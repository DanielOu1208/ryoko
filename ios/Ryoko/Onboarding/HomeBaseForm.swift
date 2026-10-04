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
    @State private var showsMapPicker = false
    @Environment(AppSituationStore.self) private var situationStore

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
                    Button {
                        showsMapPicker = true
                    } label: {
                        HStack {
                            Label("Pick on map", systemImage: "mappin.and.ellipse")
                                .foregroundStyle(.primary)
                            Spacer(minLength: Theme.grid)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                } footer: {
                    if let failure = search.failure { Text(failure) }
                }
                extra()
            }
        }
        .navigationDestination(isPresented: $showsMapPicker) {
            HomeBaseMapPicker(
                start: home?.coordinate ?? situationStore.situation?.place?.coordinate,
                homeLanguage: homeLanguage
            ) { picked in
                home = picked
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
        if OnboardingDebugOptions.mapPickerAction != nil {
            showsMapPicker = true
            return
        }
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
    /// The visible span in degrees of latitude; picking needs street level.
    @State private var span: CLLocationDegrees = 0
    @State private var isResolving = false
    @Environment(\.dismiss) private var dismiss

    /// About 5 km of latitude: closer than this, the pin marks a street.
    private static let maxPickSpan: CLLocationDegrees = 0.05
    private var isZoomedIn: Bool { span > 0 && span <= Self.maxPickSpan }

    /// - Parameter start: where to open (the home base, or the place you're
    ///   at); nil opens at your location, or the whole map without one.
    init(start: Coordinate?, homeLanguage: String, onPick: @escaping (HomeBase) -> Void) {
        self.homeLanguage = homeLanguage
        self.onPick = onPick
        if let start {
            let center = CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon)
            let region = MKCoordinateRegion(center: center, latitudinalMeters: 800, longitudinalMeters: 800)
            _position = State(initialValue: .region(region))
            _center = State(initialValue: center)
            _span = State(initialValue: region.span.latitudeDelta)
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
            span = context.region.span.latitudeDelta
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
            SurveyContinueButton(title: buttonTitle) {
                Task { await pick() }
            }
            .disabled(center == nil || isResolving || !isZoomedIn)
        }
        .navigationTitle("Pick on map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        #if DEBUG
        .task {
            // `-RyokoOnboardingMapPicker use`: tap "Use this spot" once the map settles.
            guard OnboardingDebugOptions.mapPickerAction == "use" else { return }
            try? await Task.sleep(for: .seconds(3))
            await pick()
        }
        #endif
    }

    private var buttonTitle: String {
        if isResolving { return "Finding the address…" }
        return isZoomedIn ? "Use this spot" : "Zoom in to pick a spot"
    }

    private func pick() async {
        guard let center, isZoomedIn else { return }
        isResolving = true
        defer { isResolving = false }
        guard let home = await HomeBaseLocalizer.homeBase(at: center, homeLanguage: homeLanguage) else { return }
        onPick(home)
        dismiss()
    }
}
