import Foundation
import os

/// Speaks a phrase aloud (tier 2, design §8.1): ElevenLabs with an audio cache,
/// falling back to `AVSpeechSynthesizer`. Speech is always on demand.
@MainActor
protocol SpeechService: AnyObject {
    /// Speaks `phrase.local` in `phrase.lang`, stopping anything already playing.
    /// Returns when playback ends or is stopped. Failures fall back or stay
    /// silent; they don't throw.
    func speak(_ phrase: Phrase) async
    /// Stops playback now.
    func stop()
}

/// Logs instead of speaking. Used until the Speech workstream lands.
@MainActor
final class FixtureSpeechService: SpeechService {
    private(set) var spoken: [Phrase] = []

    func speak(_ phrase: Phrase) async {
        spoken.append(phrase)
        RyokoLog.speech.info("Would speak \(phrase.id, privacy: .public) in \(phrase.lang, privacy: .public)")
    }

    func stop() {
        RyokoLog.speech.info("Would stop speaking")
    }
}
