import SwiftUI

/// Placeholder for Show mode (design §4.4), so `AppRouter.show` works today.
/// `RootTabView` presents it full screen. The Nearby and cards workstream (W3.4)
/// replaces this file: brightness, idle timer, Flip, the allergy and taxi layouts.
struct ShowModeView: View {
    let content: ShowContent

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LocalText(localText, languageTag: content.language)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
                .pageMargins()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    private var localText: String {
        switch content {
        case let .phrase(phrase): phrase.local
        case let .allergy(card): ([card.titleLocal] + card.lines.map(\.local)).joined(separator: "\n")
        case let .taxi(card): "\(card.name)\n\(card.address)"
        }
    }
}
