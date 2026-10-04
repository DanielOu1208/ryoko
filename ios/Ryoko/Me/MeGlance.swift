import SwiftUI
import ThinkingOrbs

// MARK: - Allergy card

/// Me's allergy card at a glance (design §4.10, #69): its title in the local
/// script, then each allergen with its severity in words, most serious first.
/// Tapping it opens the full card in Show mode, through the same presenter as
/// a place card's Allergy button. With no templates for where you are, tapping
/// asks which language to show it in. With no allergies, it's a quiet row that
/// opens the allergies editor.
struct MeAllergySection: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(AppSituationStore.self) private var situationStore
    @Environment(AppRouter.self) private var router
    @Environment(\.ryokoAPI) private var api

    @State private var presenter = AllergyCardPresenter()

    var body: some View {
        let profile = profileStore.profile
        let allergies = Self.sorted(AllergyCardStore.allergies(in: profile) ?? [])
        Section {
            if allergies.isEmpty {
                NavigationLink(value: MeRoute.editor(.allergies)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(profile.allergies == nil ? "Allergies skipped" : "No allergies", systemImage: "allergens")
                        Text("Add one and your allergy card is ready to show in the local language.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                card(allergies: allergies, profile: profile)
                NavigationLink(value: MeRoute.editor(.allergies)) {
                    Text("Edit allergies")
                }
            }
        } header: {
            Text("Allergy card")
        }
        .allergyCardFailureAlert(presenter)
        #if DEBUG
        .task {
            // `-RyokoMeShowAllergy zh-Hans`: open the card from Me, once per launch.
            guard !Self.didRunLaunchHook, let tag = ShowDebugOptions.meAllergyLanguage else { return }
            Self.didRunLaunchHook = true
            open(in: tag)
        }
        #endif
    }

    #if DEBUG
    private static var didRunLaunchHook = false
    #endif

    /// The situation's language when there are templates for it.
    private var language: String? {
        guard let local = situationStore.situation?.localLanguage,
              AllergyCardStore.unavailability(profile: profileStore.profile, language: local) == nil else { return nil }
        return local
    }

    @ViewBuilder
    private func card(allergies: [Allergy], profile: Profile) -> some View {
        if let language {
            Button { open(in: language) } label: {
                content(allergies: allergies, language: language)
            }
            .tint(.primary)
            .accessibilityHint("Shows the card full screen")
        } else {
            Menu {
                ForEach(AllergyCardStore.templateLanguages, id: \.self) { lang in
                    Button("In \(lang.displayName)") { open(in: lang.tag) }
                }
            } label: {
                content(allergies: allergies, language: nil)
            }
            .tint(.primary)
            .accessibilityHint("Choose the language to show it in")
        }
    }

    private func content(allergies: [Allergy], language: String?) -> some View {
        let templates = language.flatMap { AllergyTemplates.bundled?.language(for: $0) }
        return VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
            HStack(alignment: .firstTextBaseline) {
                if let templates {
                    LocalText(templates.templates.title.local, languageTag: templates.tag)
                        .font(.title2.bold())
                } else {
                    Text("Ready to show")
                        .font(.title2.bold())
                }
                Spacer(minLength: Theme.grid)
                if presenter.isLoading {
                    ThinkingOrb(.solving, size: .small)
                        .accessibilityLabel("Writing the allergy card")
                } else {
                    Image(systemName: language == nil ? "chevron.up.chevron.down" : "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.grid) {
                ForEach(Array(allergies.enumerated()), id: \.offset) { _, allergy in
                    HStack(spacing: Theme.grid) {
                        Image(systemName: Self.symbol(allergy.severity))
                            .foregroundStyle(Self.colour(allergy.severity))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(ProfileWording.allergen(allergy))
                            .font(.body.weight(.medium))
                        Spacer(minLength: Theme.grid)
                        Text(ProfileWording.severityTitle(allergy.severity))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Self.colour(allergy.severity))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(footer(language: language))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.grid)
        .contentShape(.rect)
    }

    private func footer(language: String?) -> String {
        guard let language, let row = LangCode(tag: language) else {
            return "No card for the language here yet. Tap to choose one."
        }
        return "Tap to show it in \(row.displayName), full screen."
    }

    private func open(in language: String) {
        presenter.present(profile: profileStore.profile, language: language, api: api, router: router)
    }

    // MARK: Severity (design §9.2: red only for serious and life-threatening; always in words)

    private static let rank: [Severity: Int] = [.lifeThreatening: 0, .serious: 1, .mild: 2]

    static func sorted(_ allergies: [Allergy]) -> [Allergy] {
        allergies.enumerated()
            .sorted { (rank[$0.element.severity] ?? 3, $0.offset) < (rank[$1.element.severity] ?? 3, $1.offset) }
            .map(\.element)
    }

    private static func symbol(_ severity: Severity) -> String {
        switch severity {
        case .mild: "info.circle"
        case .serious: "exclamationmark.circle.fill"
        case .lifeThreatening: "exclamationmark.triangle.fill"
        }
    }

    private static func colour(_ severity: Severity) -> Color {
        severity == .mild ? .secondary : .red
    }
}

// MARK: - At a glance

/// Diet, your usual and the home base, each opening its editor. The rest of
/// the profile is in Settings.
struct MeGlanceSection: View {
    @Environment(ProfileStore.self) private var profileStore

    private static let rows: [(page: SurveyPage, symbol: String)] = [
        (.diet, "carrot"),
        (.usual, "cup.and.saucer"),
        (.homeBase, "house"),
    ]

    var body: some View {
        let profile = profileStore.profile
        Section {
            ForEach(Self.rows, id: \.page) { row in
                NavigationLink(value: MeRoute.editor(row.page)) {
                    LabeledContent {
                        Text(ProfileWording.summary(of: row.page, in: profile))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label(row.page.meLabel, systemImage: row.symbol)
                    }
                }
            }
        } header: {
            Text("Your profile")
        }
    }
}
