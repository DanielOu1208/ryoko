import SwiftUI

/// The two panes for the latest turn (design §4.8).
///
/// - **Upright:** what was said on top, the translation below.
/// - **Face to face:** the top half is turned 180° toward the other person and
///   always shows their language; the bottom half always shows yours.
///
/// The rotation animates with the caller's animation (`.smooth`, or a
/// crossfade under Reduce Motion).
///
/// When the turn is yours, tapping your words edits them (T2.4): the pane
/// with your words shows a pencil, and `editMine` runs.
struct TranslatePanes: View {
    let turn: Turn?
    let pair: TranslatePair?
    let layout: TranslateLayout
    /// Edits your words, when the turn is yours. nil turns tapping off.
    var editMine: (() -> Void)?

    /// The turn is yours and can be edited.
    private var canEdit: Bool { turn?.speaker == .me && editMine != nil }

    var body: some View {
        VStack(spacing: 0) {
            top
                .rotationEffect(layout == .faceToFace ? .degrees(180) : .zero)
            Divider()
                .padding(.horizontal, Theme.margin)
            bottom
        }
    }

    // MARK: Layouts

    @ViewBuilder
    private var top: some View {
        switch layout {
        case .upright: uprightSaid
        case .faceToFace: theirHalf
        }
    }

    @ViewBuilder
    private var bottom: some View {
        switch layout {
        case .upright: uprightTranslation
        case .faceToFace: yourHalf
        }
    }

    /// Upright, top: what was said, in the speaker's language.
    private var uprightSaid: some View {
        TranslatePane(
            caption: turn.map { editableCaption(speakerCaption($0)) },
            text: turn?.original ?? "",
            languageTag: turn?.originalTag ?? "en",
            font: .title2,
            placeholder: .init(
                text: pair.map { "Tap the mic and speak \($0.home.name). Tap \($0.other.name) when it's their turn." } ?? "Tap the mic to start.",
                languageTag: "en"
            ),
            onTap: canEdit ? editMine : nil
        )
    }

    /// Upright, bottom: the translation.
    private var uprightTranslation: some View {
        TranslatePane(
            caption: turn.map { Text("Translation · \(languageName($0.translationTag))") },
            text: turn?.translation ?? "",
            languageTag: turn?.translationTag ?? "en",
            font: .title.weight(.semibold),
            placeholder: .init(text: turn == nil ? "The translation shows here." : "…", languageTag: "en")
        )
    }

    /// Face to face, top (turned toward them): always their language.
    private var theirHalf: some View {
        let them = pair?.other ?? turn.flatMap { PairLanguage(tag: $0.speaker == .them ? $0.originalTag : $0.translationTag) }
        let text = turn.map { $0.speaker == .them ? $0.original : $0.translation } ?? ""
        return TranslatePane(
            caption: them.map { Text.local($0.nativeName, languageTag: $0.tag) },
            text: text,
            languageTag: them?.tag ?? turn?.translationTag ?? "en",
            font: .title.weight(.semibold),
            placeholder: placeholderForThem(them)
        )
    }

    /// Face to face, bottom: always your language.
    private var yourHalf: some View {
        let you = pair?.home ?? turn.flatMap { PairLanguage(tag: $0.speaker == .me ? $0.originalTag : $0.translationTag) }
        let text = turn.map { $0.speaker == .me ? $0.original : $0.translation } ?? ""
        return TranslatePane(
            caption: you.map { editableCaption($0.name) },
            text: text,
            languageTag: you?.tag ?? "en",
            font: .title.weight(.semibold),
            placeholder: .init(text: turn == nil ? "Tap the mic and speak. Tap their language when it's their turn." : "…", languageTag: "en"),
            onTap: canEdit ? editMine : nil
        )
    }

    // MARK: Copy

    private func speakerCaption(_ turn: Turn) -> String {
        var caption = "\(turn.speaker == .me ? "You" : "Them") · \(languageName(turn.originalTag))"
        if turn.source == .typed { caption += " · Typed" }
        if turn.edited { caption += " · Edited" }
        return caption
    }

    /// The caption, with a pencil when tapping edits your words.
    private func editableCaption(_ caption: String) -> Text {
        canEdit ? Text("\(caption)  \(Image(systemName: "pencil"))") : Text(caption)
    }

    private func languageName(_ tag: String) -> String {
        PairLanguage(tag: tag)?.name ?? tag
    }

    private func placeholderForThem(_ them: PairLanguage?) -> TranslatePane.Placeholder {
        if turn != nil { return .init(text: "…", languageTag: "en") }
        if let them, let prompt = them.speakPrompt { return .init(text: prompt, languageTag: them.tag) }
        return .init(text: "Their words show here.", languageTag: "en")
    }
}

/// One pane: a small caption and large text that grows and scrolls, keeping
/// the newest words in view.
struct TranslatePane: View {
    struct Placeholder {
        var text: String
        var languageTag: String
    }

    let caption: Text?
    let text: String
    let languageTag: String
    let font: Font
    let placeholder: Placeholder
    /// Tapping the pane edits these words (yours). nil: not tappable.
    var onTap: (() -> Void)?

    @State private var position = ScrollPosition(edge: .top)

    private static let fade: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let caption {
                caption
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Group {
                    if text.isEmpty {
                        LocalText(placeholder.text, languageTag: placeholder.languageTag)
                            .foregroundStyle(.tertiary)
                    } else {
                        LocalText(text, languageTag: languageTag)
                            .textSelection(.enabled)
                    }
                }
                .font(font)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($position)
            .scrollBounceBehavior(.basedOnSize)
            // Earlier words fade out at the top instead of being cut mid-line.
            .contentMargins(.top, Self.fade, for: .scrollContent)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                    Color.black
                }
            }
            // Keep the newest words in view as the text grows.
            .onChange(of: text) { position.scrollTo(edge: .bottom) }
            .onAppear { position.scrollTo(edge: .bottom) }
        }
        // The panes are already large; past this they'd show only a word or two.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, Theme.grid * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
        .accessibilityHint(onTap == nil ? "" : "Edits what you said.")
        .accessibilityActions {
            if let onTap { Button("Edit", action: onTap) }
        }
    }
}
