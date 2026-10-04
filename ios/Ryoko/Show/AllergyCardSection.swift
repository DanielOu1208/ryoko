import SwiftUI
import ThinkingOrbs

/// Me → "Allergy card" (design §4.10): a preview row that opens the card in
/// Show mode. It uses the situation's local language when there are templates
/// for it; otherwise it offers the template languages to pick from.
struct AllergyCardSection: View {
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        Section {
            AllergyCardPreviewRow()
        } header: {
            Text("Allergy card")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        let profile = profileStore.profile
        let hasFreeText = (AllergyCardStore.allergies(in: profile) ?? []).contains { $0.id == .custom }
        return hasFreeText
            ? "Listed allergens use the bundled wording and work offline. Allergens you typed in are written by Mimo and need a connection the first time."
            : "Uses the bundled wording, so it works offline."
    }
}

/// The row itself: "Show allergy card", the language and the allergens.
struct AllergyCardPreviewRow: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(AppRouter.self) private var router
    @Environment(\.ryokoAPI) private var api

    @State private var presenter = AllergyCardPresenter()

    var body: some View {
        let profile = profileStore.profile
        let local = situationStore.situation?.localLanguage
        let hasAllergies = !(AllergyCardStore.allergies(in: profile) ?? []).isEmpty
        Group {
            if !hasAllergies {
                let skipped = profile.allergies == nil
                label(subtitle: skipped ? "Allergies were skipped in your profile" : "No allergies in your profile", language: nil, symbol: nil)
            } else if let local, AllergyCardStore.unavailability(profile: profile, language: local) == nil {
                Button { open(in: local) } label: {
                    label(subtitle: AllergyCardStore.summary(profile: profile, language: local), language: local, symbol: "arrow.up.left.and.arrow.down.right")
                }
            } else {
                // No templates for where you are (or nowhere yet): pick a language.
                Menu {
                    ForEach(AllergyCardStore.templateLanguages, id: \.self) { lang in
                        Button("In \(lang.displayName)") { open(in: lang.tag) }
                    }
                } label: {
                    label(subtitle: AllergyCardStore.summary(profile: profile, language: LangCode.zhHans.tag), language: nil, symbol: "chevron.up.chevron.down")
                }
                .accessibilityHint("Choose the language to show it in")
            }
        }
        .tint(.primary)
        .allergyCardFailureAlert(presenter)
        #if DEBUG
        .task {
            // `-RyokoMeShowAllergy zh-Hans`: open the card from this row, once per launch.
            guard !Self.didRunLaunchHook, let tag = ShowDebugOptions.meAllergyLanguage else { return }
            Self.didRunLaunchHook = true
            open(in: tag)
        }
        #endif
    }

    #if DEBUG
    private static var didRunLaunchHook = false
    #endif

    /// `symbol` nil means there's nothing to open (no allergies).
    private func label(subtitle: String, language: String?, symbol: String?) -> some View {
        HStack(spacing: Theme.grid * 1.5) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show allergy card")
                    .foregroundStyle(symbol == nil ? .secondary : .primary)
                Text(languageLine(language) + subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if presenter.isLoading {
                // Mimo writing the card in the local language.
                ThinkingOrb(.solving, size: .small)
                    .accessibilityLabel("Writing the allergy card")
            } else if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }

    private func languageLine(_ tag: String?) -> String {
        guard let tag, let row = LangCode(tag: tag) else { return "" }
        return "In \(row.displayName) · "
    }

    private func open(in language: String) {
        presenter.present(profile: profileStore.profile, language: language, api: api, router: router)
    }
}
