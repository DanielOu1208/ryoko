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
    /// Asks Soniox to finalize what it heard so far, and keeps listening.
    /// `<fin>` arrives in `events` once it has.
    func finalize()
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

    /// - Parameter api: where a session gets its Soniox key (T2.6).
    @MainActor
    func makeRun(pair: TranslatePair, api: any RyokoAPI, turnMode: TurnMode) -> any TranscriptionRun {
        let keys = SonioxKeyProvider(api: api)
        switch self {
        case .microphone:
            return SonioxRun(pair: pair, audio: MicrophoneCapture(), usesAudioSession: true, keys: keys)
        case .silence:
            #if DEBUG
            return SonioxRun(pair: pair, audio: SilenceSource(), usesAudioSession: false, keys: keys)
            #else
            return SonioxRun(pair: pair, audio: MicrophoneCapture(), usesAudioSession: true, keys: keys)
            #endif
        case .canned:
            #if DEBUG
            return CannedRun(pair: pair, pace: TranslateDebug.cannedPace, failure: TranslateDebug.injectedProblem, handsOver: turnMode == .manual)
            #else
            return SonioxRun(pair: pair, audio: MicrophoneCapture(), usesAudioSession: true, keys: keys)
            #endif
        }
    }
}

/// Audio to Soniox and back (design §4.8, W5.1).
///
/// 1. Starts the audio (it queues while the key and the socket come, so the
///    first words aren't lost), gets a key (a temporary one from the server,
///    or the build's own: `SonioxKeyProvider`), opens the socket, sends the config.
/// 2. Sends each ~120 ms chunk as it comes.
/// 3. `finish()` stops the audio; the pump then sends the empty frame, and
///    Soniox finalizes and says `finished`. If it doesn't within a few
///    seconds, the socket is closed and what arrived is kept.
nonisolated final class SonioxRun: TranscriptionRun, @unchecked Sendable {
    let events: AsyncThrowingStream<TranscriptionEvent, any Error>

    private let continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    private let pair: TranslatePair
    private let audio: any AudioSource
    private let usesAudioSession: Bool
    private let keys: SonioxKeyProvider
    private let state = Mutex(State())

    private nonisolated struct State {
        var session: SonioxSession?
        var driver: Task<Void, Never>?
        var finishing = false
        var cancelled = false
    }

    init(pair: TranslatePair, audio: any AudioSource, usesAudioSession: Bool, keys: SonioxKeyProvider) {
        self.pair = pair
        self.audio = audio
        self.usesAudioSession = usesAudioSession
        self.keys = keys
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

    func finalize() {
        guard let session = state.withLock({ $0.session }) else { return } // still connecting
        Task { await session.finalize() }
    }

    func cancel() {
        let (session, driver) = state.withLock { state in
            state.cancelled = true
            return (state.session, state.driver)
        }
        audio.stop()
        session?.close()
        driver?.cancel()
        continuation.finish()
    }

    private func run() async {
        defer {
            audio.stop()
            state.withLock { $0.session }?.close()
            if usesAudioSession { TranslateAudioSession.deactivate() }
        }
        do {
            // Off the main thread: activating the session can block for a moment.
            if usesAudioSession { try TranslateAudioSession.activate() }
            let chunks = try audio.start()
            let key = try await keys.key()
            if state.withLock({ $0.cancelled }) { return }
            let session = try SonioxSession(apiKey: key.value, config: pair.sonioxConfig)
            state.withLock { $0.session = session }
            try await session.open()
            let responses = session.responses()
            RyokoLog.translate.notice("Soniox session open: \(self.pair.label, privacy: .public), \(key.source.rawValue, privacy: .public) key")
            continuation.yield(.connected)

            let pump = Task { [continuation] in
                for await chunk in chunks {
                    continuation.yield(.level(chunk.level))
                    do {
                        try await session.send(audio: chunk.pcm)
                    } catch {
                        break // the reader reports the failure
                    }
                }
                await session.endAudio()
            }
            defer { pump.cancel() }

            for try await response in responses {
                continuation.yield(.response(response))
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
}

#if DEBUG
/// DEBUG: plays `CannedConversation` as if it came from Soniox, or fails with
/// an injected problem. No network, key or microphone.
nonisolated final class CannedRun: TranscriptionRun, @unchecked Sendable {
    let events: AsyncThrowingStream<TranscriptionEvent, any Error>
    private let continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    private let driver = Mutex<Task<Void, Never>?>(nil)

    init(pair: TranslatePair, pace: Double, failure: TranslateProblem?, handsOver: Bool) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self)
        let steps = CannedConversation.steps(for: pair, pace: pace)
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

    func finalize() {
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
