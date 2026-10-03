import SwiftUI

/// Every turn of this run of the app, oldest first (design §4.8). History
/// isn't saved; it's gone when Ryoko quits.
struct TranslateHistorySheet: View {
    let turns: [Turn]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if turns.isEmpty {
                    ContentUnavailableView {
                        Label("No turns yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("What you and the other person say shows here while you translate.")
                    }
                } else {
                    ScrollViewReader { proxy in
                        List(turns) { turn in
                            TurnRow(turn: turn)
                        }
                        // Open on the latest turn, once the list has laid out.
                        .task {
                            try? await Task.sleep(for: .milliseconds(80))
                            if let last = turns.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Solid, so the red mic button doesn't glow through the turns while listening.
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }
}

/// One turn: who spoke and in what language, what they said, and the translation.
private struct TurnRow: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 0.75) {
            HStack(spacing: Theme.grid * 0.75) {
                Image(systemName: turn.speaker == .me ? "person.fill" : "person")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text("\(turn.speaker == .me ? "You" : "Them") · \(PairLanguage(tag: turn.originalTag)?.name ?? turn.originalTag)")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)

            LocalText(turn.original, languageTag: turn.originalTag)
                .font(.body)
            if turn.translation.isEmpty {
                Text("Translating…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            } else {
                LocalText(turn.translation, languageTag: turn.translationTag)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.grid * 0.5)
        .accessibilityElement(children: .combine)
    }
}

#Preview("History") {
    let pair = TranslatePair(home: PairLanguage(.en), other: PairLanguage(.zhHans))
    var builder = TurnBuilder(pair: pair)
    for step in CannedConversation.steps(for: pair, pace: 0) {
        builder.apply(step.response.tokens)
    }
    return TranslateHistorySheet(turns: builder.history)
}
