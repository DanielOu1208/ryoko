import AVFoundation
import os

/// Speaks phrases (design §8.1): ElevenLabs audio, cached on the device, played
/// with `AVAudioPlayer`; `AVSpeechSynthesizer` when there's no key, no network
/// or an error. One phrase at a time: a new one stops the last.
///
/// - The `.playback` session plays through the silent switch and ducks other
///   audio; it's released when the phrase ends, unless something else (Translate)
///   has taken the session since.
/// - `beforeSpeaking` stops Translate's listening first, so the two never overlap.
@MainActor
@Observable
final class LiveSpeechService: SpeechService {
    private(set) var activity: SpeechActivity = .idle

    @ObservationIgnored private let client: ElevenLabsClient?
    @ObservationIgnored private let beforeSpeaking: @MainActor () async -> Void
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let delegate = PlaybackDelegate()
    @ObservationIgnored private var player: AVAudioPlayer?
    /// The player or utterance now playing, so a late callback from an old one is ignored.
    @ObservationIgnored private var source: ObjectIdentifier?
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?
    /// Bumped by every speak and stop; a speak that sees a newer one gives way.
    @ObservationIgnored private var generation = 0

    init(
        client: ElevenLabsClient? = ElevenLabsCredentials.fromBundle().map { ElevenLabsClient(credentials: $0) },
        beforeSpeaking: @escaping @MainActor () async -> Void = {}
    ) {
        self.client = client
        self.beforeSpeaking = beforeSpeaking
        synthesizer.delegate = delegate
        delegate.onFinish = { [weak self] id in self?.playbackEnded(id) }
        RyokoLog.speech.info("Speech: \(client == nil ? "on-device voice only (no ElevenLabs key or voice)" : "ElevenLabs \(ElevenLabsClient.model)", privacy: .public)")
        Task { await SpeechAudioCache.prune() }
    }

    func speak(_ phrase: Phrase) async {
        stop()
        generation += 1
        let mine = generation
        let text = phrase.local.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        activity = .loading(phrase.id)
        async let fetched = elevenLabsAudio(text, language: phrase.lang)
        await beforeSpeaking()
        let audio = await fetched
        guard mine == generation else { return }

        activateSession()
        if let audio, let player = try? AVAudioPlayer(data: audio) {
            player.delegate = delegate
            self.player = player
            source = ObjectIdentifier(player)
            if !player.play() { speakOnDevice(text, language: phrase.lang) }
        } else {
            speakOnDevice(text, language: phrase.lang)
        }
        activity = .playing(phrase.id)

        await withCheckedContinuation { finished = $0 }
        guard mine == generation else { return }
        player = nil
        source = nil
        activity = .idle
        deactivateSession()
    }

    func stop() {
        generation += 1
        let wasPlaying = activity != .idle
        player?.stop()
        player = nil
        source = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finished?.resume()
        finished = nil
        activity = .idle
        if wasPlaying { deactivateSession() }
    }

    // MARK: Audio

    /// Cached audio, or ElevenLabs' (then cached). nil without a key or on failure.
    private func elevenLabsAudio(_ text: String, language: String) async -> Data? {
        guard let client else { return nil }
        let key = SpeechAudioCache.key(text: text, language: language, voiceID: client.voiceID, model: ElevenLabsClient.model)
        if let cached = await SpeechAudioCache.data(for: key) { return cached }
        do {
            // ISO 639-1, the same codes Soniox takes.
            let audio = try await client.audio(for: text, languageCode: LangCode(tag: language)?.sonioxCode)
            await SpeechAudioCache.save(audio, for: key)
            return audio
        } catch {
            RyokoLog.speech.error("ElevenLabs failed, using the on-device voice: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func speakOnDevice(_ text: String, language: String) {
        player = nil
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.deviceVoiceLanguage(for: language))
        source = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    /// `AVSpeechSynthesisVoice` wants a language-region code.
    private static func deviceVoiceLanguage(for tag: String) -> String {
        switch LangCode(tag: tag) {
        case .zhHans: "zh-CN"
        case .zhHant: "zh-TW"
        case .ja: "ja-JP"
        case .en: "en-US"
        case nil: tag
        }
    }

    private func playbackEnded(_ id: ObjectIdentifier) {
        guard id == source else { return }
        finished?.resume()
        finished = nil
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            RyokoLog.speech.error("Playback session didn't activate: \(String(describing: error), privacy: .public)")
        }
    }

    private func deactivateSession() {
        let session = AVAudioSession.sharedInstance()
        // Translate may have started listening since; its session isn't ours to end.
        guard session.category == .playback else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Playback callbacks, sent back to the main actor with what finished.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    var onFinish: ((ObjectIdentifier) -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finish(ObjectIdentifier(player))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(ObjectIdentifier(utterance))
    }

    private nonisolated func finish(_ id: ObjectIdentifier) {
        Task { @MainActor in self.onFinish?(id) }
    }
}
