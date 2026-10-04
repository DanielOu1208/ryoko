import SwiftUI

/// Speak (design §8.1): plays the phrase aloud; while it plays, the same button
/// stops it. Text and icon, so it reads the same as a card button and in a
/// toolbar. The caller picks the button style.
struct SpeakButton: View {
    let phrase: Phrase
    /// Whether playing it goes into trip memory (design §8.3). Show mode's
    /// taxi card turns it off: it's an address, not a phrase.
    var remembers = true

    @Environment(\.speechService) private var speech
    @Environment(\.tripMemory) private var tripMemory

    var body: some View {
        let activity = speech.activity
        let isMine = activity.phraseID == phrase.id
        Button {
            if isMine {
                speech.stop()
            } else {
                if remembers { tripMemory.spoken(phrase) }
                Task { await speech.speak(phrase) }
            }
        } label: {
            HStack(spacing: Theme.grid * 0.75) {
                if activity == .loading(phrase.id) {
                    ProgressView()
                } else {
                    Image(systemName: isMine ? "stop.fill" : "speaker.wave.2")
                }
                Text(isMine ? "Stop" : "Speak")
            }
        }
        .accessibilityLabel(isMine ? "Stop speaking" : "Speak")
        .accessibilityHint(isMine ? "" : "Plays the phrase aloud")
    }
}

extension ShowContent {
    /// What Speak reads out in Show mode: the phrase; the allergy card's lines
    /// and its request; the taxi card's phrase, then the name and address.
    var spokenPhrase: Phrase {
        switch self {
        case let .phrase(phrase):
            return phrase
        case let .allergy(card):
            let text = (card.lines.map(\.local) + [card.requestLocal]).filter { !$0.isEmpty }.joined(separator: "\n")
            return Phrase(id: id, lang: card.language, local: text, romanization: nil, gloss: card.requestHome)
        case let .taxi(card):
            let text = [card.phrase.local, card.name, card.address].filter { !$0.isEmpty }.joined(separator: "\n")
            return Phrase(id: id, lang: card.language, local: text, romanization: nil, gloss: card.phrase.gloss)
        }
    }
}
