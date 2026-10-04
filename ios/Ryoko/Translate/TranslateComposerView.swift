import SwiftUI

/// Type mode and the editor on screen (design §4.8, T2.4): with the keyboard
/// up, the big panes are gone and a compact preview of the translation sits
/// above the text field. Done and Cancel live in the navigation bar.
struct TranslateComposerView: View {
    let composer: TranslateComposer
    /// The return key: Done.
    let submit: () -> Void

    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var fieldPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
            Spacer(minLength: 0)
            preview
            field
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, Theme.grid * 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onAppear { focused = true }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: Theme.grid) {
            HStack(spacing: Theme.grid) {
                if let target = composer.target {
                    Text(previewCaption(target))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if composer.isTranslating || composer.isFinishing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Translating")
                }
            }
            Group {
                if let translation = composer.translation, TypedText.request(composer.text) != nil {
                    LocalText(translation, languageTag: composer.target?.tag ?? "en")
                        .foregroundStyle(composer.isCurrent ? .primary : .secondary)
                        .contentTransition(.opacity)
                        .animation(.default, value: translation)
                } else {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.title3.weight(.semibold))
            .lineLimit(1...6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)

            if let failure = composer.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        // The keyboard takes half the screen; past this the preview would crowd the field.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(Theme.grid * 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Translate's page is the plain system background (design §9.3), so the
        // solid card is the secondary background, not the grouped card fill.
        .background(Color(uiColor: .secondarySystemBackground), in: Theme.cardShape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func previewCaption(_ target: PairLanguage) -> String {
        if case .editing = composer.purpose { return "Translation · \(target.name) · Editing" }
        return "Translation · \(target.name)"
    }

    private var placeholder: String {
        guard let target = composer.target else { return "" }
        return "The \(target.name) shows here as you type."
    }

    // MARK: Field

    private var field: some View {
        TextField(fieldPrompt, text: textBinding, axis: .vertical)
            .lineLimit(1...5)
            .font(.body)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(submit)
            .padding(.horizontal, fieldPadding * 1.25)
            .padding(.vertical, fieldPadding)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityLabel(fieldPrompt)
    }

    private var fieldPrompt: String {
        let name = composer.source?.name ?? "your language"
        if case .editing = composer.purpose { return "Edit what you said in \(name)" }
        return "Type in \(name)"
    }

    /// The return key ends the text (Done) instead of adding a line.
    private var textBinding: Binding<String> {
        Binding(
            get: { composer.text },
            set: { newValue in
                if composer.update(newValue) { submit() }
            }
        )
    }
}

#Preview("Type mode") {
    let composer = TranslateComposer()
    composer.openTyping(
        pair: TranslatePair(home: PairLanguage(.en), other: PairLanguage(.zhHans)),
        api: FixtureRyokoAPI(),
        situation: { Fixtures.shanghai }
    )
    return NavigationStack {
        TranslateComposerView(composer: composer, submit: {})
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
    }
}
