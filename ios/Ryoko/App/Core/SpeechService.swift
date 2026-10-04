import Foundation
import os

/// Speaks a phrase aloud (tier 2, design §8.1): ElevenLabs with an audio cache,
/// falling back to `AVSpeechSynthesizer`. Speech is always on demand.
/// `RyokoApp` sets `LiveSpeechService` (ios/Ryoko/Speech/); `SpeakButton` is
/// the control.
@MainActor
protocol SpeechService: AnyObject {
    /// What's happening now, for the Speak buttons. Observable on the live service.
    var activity: SpeechActivity { get }
    /// Speaks `phrase.local` in `phrase.lang`, stopping anything already playing.
    /// Returns when playback ends or is stopped. Failures fall back or stay
    /// silent; they don't throw.
    func speak(_ phrase: Phrase) async
    /// Stops playback now.
    func stop()
}

/// The phrase being fetched or played, by `Phrase.id`.
enum SpeechActivity: Equatable {
    case idle
    /// Waiting for ElevenLabs (a cache miss).
    case loading(String)
    case playing(String)

    var phraseID: String? {
        switch self {
        case .idle: nil
        case let .loading(id), let .playing(id): id
        }
    }
}

/// Logs instead of speaking. Previews use it.
@MainActor
@Observable
final class FixtureSpeechService: SpeechService {
    private(set) var spoken: [Phrase] = []
    private(set) var activity: SpeechActivity = .idle

    func speak(_ phrase: Phrase) async {
        spoken.append(phrase)
        RyokoLog.speech.info("Would speak \(phrase.id, privacy: .public) in \(phrase.lang, privacy: .public)")
    }

    func stop() {
        RyokoLog.speech.info("Would stop speaking")
    }
}
