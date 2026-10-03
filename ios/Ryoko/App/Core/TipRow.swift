import SwiftUI

/// A cultural tip from a place card, in the home language (design §4.3).
/// A stub for W3 to style.
struct TipRow: View {
    let tip: Tip

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(tip.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tip: \(tip.text)")
    }
}
