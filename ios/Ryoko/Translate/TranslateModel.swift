import AVFoundation
import Foundation
import Observation
import os
import UIKit

/// Translate's listening sessions and turns (design §4.8, W5.2).
///
/// - One session at a time. Its pair is fixed when it starts.
/// - Turns live in memory only. Each session's turns are kept for History when
///   the next one starts.
/// - Listening stops after 2 minutes without speech, when the app goes to the
///   background, and when another app interrupts the audio.
/// - The screen stays on while listening.
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

    /// Turns from earlier sessions.
    private(set) var archived: [Turn] = []
    /// The current (or last) session's turns.
    private(set) var builder: TurnBuilder?

    /// What the panes show: the latest turn, with its live words.
    var display: Turn? { builder?.display ?? archived.last }
    /// Every turn, oldest first.
    var history: [Turn] { archived + (builder?.history ?? []) }
    var isActive: Bool { phase != .idle }

    let sourceKind: TranscriptionSourceKind
    let silenceLimit: Duration

    @ObservationIgnored private var run: (any TranscriptionRun)?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = ContinuousClock.now
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var ownsIdleTimer = false
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?

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
    func start(pair: TranslatePair) async {
        guard phase == .idle else { return }
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

        if let builder { archived += builder.turns }
        builder = TurnBuilder(pair: pair, firstId: (archived.last?.id ?? 0) + 1)
        sessionPair = pair
        session += 1
        let current = session
        let run = sourceKind.makeRun(pair: pair)
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
        case (.user, .listening), (.silence, .listening):
            phase = .finishing
            level = 0
            run.finish()
        default:
            run.cancel()
            ended(session: session, problem: nil)
        }
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
        builder?.endSession()
        phase = .idle
        level = 0
        run = nil
        watchdog?.cancel()
        watchdog = nil
        setIdleTimerDisabled(false)
        if let problem {
            self.problem = problem
            lastStop = nil
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
            case .user, nil: return "Tap to start"
            }
        case .starting: return "Connecting…"
        case .listening: return "Listening"
        case .finishing: return "Finishing…"
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
