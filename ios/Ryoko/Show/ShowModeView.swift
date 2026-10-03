import SwiftUI

/// Show mode (design §4.4): a full-screen card meant to be handed to someone
/// else. `RootTabView` presents it for `router.show`; a view that is itself in a
/// sheet presents it with its own `.fullScreenCover`.
///
/// - A plain system background (white or black), no gradient: contrast first.
/// - **Flip** turns the content 180° for someone across a counter; the
///   controls stay the right way up for you. **Done** closes it.
/// - Brightness goes to max and the idle timer is off while it's open
///   (`ShowScreenKeeper`); both are restored on close.
/// - A haptic on open. Speak arrives in tier 2.
struct ShowModeView: View {
    let content: ShowContent

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFlipped = false
    @State private var hasAppeared = false

    var body: some View {
        NavigationStack {
            ShowContentView(content: content)
                .rotationEffect(.degrees(isFlipped ? 180 : 0))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .accessibilityHint(isFlipped ? "Turned upside down for the person across from you" : "")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Text and icon: toolbar labels otherwise show the icon only.
                        Button(action: flip) {
                            HStack(spacing: Theme.grid * 0.75) {
                                Image(systemName: "arrow.up.arrow.down")
                                Text(isFlipped ? "Flip back" : "Flip")
                            }
                        }
                        .accessibilityLabel(isFlipped ? "Flip back" : "Flip")
                        .accessibilityHint("Turns the card upside down for someone across from you")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        }
        .tint(Theme.tint)
        .background(ShowScreenKeeper(isActive: scenePhase == .active).accessibilityHidden(true))
        .sensoryFeedback(.impact(weight: .medium), trigger: hasAppeared) { _, appeared in appeared }
        .sensoryFeedback(.selection, trigger: isFlipped)
        .statusBarHidden()
        .onAppear {
            hasAppeared = true
            #if DEBUG
            if ShowDebugOptions.startsFlipped { isFlipped = true }
            #endif
        }
        #if DEBUG
        .task {
            guard let delay = ShowDebugOptions.autoCloseAfter else { return }
            try? await Task.sleep(for: delay)
            dismiss()
        }
        #endif
    }

    private func flip() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth) {
            isFlipped.toggle()
        }
    }
}

/// The layout for each kind of content.
private struct ShowContentView: View {
    let content: ShowContent

    var body: some View {
        switch content {
        case let .phrase(phrase): ShowPhraseView(phrase: phrase)
        case let .allergy(card): ShowAllergyView(card: card)
        case let .taxi(card): ShowTaxiView(card: card)
        }
    }
}

// MARK: - Phrase

/// The local script as large as fits, romanization below it in smaller type,
/// and the gloss smallest, at the bottom.
private struct ShowPhraseView: View {
    let phrase: Phrase

    @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true
    /// The starting size; `minimumScaleFactor` shrinks it until the phrase fits.
    @ScaledMetric(relativeTo: .largeTitle) private var scriptSize: CGFloat = 120

    var body: some View {
        VStack(spacing: Theme.grid * 3) {
            LocalText(phrase.local, languageTag: phrase.lang)
                .font(.system(size: scriptSize, weight: .semibold))
                .minimumScaleFactor(0.1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            // Romanization and gloss are for you; the script is for them. At the
            // largest text sizes they stop growing at AX1, so the script keeps the screen.
            Group {
                if showsRomanization, let romanization = phrase.romanization {
                    Text(romanization)
                        .font(.title2)
                }
                Text(phrase.gloss)
                    .font(.body)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .pageMargins()
        .padding(.vertical, Theme.grid * 3)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Allergy

/// The allergy card: a scrollable stack, each line in local script at `.title`
/// with your language below at `.body`, and the severity always in words.
private struct ShowAllergyView: View {
    let card: AllergyShowCard

    @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.grid * 3) {
                VStack(alignment: .leading, spacing: Theme.grid) {
                    LocalText(card.titleLocal, languageTag: card.language)
                        .font(.largeTitle.bold())
                    if let titleHome = card.titleHome {
                        Text(titleHome)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    if let note = cardNote {
                        NotReviewedNote(text: note)
                    }
                }
                ForEach(card.lines) { line in
                    Divider()
                    AllergyLineView(
                        line: line,
                        language: card.language,
                        marksUnreviewed: line.allergenId == .custom && hasTemplateLines
                    )
                }
                Divider()
                VStack(alignment: .leading, spacing: Theme.grid) {
                    LocalText(card.requestLocal, languageTag: card.language)
                        .font(.title.weight(.semibold))
                    if showsRomanization, let romanization = card.requestRomanization {
                        Text(romanization)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(card.requestHome)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .pageMargins()
            .padding(.vertical, Theme.grid * 2)
        }
    }

    private var hasTemplateLines: Bool {
        card.lines.contains { $0.allergenId != .custom }
    }

    /// "Not reviewed" for the whole card: when its templates haven't been checked
    /// by a native reader, or when every line came from the server. On a card
    /// that mixes reviewed templates with typed-in allergens, only those lines
    /// are tagged.
    private var cardNote: String? {
        guard !card.reviewed else { return nil }
        guard hasTemplateLines else {
            return "Not reviewed. Written by Mimo from what you typed; no native speaker has checked it."
        }
        let templatesReviewed = AllergyTemplates.bundled?.language(for: card.language)?.templates.reviewed ?? false
        return templatesReviewed ? nil : "Not reviewed. No native speaker has checked this wording yet."
    }
}

/// One allergen: the severity in words (local, then yours), the line in local
/// script, and your language below.
private struct AllergyLineView: View {
    let line: AllergyShowCard.Line
    let language: String
    /// Tag a free-text line on a card that also has template lines.
    let marksUnreviewed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid) {
            SeverityLabel(severity: line.severity, local: line.severityLocal, language: language)
            LocalText(line.local, languageTag: language)
                .font(.title)
                .fixedSize(horizontal: false, vertical: true)
            Text(line.home)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if marksUnreviewed {
                NotReviewedNote(text: "Not reviewed. Written by Mimo from what you typed.")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "严重过敏 · Serious": always words, never colour alone. Red is reserved for
/// allergy severity (design §9.2); mild stays neutral.
private struct SeverityLabel: View {
    let severity: Severity
    let local: String?
    let language: String

    var body: some View {
        let icon = Text(Image(systemName: symbol))
        let words = if let local {
            // The "·" is glued to the local label, so no line starts with it.
            Text("\(icon) \(Text.local(local, languageTag: language))\u{00A0}· \(severity.displayName)")
        } else {
            Text("\(icon) \(severity.displayName)")
        }
        words
            .font(.headline)
            .foregroundStyle(severity == .mild ? Color.secondary : Color.red)
            .accessibilityLabel("Severity: \(severity.displayName)")
    }

    private var symbol: String {
        switch severity {
        case .mild: "info.circle"
        case .serious: "exclamationmark.circle.fill"
        case .lifeThreatening: "exclamationmark.triangle.fill"
        }
    }
}

private struct NotReviewedNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.bubble")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Taxi

/// The local name at `.largeTitle`, the address at `.title2`, the fixed phrase,
/// then the map snapshot, shown whole so its attribution stays visible.
private struct ShowTaxiView: View {
    let card: TaxiShowCard

    @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.grid * 3) {
                VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
                    LocalText(card.name, languageTag: ScriptMatch.languageTag(for: card.name, preferring: card.language))
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if !card.address.isEmpty {
                        LocalText(card.address, languageTag: ScriptMatch.languageTag(for: card.address, preferring: card.language))
                            .font(.title2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                Divider()
                VStack(alignment: .leading, spacing: Theme.grid) {
                    LocalText(card.phrase.local, languageTag: card.phrase.lang)
                        .font(.title.weight(.semibold))
                    if showsRomanization, let romanization = card.phrase.romanization {
                        Text(romanization)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if card.phrase.gloss != card.phrase.local {
                        Text(card.phrase.gloss)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                if let snapshot = card.snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.grid * 2, style: .continuous))
                        .accessibilityLabel("Map of the destination")
                }
            }
            .pageMargins()
            .padding(.vertical, Theme.grid * 2)
        }
    }
}

#Preview("Phrase") {
    ShowModeView(content: .phrase(Fixtures.tokyoCard?.phrases.first
        ?? Phrase(id: "p", lang: "ja", local: "こんにちは", romanization: "Konnichiwa", gloss: "Hello")))
}

#Preview("Allergy") {
    ShowModeView(content: .allergy(AllergyShowCard(Fixtures.allergyCard
        ?? AllergyCardResponse(language: "ja", title: "", items: [], requestLocal: "", requestHome: "", romanization: nil, reviewed: false))))
}
