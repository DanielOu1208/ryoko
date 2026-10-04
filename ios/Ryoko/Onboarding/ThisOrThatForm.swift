import SwiftUI

// MARK: - 6. This or that

/// Four pairs of big tappable cards (design §4.1). Tapping a card picks it;
/// tapping it again clears the pair (`null`).
struct ThisOrThatSections: View {
    @Binding var personality: Personality

    var body: some View {
        Section("Your day") {
            ThisOrThatPair(selection: $personality.rhythm, options: [
                .init(value: .earlyBird, title: ProfileWording.rhythm(.earlyBird), detail: "Early openings", symbol: "sunrise"),
                .init(value: .nightOwl, title: ProfileWording.rhythm(.nightOwl), detail: "Late openings", symbol: "moon.stars"),
            ])
        }
        Section("When you order") {
            ThisOrThatPair(selection: $personality.food, options: [
                .init(value: .localFavourite, title: ProfileWording.food(.localFavourite), detail: "The local specialty", symbol: "fork.knife"),
                .init(value: .myUsual, title: ProfileWording.food(.myUsual), detail: "Close to what you like", symbol: "repeat"),
            ])
        }
        Section("Spending") {
            ThisOrThatPair(selection: $personality.budget, options: [
                .init(value: .save, title: ProfileWording.budget(.save), detail: "Good value", symbol: "banknote"),
                .init(value: .splurge, title: ProfileWording.budget(.splurge), detail: "Worth paying for", symbol: "crown"),
            ])
        }
        Section("Places") {
            ThisOrThatPair(selection: $personality.vibe, options: [
                .init(value: .quiet, title: ProfileWording.vibe(.quiet), detail: "Calm corners", symbol: "leaf"),
                .init(value: .lively, title: ProfileWording.vibe(.lively), detail: "Busy and buzzing", symbol: "person.3"),
            ])
        }
    }
}

/// One pair, side by side (stacked at accessibility text sizes).
private struct ThisOrThatPair<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var detail: String
        var symbol: String
    }

    @Binding var selection: Value?
    let options: [Option]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.grid * 1.5))
            : AnyLayout(HStackLayout(spacing: Theme.grid * 1.5))
        layout {
            ForEach(options, id: \.value) { option in
                ThisOrThatCard(
                    title: option.title,
                    detail: option.detail,
                    symbol: option.symbol,
                    isSelected: selection == option.value
                ) {
                    selection = selection == option.value ? nil : option.value
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A big card: symbol, title, a short line. Solid fill (no glass on content,
/// design §9.4); the picked one is outlined in the primary colour and marked
/// with a checkmark, so the choice never depends on colour alone.
private struct ThisOrThatCard: View {
    let title: String
    let detail: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.grid) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                Spacer(minLength: Theme.grid)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(Theme.grid * 2)
            .background(Theme.cardFill, in: Theme.cardShape)
            .overlay {
                Theme.cardShape
                    .strokeBorder(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2.5 : 0.5)
            }
            .contentShape(Theme.cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy, value: isSelected)
    }
}
