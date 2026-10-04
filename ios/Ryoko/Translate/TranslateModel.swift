import AVFoundation
import Foundation
import Observation
import os
import UIKit

/// Translate's listening sessions and turns (design §4.8, W5.2, T2.4, T2.5).
///
/// - One session at a time. Its pair is fixed when it starts.
/// - Turns live in memory only. A session's turns move to `log` when it ends;
///   typed turns (Type mode) and edits go there too.
/// - Listening stops after 2 minutes without speech, when the app goes to the
///   background, and when another app interrupts the audio.
/// - While you type or edit, listening pauses (`pause()`): the session ends
///   cleanly, and `resume()` starts a new one with the same pair.
/// - The screen stays on while listening.
/// - The app owns one model (`RyokoApp` puts it in the environment), so
///   listening carries on across tabs and the tab bar's Listening accessory
///   can show it and stop it.
@MainActor
@Observable
final class TranslateModel {
    enum Phase: Equatable {
        case idle
        /// Asking for the microphone, or connecting.
        case starting
        case listening
        /// Waiting for Soniox to finalize after Stop.
        case finishing
    }

    enum StopReason: Equatable {
        case user
        case silence
        case background
        case interrupted
        /// Paused while you type or edit; `resume()` picks up again.
        case paused
    }

    private(set) var phase: Phase = .idle
    /// Why the last session failed, if it did. Cleared by the next start.
    private(set) var problem: TranslateProblem?
    /// Why the last session stopped.
    private(set) var lastStop: StopReason?
    /// The microphone level, 0…1, for the mic button.
    private(set) var level: Float = 0
    /// The running (or last) session's pair.
    private(set) var sessionPair: TranslatePair?

    /// Turns from ended sessions, typed turns and edits.
    private(set) var log = TurnLog()
    /// The running session's turns. nil between sessions.
    private(set) var builder: TurnBuilder?
    /// Listening stopped for the editor and comes back with `resume()`.
    private(set) var isPaused = false

    /// What the panes show: the session's latest turn with its live words; or
    /// the turn you just edited; or the latest turn.
    var display: Turn? {
        if let live = builder?.display { return live }
        return log.focused ?? log.turns.last
    }
    /// Every turn, oldest first.
    var history: [Turn] { log.turns + (builder?.history ?? []) }
    var isActive: Bool { phase != .idle }
    /// Your most recent turn you can edit.
    var latestEditable: Turn? { builder == nil ? log.latestEditable : nil }

    let sourceKind: TranscriptionSourceKind
    let silenceLimit: Duration

    @ObservationIgnored private var run: (any TranscriptionRun)?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = ContinuousClock.now
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var ownsIdleTimer = false
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    /// The API the last session got its key from, for `resume()`.
    @ObservationIgnored private var lastAPI: (any RyokoAPI)?

    init(source: TranscriptionSourceKind = .microphone, silenceLimit: Duration = .seconds(120)) {
        sourceKind = source
        self.silenceLimit = silenceLimit
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.stop(.interrupted) }
        }
    }

    // MARK: Start and stop

    /// Starts listening with `pair`, asking for the microphone first if needed.
    /// - Parameter api: where the session gets its Soniox key (T2.6).
    func start(pair: TranslatePair, api: any RyokoAPI) async {
        guard phase == .idle else { return }
        isPaused = false
        lastAPI = api
        guard pair.isUsable else {
            problem = .noPair
            return
        }
        problem = nil
        lastStop = nil
        phase = .starting
        if sourceKind.needsMicrophone {
            let granted = await TranslateAudioSession.requestPermission()
            guard phase == .starting else { return } // stopped while asking
            guard granted else {
                phase = .idle
                problem = .microphoneDenied
                return
            }
        }

        builder = TurnBuilder(pair: pair, firstId: log.nextId)
        sessionPair = pair
        session += 1
        let current = session
        let run = sourceKind.makeRun(pair: pair, api: api)
        self.run = run
        lastHeard = .now
        setIdleTimerDisabled(true)
        RyokoLog.translate.notice("Listening: \(pair.label, privacy: .public) via \(self.sourceKind.rawValue, privacy: .public)")

        consumer = Task { [weak self] in
            do {
                for try await event in run.events {
                    self?.handle(event, session: current)
                }
                self?.ended(session: current, problem: nil)
            } catch {
                self?.ended(session: current, problem: TranslateProblem.network(error))
            }
        }
        startWatchdog(session: current)
    }

    /// Stops listening. A user stop lets Soniox finalize the last words; the
    /// background and interruptions stop at once.
    func stop(_ reason: StopReason) {
        guard phase != .idle else { return }
        lastStop = reason
        guard let run else {
            // Still asking for the microphone.
            phase = .idle
            return
        }
        switch (reason, phase) {
        case (.user, .listening), (.silence, .listening), (.paused, .listening):
            phase = .finishing
            level = 0
            run.finish()
        default:
            run.cancel()
            ended(session: session, problem: nil)
        }
    }

    /// Stops listening for good: from the Listening accessory, or the app
    /// leaving the screen. A pause for the editor is forgotten too.
    func stopAndForgetPause(_ reason: StopReason) {
        isPaused = false
        stop(reason)
    }

    // MARK: Pause for typing and editing (T2.4)

    /// Pauses listening while you type or edit (design §4.8: "Soniox pauses
    /// while the editor is open"). The session finishes cleanly, so its last
    /// words and translations land, and returns once it has. Does nothing
    /// when not listening.
    func pause() async {
        guard phase != .idle else { return }
        isPaused = true
        stop(.paused)
        // Soniox usually finalizes in well under a second; don't wait forever.
        let deadline = ContinuousClock.now + .seconds(5)
        while phase != .idle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if phase != .idle {
            RyokoLog.translate.notice("Pause: the session didn't finish in time, closing it")
            run?.cancel()
            ended(session: session, problem: nil)
        }
    }

    /// Listens again after `pause()`, with the same pair. Does nothing if
    /// listening wasn't paused, or was stopped since.
    func resume() async {
        guard isPaused, phase == .idle, let pair = sessionPair, let api = lastAPI else {
            isPaused = false
            return
        }
        await start(pair: pair, api: api)
    }

    // MARK: Typed turns and edits (T2.4)

    /// Adds a turn typed in Type mode. Listening is paused (or off) by now.
    func addTyped(pair: TranslatePair, text: String, translation: String) {
        if builder != nil { endSessionNow() }
        let turn = log.addTyped(pair: pair, text: text, translation: translation)
        RyokoLog.translate.notice("Typed turn \(turn.id) added (\(pair.label, privacy: .public))")
    }

    /// Replaces your words in turn `id` and their translation.
    @discardableResult
    func applyEdit(id: Int, original: String, translation: String) -> Bool {
        if builder != nil { endSessionNow() }
        let applied = log.edit(id: id, original: original, translation: translation)
        RyokoLog.translate.notice("Edit of turn \(id) \(applied ? "applied" : "refused", privacy: .public)")
        return applied
    }

    /// The turn with this id, if it's in the log (every turn is, between sessions).
    func turn(id: Int) -> Turn? {
        log.turns.first { $0.id == id }
    }

    /// Ends a session at once, keeping what it heard.
    private func endSessionNow() {
        run?.cancel()
        ended(session: session, problem: nil)
    }

    // MARK: Events

    private func handle(_ event: TranscriptionEvent, session: Int) {
        guard session == self.session else { return }
        switch event {
        case .connected:
            if phase == .starting { phase = .listening }
        case .level(let value):
            if phase == .listening { level = value }
        case .response(let response):
            if phase == .starting { phase = .listening }
            builder?.apply(response.tokens)
            if response.tokens.contains(where: { $0.isOriginal && TurnRule.isWordy($0.text) }) {
                lastHeard = .now
            }
        }
    }

    private func ended(session: Int, problem: TranslateProblem?) {
        guard session == self.session, phase != .idle else { return }
        if var builder {
            builder.endSession()
            log.archive(builder.turns)
        }
        builder = nil
        phase = .idle
        level = 0
        run = nil
        watchdog?.cancel()
        watchdog = nil
        setIdleTimerDisabled(false)
        if let problem {
            self.problem = problem
            lastStop = nil
            isPaused = false
        }
        RyokoLog.translate.notice("Stopped listening (\(problem?.title ?? "no error", privacy: .public))")
    }

    /// Stops after `silenceLimit` with no speech.
    private func startWatchdog(session: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, session == self.session, self.phase == .listening else { continue }
                if ContinuousClock.now - self.lastHeard >= self.silenceLimit {
                    RyokoLog.translate.notice("No speech for \(self.silenceLimit), stopping")
                    self.stop(.silence)
                    return
                }
            }
        }
    }

    // MARK: Screen

    /// Keeps the screen on while listening, and only undoes what it did.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        if disabled {
            guard !UIApplication.shared.isIdleTimerDisabled else { return }
            UIApplication.shared.isIdleTimerDisabled = true
            ownsIdleTimer = true
        } else if ownsIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = false
            ownsIdleTimer = false
        }
    }

    // MARK: Copy

    /// The line above the mic button.
    var statusText: String {
        if let problem { return problem.title }
        switch phase {
        case .idle:
            switch lastStop {
            case .silence: return "Stopped after \(silenceLimitText) of quiet"
            case .background: return "Stopped when Ryoko left the screen"
            case .interrupted: return "Stopped for another app's audio"
            case .paused: return isPaused ? "Paused while you type" : "Tap to start"
            case .user, nil: return "Tap to start"
            }
        case .starting: return "Connecting…"
        case .listening: return "Listening"
        case .finishing: return isPaused ? "Pausing…" : "Finishing…"
        }
    }

    private var silenceLimitText: String {
        let seconds = Int(silenceLimit.components.seconds)
        if seconds >= 60, seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(seconds) seconds"
    }
}
