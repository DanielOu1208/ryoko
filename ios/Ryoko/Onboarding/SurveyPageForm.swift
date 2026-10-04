import SwiftUI

/// Where a page's form is shown: in the survey (the answer is written when you
/// tap Continue), or as Me's editor (edits apply as you make them).
enum SurveyFormContext {
    case survey
    case editor
}

/// One survey page's form, editing a `SurveyDraft`. The survey and Me's
/// editors show the same form, so the pickers are the same in both
/// (design §4.10). `extra` adds rows at the end (Me's "Mark as skipped").
struct SurveyPageForm<Extra: View>: View {
    let page: SurveyPage
    @Binding var draft: SurveyDraft
    var context: SurveyFormContext = .survey
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        switch page {
        case .homeBase:
            HomeBaseForm(home: $draft.homeBase, homeLanguage: draft.homeLanguage, context: context) {
                intro
            } extra: {
                extra()
            }
        default:
            ScrollViewReader { proxy in
                Form {
                    intro
                    sections
                    extra()
                    #if DEBUG
                    if DebugLaunchOptions.scrollAnchor != nil {
                        Color.clear.frame(height: 1).listRowBackground(Color.clear).id(Self.debugBottomID)
                    }
                    #endif
                }
                #if DEBUG
                .task {
                    // `-RyokoScrollToBottom 1` (screenshots of rows below the fold).
                    guard DebugLaunchOptions.scrollAnchor != nil else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    proxy.scrollTo(Self.debugBottomID, anchor: .bottom)
                }
                #endif
            }
        }
    }

    #if DEBUG
    private static var debugBottomID: String { "survey-form-bottom" }
    #endif

    /// The page's one-line explanation, above the first section.
    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.grid) {
            if context == .survey, page == .origin {
                Text("A few quick questions so Mimo can pick the right words for you. Skip anything, and change it later in Me.")
                    .font(.body)
            }
            Text(page.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: Theme.grid / 2, bottom: Theme.grid, trailing: Theme.grid / 2))
    }

    @ViewBuilder
    private var sections: some View {
        switch page {
        case .origin: OriginSections(draft: $draft)
        case .languages: LanguagesSections(draft: $draft)
        case .diet: DietSections(draft: $draft)
        case .allergies: AllergiesSections(draft: $draft)
        case .usual: UsualSections(draft: $draft)
        case .thisOrThat: ThisOrThatSections(personality: $draft.personality)
        case .homeBase: EmptyView()
        }
    }
}

extension SurveyPageForm where Extra == EmptyView {
    init(page: SurveyPage, draft: Binding<SurveyDraft>, context: SurveyFormContext = .survey) {
        self.init(page: page, draft: draft, context: context) { EmptyView() }
    }
}

// MARK: - 1. Where you're from

private struct OriginSections: View {
    @Binding var draft: SurveyDraft

    var body: some View {
        Section {
            NavigationLink {
                CountryPickerList(selection: $draft.nationality)
            } label: {
                LabeledContent("Country", value: draft.nationality.map(ProfileWording.country) ?? "Choose")
            }
            NavigationLink {
                LanguagePickerList(
                    title: "Home language",
                    isSelected: { $0 == draft.homeLanguage },
                    pick: { draft.homeLanguage = $0 },
                    dismissesOnPick: true
                )
            } label: {
                LabeledContent("Home language", value: ProfileWording.language(draft.homeLanguage))
            }
        }
        .onChange(of: draft.homeLanguage) { old, new in
            // Keep "Languages you speak" in step while it only holds the home language.
            if draft.spokenLanguages == [old] {
                draft.spokenLanguages = [new]
            } else if !draft.spokenLanguages.contains(new) {
                draft.spokenLanguages.insert(new, at: 0)
            }
        }
    }
}

/// A searchable list of countries; picking one goes back.
struct CountryPickerList: View {
    @Binding var selection: String?
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if query.isEmpty, let device = SurveyOptions.deviceCountry, device != selection {
                Section("This device") { row(device) }
            }
            Section {
                ForEach(matches, id: \.self, content: row)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search countries")
        .navigationTitle("Country")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if matches.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private var matches: [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SurveyOptions.countries }
        return SurveyOptions.countries.filter {
            ProfileWording.country($0).localizedStandardContains(query) || $0.caseInsensitiveCompare(query) == .orderedSame
        }
    }

    private func row(_ code: String) -> some View {
        Button {
            selection = code
            dismiss()
        } label: {
            CheckRow(title: ProfileWording.country(code), isSelected: code == selection)
        }
    }
}

// MARK: - 2. Languages you speak

private struct LanguagesSections: View {
    @Binding var draft: SurveyDraft

    var body: some View {
        Section {
            ChipGroup(
                values: chipLanguages,
                title: ProfileWording.language,
                isSelected: draft.spokenLanguages.contains,
                toggle: toggle
            )
            NavigationLink("More languages") {
                LanguagePickerList(
                    title: "Languages you speak",
                    isSelected: draft.spokenLanguages.contains,
                    pick: toggle,
                    dismissesOnPick: false
                )
            }
        } footer: {
            if draft.spokenLanguages.count >= SurveyOptions.maxSpokenLanguages {
                Text("That's the most Ryoko keeps: \(SurveyOptions.maxSpokenLanguages) languages.")
            }
        }
    }

    /// The common languages, plus any others already picked.
    private var chipLanguages: [String] {
        let extras = draft.spokenLanguages.filter { !SurveyOptions.commonLanguages.contains($0) }
        return SurveyOptions.commonLanguages + extras
    }

    private func toggle(_ tag: String) {
        if let index = draft.spokenLanguages.firstIndex(of: tag) {
            draft.spokenLanguages.remove(at: index)
        } else if draft.spokenLanguages.count < SurveyOptions.maxSpokenLanguages {
            draft.spokenLanguages.append(tag)
        }
    }
}

/// A searchable list of languages, for one pick (home language) or several.
struct LanguagePickerList: View {
    let title: String
    let isSelected: (String) -> Bool
    let pick: (String) -> Void
    let dismissesOnPick: Bool

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(matches, id: \.self) { tag in
            Button {
                pick(tag)
                if dismissesOnPick { dismiss() }
            } label: {
                CheckRow(title: ProfileWording.language(tag), isSelected: isSelected(tag))
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search languages")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if matches.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private var matches: [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SurveyOptions.allLanguages }
        return SurveyOptions.allLanguages.filter { ProfileWording.language($0).localizedStandardContains(query) }
    }
}

/// A list row with a trailing checkmark when selected.
struct CheckRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.grid)
            if isSelected {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
