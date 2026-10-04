import SwiftUI

/// A cultural tip from a place card, in the home language (design §4.3). A tip
/// that rests on a travel guide links its source underneath (design §8.4:
/// Wikivoyage is CC BY-SA, so cited tips link back).
struct TipRow: View {
    let tip: Tip

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.grid / 2) {
                Text(tip.text)
                    .font(.body)
                    .accessibilityLabel("Tip: \(tip.text)")
                if let source = tip.source, let url = source.link {
                    Link(destination: url) {
                        Label(source.title, systemImage: "book")
                            .font(.footnote)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Source: \(source.title)")
                    .accessibilityHint("Opens in Safari")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}
