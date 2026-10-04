import SwiftUI

/// A phrase inside Mimo's reply (design §6.2): a quiet line in the text, set
/// off by a bar on its leading edge like a quote, with the local script and
/// its meaning. Tap it to show it full screen.
struct MimoPhraseLine: View {
    let phrase: Phrase
    var onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(alignment: .top, spacing: Theme.grid * 1.5) {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.grid / 2) {
                    LocalText(phrase.local, languageTag: phrase.lang)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(phrase.gloss)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Theme.grid / 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the phrase full screen to show someone")
    }
}
