import SwiftUI

/// The two panes for the latest turn (design §4.8).
///
/// - **Upright:** what was said on top, the translation below.
/// - **Face to face:** the top half is turned 180° toward the other person and
///   always shows their language; the bottom half always shows yours.
///
/// The rotation animates with the caller's animation (`.smooth`, or a
/// crossfade under Reduce Motion).
struct TranslatePanes: View {
    let turn: Turn?
    let pair: TranslatePair?
    let layout: TranslateLayout

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
            caption: turn.map { Text(speakerCaption($0)) },
            text: turn?.original ?? "",
            languageTag: turn?.originalTag ?? "en",
            font: .title2,
            placeholder: .init(
                text: pair.map { "Tap the mic, then speak \($0.home.name) or \($0.other.name)." } ?? "Tap the mic to start.",
                languageTag: "en"
            )
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
            caption: you.map { Text($0.name) },
            text: text,
            languageTag: you?.tag ?? "en",
            font: .title.weight(.semibold),
            placeholder: .init(text: turn == nil ? "Tap the mic, then take turns speaking." : "…", languageTag: "en")
        )
    }

    // MARK: Copy

    private func speakerCaption(_ turn: Turn) -> String {
        "\(turn.speaker == .me ? "You" : "Them") · \(languageName(turn.originalTag))"
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
        .accessibilityElement(children: .combine)
    }
}
