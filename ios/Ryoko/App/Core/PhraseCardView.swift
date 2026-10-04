import SwiftUI

/// One phrase, in the styles from design §9.1 and §9.4. A stub for W3 (place cards,
/// place sheets) and W6 (Mimo's phrase blocks) to build on.
///
/// - `.card`: the Map's place cards. Local script at `.title` semibold, then
///   romanization, gloss, the "because…" line, and Show and Speak buttons.
/// - `.block`: Mimo's compact phrase block. Script at `.title3` semibold, no
///   "because…", a chevron, and the whole block opens Show mode.
///
/// Both are solid cards (`secondarySystemGroupedBackground`, 24 pt continuous
/// corners). No glass on content.
struct PhraseCardView: View {
    enum Style {
        case card
        case block
    }

    let phrase: Phrase
    var style: Style = .card
    /// Me's romanization toggle. It only hides the row.
    var showsRomanization = true
    /// Opens Show mode with this phrase. No Show button (card) or tap (block) when nil.
    var onShow: (() -> Void)?

    var body: some View {
        switch style {
        case .card: card
        case .block: block
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            lines(scriptFont: .title.weight(.semibold))
            if let because = phrase.because {
                Text(because)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            HStack(spacing: 8) {
                if let onShow {
                    Button("Show", systemImage: "arrow.up.left.and.arrow.down.right", action: onShow)
                        .accessibilityHint("Opens the phrase full screen to show someone")
                }
                SpeakButton(phrase: phrase)
            }
            .buttonStyle(.glass)
            .tint(.primary)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(PhraseCardSurface())
    }

    @ViewBuilder
    private var block: some View {
        let content = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                lines(scriptFont: .title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if onShow != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .background(PhraseCardSurface())
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

        if let onShow {
            Button(action: onShow) { content }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the phrase full screen to show someone")
        } else {
            content
        }
    }

    /// Local script, then romanization and gloss (design §9.6: local script first).
    @ViewBuilder
    private func lines(scriptFont: Font) -> some View {
        LocalText(phrase.local, languageTag: phrase.lang)
            .font(scriptFont)
            .fixedSize(horizontal: false, vertical: true)
        if showsRomanization, let romanization = phrase.romanization {
            Text(romanization)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        Text(phrase.gloss)
            .font(.body)
            .foregroundStyle(.secondary)
    }
}

/// The solid content-card surface from design §9.4.
private struct PhraseCardSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
