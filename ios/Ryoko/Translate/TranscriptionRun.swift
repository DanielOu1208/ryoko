import Foundation
import os
import Synchronization

/// What a listening session reports.
nonisolated enum TranscriptionEvent: Sendable {
    /// Connected; the words can start.
    case connected
    /// The latest microphone level, 0…1.
    case level(Float)
    /// A Soniox message.
    case response(SonioxResponse)
    #if DEBUG
    /// DEBUG: the canned script's next line is the other person's, as if
    /// someone tapped their language.
    case handOver(TurnSpeaker)
    #endif
}

/// One listening session. `events` ends normally after `finish()` once Soniox
/// has sent everything, or throws a `TranslateProblem`.
nonisolated protocol TranscriptionRun: Sendable {
    var events: AsyncThrowingStream<TranscriptionEvent, any Error> { get }
    /// Stops the audio and lets Soniox finalize what it heard.
    func finish()
    /// Manual turns: Soniox finalizes what it heard so far (`<fin>` arrives in
    /// `events` once it has) and keeps listening, now for `language` only
    /// (a Soniox code). Nothing changes if it already listens for it.
    func handOver(lockingTo language: String)
    /// Stops at once.
    func cancel()
}

/// Which audio and service a session uses. Only `.microphone` ships; the
/// others are DEBUG hooks (`-RyokoTranslateSource`).
nonisolated enum TranscriptionSourceKind: String, Sendable {
    /// The microphone, streamed to Soniox.
    case microphone
    /// DEBUG: silence streamed to the real Soniox (checks the key and errors).
    case silence
    /// DEBUG: a scripted conversation; no network, key or microphone.
    case canned

    var needsMicrophone: Bool { self == .microphone }

    /// - Parameters:
    ///   - api: where a session gets its Soniox key (T2.6).
    ///   - language: the Soniox code to listen for (the speaker's, with manual
    ///     turns), or nil for either of the pair.
    @MainActor
    func makeRun(pair: TranslatePair, api: any RyokoAPI, turnMode: TurnMode, language: String?) -> any TranscriptionRun {
        let keys = SonioxKeyProvider(api: api)
        switch self {
        case .microphone:
            return SonioxRun(pair: pair, language: language, audio: MicrophoneCapture(), usesAudioSession: true, keys: keys)
        case .silence:
            #if DEBUG
            return SonioxRun(pair: pair, language: language, audio: SilenceSource(), usesAudioSession: false, keys: keys)
            #else
            return SonioxRun(pair: pair, language: language, audio: MicrophoneCapture(), usesAudioSession: true, keys: keys)
            #endif
        case .canned:
            #if DEBUG
            return CannedRun(
                pair: pair, pace: TranslateDebug.cannedPace, script: TranslateDebug.cannedScript,
                failure: TranslateDebug.injectedProblem, handsOver: turnMode == .manual
            )
            #else
            return SonioxRun(pair: pair, language: language, audio: MicrophoneCapture(), usesAudioSession: true, keys: keys)
            #endif
        }
    }
}

/// Audio to Soniox and back (design §4.8, W5.1).
///
/// 1. Starts the audio (it waits in a backlog while the key and the socket
///    come, so the first words aren't lost), gets a key (a temporary one from
///    the server, or the build's own: `SonioxKeyProvider`), opens the socket,
///    sends the config.
/// 2. Sends each ~120 ms chunk as it comes.
/// 3. Manual turns listen for one language at a time, the speaker's (#74).
///    Soniox only takes its languages when a session opens, so a hand-over
///    finalizes the current session (its words and `<fin>` arrive first, so
///    they stay in that turn), ends it, and opens a new one locked to the new
///    speaker's language. The audio in between waits in the backlog, and the
///    next key is fetched while the old session finishes.
/// 4. `finish()` stops the audio; the pump then sends the empty frame, and
///    Soniox finalizes and says `finished`. If it doesn't within a few
///    seconds, the socket is closed and what arrived is kept.
nonisolated final class SonioxRun: TranscriptionRun, @unchecked Sendable {
    let events: AsyncThrowingStream<TranscriptionEvent, any Error>

    private let continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    private let pair: TranslatePair
    private let audio: any AudioSource
    private let usesAudioSession: Bool
    private let keys: SonioxKeyProvider
    private let state: Mutex<State>

    /// About 30 s of audio: more than a hand-over ever waits.
    private static let backlogLimit = 250
    /// How long a session that's handing over may take to finish.
    private static let handOverGrace: Duration = .seconds(3)

    private nonisolated struct State {
        /// The session being read; it takes the audio once `takesAudio` is on.
        var session: SonioxSession?
        /// Off while a session connects and once a hand-over has begun: the
        /// audio waits in `backlog`.
        var takesAudio = false
        /// The language the next session listens for (nil: either of the pair).
        var language: String?
        /// A hand-over is under way: once the current session finishes, the
        /// next opens locked to `language`.
        var switching = false
        /// The next session's key, fetched while the old one finishes.
        var nextKey: Task<(value: String, source: SonioxKeySource), any Error>?
        /// Audio no session could take yet, oldest first.
        var backlog: [Data] = []
        var driver: Task<Void, Never>?
        var finishing = false
        var cancelled = false
    }

    init(pair: TranslatePair, language: String?, audio: any AudioSource, usesAudioSession: Bool, keys: SonioxKeyProvider) {
        self.pair = pair
        self.audio = audio
        self.usesAudioSession = usesAudioSession
        self.keys = keys
        state = Mutex(State(language: language))
        (events, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self)
        let driver = Task { [self] in await run() }
        state.withLock { $0.driver = driver }
    }

    func finish() {
        let alreadyFinishing = state.withLock { state -> Bool in
            defer { state.finishing = true }
            return state.finishing
        }
        guard !alreadyFinishing else { return }
        audio.stop()
        // Don't wait forever for Soniox's `finished`.
        Task { [self] in
            try? await Task.sleep(for: .seconds(4))
            state.withLock { $0.session }?.close()
        }
    }

    func handOver(lockingTo language: String) {
        let old = state.withLock { state -> SonioxSession? in
            guard !state.finishing, !state.cancelled, state.language != language else { return nil }
            state.language = language
            // Still connecting, or already handing over: the next session
            // opens with the new language (`run()` checks).
            guard state.takesAudio, !state.switching, let session = state.session else { return nil }
            state.switching = true
            state.takesAudio = false
            state.nextKey = Task { [keys] in try await keys.key() }
            return session
        }
        guard let old else { return }
        RyokoLog.translate.notice("Hand-over: finishing this Soniox session, the next listens for \(language, privacy: .public)")
        Task {
            await old.finalize()
            await old.endAudio()
            // Don't wait forever for its `finished`.
            try? await Task.sleep(for: Self.handOverGrace)
            old.close()
        }
    }

    func cancel() {
        let (session, driver, nextKey) = state.withLock { state in
            state.cancelled = true
            return (state.session, state.driver, state.nextKey)
        }
        audio.stop()
        session?.close()
        nextKey?.cancel()
        driver?.cancel()
        continuation.finish()
    }

    private func run() async {
        var pump: Task<Void, Never>?
        defer {
            pump?.cancel()
            audio.stop()
            state.withLock { $0.session }?.close()
            if usesAudioSession { TranslateAudioSession.deactivate() }
        }
        do {
            // Off the main thread: activating the session can block for a moment.
            if usesAudioSession { try TranslateAudioSession.activate() }
            let chunks = try audio.start()
            pump = startPump(chunks)
            var connected = false
            while true {
                let prefetched = state.withLock { state in
                    defer { state.nextKey = nil }
                    return state.nextKey
                }
                let key: (value: String, source: SonioxKeySource)
                if let prefetched {
                    key = try await prefetched.value
                } else {
                    key = try await keys.key()
                }
                let language = state.withLock { state -> String? in
                    state.switching = false
                    return state.language
                }
                if state.withLock({ $0.cancelled }) { return }
                var config = pair.sonioxConfig
                config.lockedLanguage = language
                let session = try SonioxSession(apiKey: key.value, config: config)
                state.withLock { $0.session = session }
                try await session.open()
                let responses = session.responses()
                RyokoLog.translate.notice("Soniox session open: \(self.pair.label, privacy: .public), \(language ?? "either language", privacy: .public), \(key.source.rawValue, privacy: .public) key")
                if !connected {
                    continuation.yield(.connected)
                    connected = true
                }
                // Audio flows to it now, unless the speaker changed while it connected.
                let stale = state.withLock { state -> Bool in
                    guard state.language == language || state.finishing else {
                        state.switching = true
                        return true
                    }
                    state.takesAudio = true
                    return false
                }
                if stale {
                    // It has heard nothing: let it go and open the right one.
                    session.close()
                    continue
                }

                do {
                    for try await response in responses {
                        continuation.yield(.response(response))
                    }
                } catch {
                    // A session that didn't finish in time during a hand-over:
                    // keep what arrived and open the next.
                    guard state.withLock({ $0.switching && !$0.finishing && !$0.cancelled }) else { throw error }
                    RyokoLog.translate.notice("Hand-over: the last session closed before it finished")
                }
                guard state.withLock({ $0.switching && !$0.finishing && !$0.cancelled }) else { break }
            }
            continuation.finish()
        } catch {
            let (finishing, cancelled) = state.withLock { ($0.finishing, $0.cancelled) }
            if cancelled { return }
            let problem = TranslateProblem.network(error)
            if finishing, problem == .closedUnexpectedly || problem == .cantReach {
                // We closed it after the grace period: keep what arrived.
                continuation.finish()
            } else {
                RyokoLog.translate.error("Listening stopped: \(problem.title, privacy: .public)")
                continuation.finish(throwing: problem)
            }
        }
    }

    /// Sends the audio to the session that takes it, oldest first; keeps it
    /// in the backlog while none does. When the audio stops (`finish()`), ends
    /// that session's audio so Soniox finalizes.
    private func startPump(_ chunks: AsyncStream<AudioChunk>) -> Task<Void, Never> {
        Task { [self, continuation] in
            for await chunk in chunks {
                continuation.yield(.level(chunk.level))
                let (session, frames) = state.withLock { state -> (SonioxSession?, [Data]) in
                    guard state.takesAudio, let session = state.session else {
                        state.backlog.append(chunk.pcm)
                        if state.backlog.count > Self.backlogLimit { state.backlog.removeFirst() }
                        return (nil, [])
                    }
                    defer { state.backlog = [] }
                    return (session, state.backlog + [chunk.pcm])
                }
                guard let session else { continue }
                for frame in frames {
                    // A failed send shows up as the session's error.
                    try? await session.send(audio: frame)
                }
            }
            let session = state.withLock { $0.takesAudio ? $0.session : nil }
            await session?.endAudio()
        }
    }
}

#if DEBUG
/// DEBUG: plays `CannedConversation` as if it came from Soniox, or fails with
/// an injected problem. No network, key or microphone.
nonisolated final class CannedRun: TranscriptionRun, @unchecked Sendable {
    let events: AsyncThrowingStream<TranscriptionEvent, any Error>
    private let continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    private let driver = Mutex<Task<Void, Never>?>(nil)

    init(pair: TranslatePair, pace: Double, script: CannedConversation.Script, failure: TranslateProblem?, handsOver: Bool) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self)
        let steps = CannedConversation.steps(for: pair, pace: pace, script: script)
        let task = Task { [continuation] in
            try? await Task.sleep(for: .seconds(0.3 * pace))
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            continuation.yield(.connected)
            for step in steps {
                try? await Task.sleep(for: .seconds(step.delay))
                if Task.isCancelled { return }
                if handsOver, let speaker = step.speaker { continuation.yield(.handOver(speaker)) }
                continuation.yield(.level(Float.random(in: 0.3...0.8)))
                continuation.yield(.response(step.response))
            }
            continuation.yield(.level(0))
            // Then stay "listening" until stopped, like a quiet room.
        }
        driver.withLock { $0 = task }
    }

    func handOver(lockingTo language: String) {
        continuation.yield(.response(SonioxResponse(tokens: [SonioxToken(text: SonioxToken.finalizeMarker, isFinal: true, language: nil)])))
    }

    func finish() {
        driver.withLock { $0?.cancel() }
        continuation.yield(.response(SonioxResponse(tokens: [], finished: true)))
        continuation.finish()
    }

    func cancel() {
        driver.withLock { $0?.cancel() }
        continuation.finish()
    }
}
#endif
