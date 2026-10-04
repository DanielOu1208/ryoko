import SwiftUI

/// The Me tab (design §4.10): the profile from the survey, each section
/// editable with the survey's own pickers; the home base for the taxi card;
/// Redo survey; the allergy card preview; the romanization toggle; credits;
/// and a small developer section. Plain system background: no time-of-day
/// gradient here.
///
/// Every edit goes through `ProfileStore`, so `profile.version` changes and the
/// server's caches (keyed on it) regenerate.
struct MeView: View {
    /// The last row of the developer section (DEBUG), for `-RyokoScrollToBottom`.
    static let lastRowID = "me-last-row"

    @Environment(ProfileStore.self) private var profileStore
    @State private var path: [SurveyPage] = []
    @State private var isRedoingSurvey = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    ProfileSection()
                    HomeBaseSection()
                    RedoSurveySection(isPresented: $isRedoingSurvey)
                    AllergyCardSection() // the allergy card preview row (W3, ios/Ryoko/Show/)
                    DisplaySection()
                    CreditsSection()
                    DeveloperSection()
                }
                .navigationTitle("Me")
                .navigationDestination(for: SurveyPage.self) { page in
                    ProfileEditor(page: page, profile: profileStore.profile)
                }
                #if DEBUG
                .task {
                    // `-RyokoScrollToBottom 1` (screenshots).
                    if DebugLaunchOptions.scrollAnchor != nil { proxy.scrollTo(Self.lastRowID, anchor: .bottom) }
                }
                #endif
            }
        }
        .fullScreenCover(isPresented: $isRedoingSurvey) {
            SurveyFlowView(
                mode: .redo,
                draft: SurveyDraft(profile: profileStore.profile),
                onFinish: { profile in
                    profileStore.completeOnboarding(with: profile)
                    isRedoingSurvey = false
                },
                onCancel: { isRedoingSurvey = false }
            )
        }
        #if DEBUG
        .task {
            // `-RyokoMeEdit <page>|redo` (screenshots).
            if OnboardingDebugOptions.meRedoesSurvey {
                isRedoingSurvey = true
            } else if let page = OnboardingDebugOptions.meEditorPage, path.isEmpty {
                path = [page]
            }
        }
        #endif
    }
}

// MARK: - Profile

/// One row per survey page, each opening that page's editor.
private struct ProfileSection: View {
    @Environment(ProfileStore.self) private var profileStore

    private static let pages: [SurveyPage] = SurveyPage.allCases.filter { $0 != .homeBase }

    var body: some View {
        let profile = profileStore.profile
        Section {
            ForEach(Self.pages) { page in
                NavigationLink(value: page) {
                    LabeledContent(page.meLabel) {
                        Text(ProfileWording.summary(of: page, in: profile))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Ryoko uses this to pick phrases, tips and places. Changes apply right away.")
        }
    }
}

/// The home base for the taxi card; opens its editor (search to change it).
private struct HomeBaseSection: View {
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        Section {
            NavigationLink(value: SurveyPage.homeBase) {
                if let home = profileStore.profile.homeBase {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(home.name)
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
                } else {
                    LabeledContent("Not set", value: "Add")
                }
            }
        } header: {
            Text("Home base")
        } footer: {
            Text("Where you're staying. The taxi card takes you back here.")
        }
    }
}

private struct RedoSurveySection: View {
    @Binding var isPresented: Bool

    var body: some View {
        Section {
            Button("Redo survey") { isPresented = true }
        } footer: {
            Text("Goes through the questions again, starting from your current answers.")
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

// MARK: - Credits

/// Third-party credits (THIRD_PARTY_NOTICES.md).
private struct CreditsSection: View {
    var body: some View {
        Section("Credits") {
            Link(destination: URL(string: "https://github.com/jeremy-prt/bloub")!) {
                LabeledContent("Mimo's avatar", value: "bloub, MIT License")
            }
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
            if profileStore.isOnboarded {
                Button("Show the survey on next launch") { profileStore.resetOnboarding() }
            } else {
                LabeledContent("Survey", value: "Shows on next launch")
            }
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

#Preview {
    MeView()
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppSituationStore.preview(nil))
        .environment(AppRouter())
}
