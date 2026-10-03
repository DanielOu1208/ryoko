import SwiftUI

/// The Me tab, minimal (design §4.10): a read-only summary of the profile, the
/// romanization toggle, and a small developer section. Editing arrives with
/// onboarding (tier 2). Plain system background: no time-of-day gradient here.
struct MeView: View {
    /// The last row of the developer section (DEBUG), for `-RyokoScrollToBottom`.
    static let lastRowID = "me-last-row"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ProfileSummarySection()
                    AllergyCardSection() // the allergy card preview row (W3, ios/Ryoko/Show/)
                    DisplaySection()
                    DeveloperSection()
                }
                .navigationTitle("Me")
                #if DEBUG
                .task {
                    // `-RyokoScrollToBottom 1` (screenshots).
                    if DebugLaunchOptions.scrollAnchor != nil { proxy.scrollTo(Self.lastRowID, anchor: .bottom) }
                }
                #endif
            }
        }
    }
}

// MARK: - Profile

private struct ProfileSummarySection: View {
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        let profile = profileStore.profile
        Section {
            LabeledContent("From", value: Describe.country(profile.nationality))
            LabeledContent("Home language", value: Describe.language(profile.homeLanguage))
            LabeledContent("Speaks", value: Describe.list(profile.spokenLanguages?.map(Describe.language)))
            LabeledContent("Diet", value: Describe.list(profile.diet?.map(Describe.diet)))
            if let notes = profile.dietNotes, !notes.isEmpty {
                LabeledContent("Diet notes", value: notes)
            }
            allergies(profile.allergies)
            LabeledContent("Favourite foods", value: Describe.list(profile.favourites?.foods))
            LabeledContent("Favourite drinks", value: Describe.list(profile.favourites?.drinks))
            LabeledContent("Sweetness", value: Describe.taste(profile.taste?.sweetness, noun: "sweet"))
            LabeledContent("Spice", value: Describe.taste(profile.taste?.spice, noun: "spicy"))
            LabeledContent("Style", value: Describe.personality(profile.personality))
        } header: {
            Text("Profile")
        } footer: {
            Text("Ryoko uses this to pick phrases, tips and places. Editing arrives with the survey.")
        }

        Section("Home base") {
            if let home = profile.homeBase {
                VStack(alignment: .leading, spacing: 4) {
                    Text(home.name)
                    if let localName = home.localName {
                        LocalText(localName, languageTag: Describe.scriptTag(localName))
                            .foregroundStyle(.secondary)
                    }
                    if let address = home.address {
                        Text(address)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let addressLocal = home.addressLocal {
                        LocalText(addressLocal, languageTag: Describe.scriptTag(addressLocal))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("Not set")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func allergies(_ allergies: [Allergy]?) -> some View {
        if let allergies, !allergies.isEmpty {
            ForEach(Array(allergies.enumerated()), id: \.offset) { index, allergy in
                LabeledContent(index == 0 ? "Allergies" : "") {
                    // Severity is always written in words (design §9.2).
                    Text("\(Describe.allergen(allergy)) · \(Describe.severity(allergy.severity))")
                }
            }
        } else {
            LabeledContent("Allergies", value: allergies == nil ? "Skipped" : "None")
        }
    }
}

// MARK: - Display

private struct DisplaySection: View {
    @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true

    var body: some View {
        Section {
            Toggle("Show romanization", isOn: $showsRomanization)
        } header: {
            Text("Display")
        } footer: {
            Text("Pinyin and romaji under the local script. Turning it off only hides that line.")
        }
    }
}

// MARK: - Developer

private struct DeveloperSection: View {
    @Environment(APIStore.self) private var apiStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(AppSituationStore.self) private var situationStore

    @State private var urlDraft = ""
    @State private var urlError: String?
    @State private var confirmingReset = false

    var body: some View {
        @Bindable var apiStore = apiStore
        Section {
            Picker("API", selection: $apiStore.mode) {
                ForEach(APIStore.Mode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Server base URL", text: $urlDraft, prompt: Text("Server base URL"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(applyURL)
                if let urlError {
                    Text(urlError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if apiStore.baseURLOverride != nil {
                Button("Use build default URL") {
                    urlDraft = ""
                    applyURL()
                }
            }

            LabeledContent("Profile version") {
                Text(profileStore.profile.version.prefix(12))
                    .font(.footnote.monospaced())
            }
            // No destructive role: red is reserved for recording and allergy severity (design §9.2).
            Button("Reset to seed profile") { confirmingReset = true }
                .confirmationDialog("Reset to the seed profile?", isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button("Reset") { profileStore.resetToSeed() }
                } message: {
                    Text("Your edits to the profile are removed.")
                }

            #if DEBUG
            if situationStore.isPreviewing {
                Button("End preview") { situationStore.endPreview() }
            }
            Menu("Preview a sample place") {
                ForEach(SamplePlaces.hours, id: \.hour) { option in
                    Button("Tokyo ramen · \(option.label)") { situationStore.previewSample(hour: option.hour) }
                }
            }
            .id(MeView.lastRowID)
            #endif
        } header: {
            Text("Developer")
        } footer: {
            Text(footer)
        }
        .onAppear { urlDraft = apiStore.baseURLOverride ?? "" }
    }

    private var footer: String {
        var lines = ["Fixtures answer from the bundled examples, with no server."]
        if !apiStore.isLiveConfigured {
            lines.append("This build has no server URL or app token, so the live server isn't available.")
        }
        lines.append("A base URL applies to the next request. Leave it empty to use the build default.")
        return lines.joined(separator: " ")
    }

    private func applyURL() {
        if apiStore.setBaseURLOverride(urlDraft) {
            urlError = nil
            urlDraft = apiStore.baseURLOverride ?? ""
        } else {
            urlError = "Enter an http or https URL, like http://127.0.0.1:8792."
        }
    }
}

// MARK: - Wording

/// Plain-language descriptions of profile values, sentence case.
private enum Describe {
    static func country(_ code: String?) -> String {
        guard let code else { return "Skipped" }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }

    static func language(_ tag: String) -> String {
        if let row = LangCode(tag: tag) { return row.displayName }
        return Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    /// A comma-separated list; "None" for an empty list and "Skipped" for nil.
    static func list(_ items: [String]?) -> String {
        guard let items else { return "Skipped" }
        return items.isEmpty ? "None" : items.joined(separator: ", ")
    }

    static func diet(_ diet: Diet) -> String {
        switch diet {
        case .vegetarian: "Vegetarian"
        case .vegan: "Vegan"
        case .halal: "Halal"
        case .kosher: "Kosher"
        case .noPork: "No pork"
        case .noBeef: "No beef"
        case .glutenFree: "Gluten-free"
        case .lactoseFree: "Lactose-free"
        }
    }

    static func allergen(_ allergy: Allergy) -> String {
        switch allergy.id {
        case .egg: "Egg"
        case .milk: "Milk"
        case .mustard: "Mustard"
        case .peanut: "Peanut"
        case .crustaceanMollusc: "Shellfish"
        case .fish: "Fish"
        case .sesame: "Sesame"
        case .soy: "Soy"
        case .sulphite: "Sulphites"
        case .treeNut: "Tree nuts"
        case .wheat: "Wheat"
        case .custom: allergy.label ?? "Other"
        }
    }

    static func severity(_ severity: Severity) -> String {
        switch severity {
        case .mild: "mild"
        case .serious: "serious"
        case .lifeThreatening: "life-threatening"
        }
    }

    /// Taste sliders run 0–4, where 2 is "as usual".
    static func taste(_ value: Int?, noun: String) -> String {
        switch value {
        case nil: "Skipped"
        case 0?: "Much less \(noun)"
        case 1?: "Less \(noun)"
        case 2?: "As usual"
        case 3?: "More \(noun)"
        default: "Much more \(noun)"
        }
    }

    static func personality(_ personality: Personality?) -> String {
        guard let personality else { return "Skipped" }
        let parts: [String] = [
            personality.rhythm.map { $0 == .earlyBird ? "Early bird" : "Night owl" },
            personality.food.map { $0 == .localFavourite ? "Local favourite" : "My usual" },
            personality.budget.map { $0 == .save ? "Save" : "Splurge" },
            personality.vibe.map { $0 == .quiet ? "Quiet" : "Lively" },
        ].compactMap(\.self)
        return parts.isEmpty ? "Skipped" : parts.joined(separator: " · ")
    }

    /// A language tag for local text with no tag of its own: kana means
    /// Japanese, other Han text is treated as Simplified Chinese.
    static func scriptTag(_ text: String) -> String {
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return LangCode.ja.tag }
        if text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) { return LangCode.zhHans.tag }
        return LangCode.en.tag
    }
}

#Preview {
    MeView()
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppSituationStore.preview(nil))
}
