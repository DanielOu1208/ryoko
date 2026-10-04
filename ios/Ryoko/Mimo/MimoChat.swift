import Foundation
import Observation
import os

/// What one message carries besides its text (design §4.9, §7.7). The view
/// builds it from the environment at send time, so every message has the
/// current profile, a re-stamped situation and the subject place.
struct MimoSendContext {
    var api: any RyokoAPI
    /// The app's one shared resolver, for `show_places` names.
    var resolver: any PlaceResolver
    var profile: Profile
    /// `situationStore.currentSituation()`: a live clock re-stamped to now.
    var situation: Situation
    /// Up to 20 MapKit POIs around the place, when they've been looked up.
    var nearby: [NearbyPlace]?
    /// `router.mimoSubject`.
    var subjectPlace: Place?
    /// Where to look up the names Mimo gives: the subject place, the active
    /// place, or the last location fix. nil means none can be found.
    var anchor: Coordinate?
}

/// One Mimo conversation (W6.1–W6.4): sends messages over SSE, turns the
/// events into each reply's ordered segments, looks up `show_places` names
/// with the shared `PlaceResolver`, and saves the transcript per session.
///
/// - Send is off while a reply streams, so the server's one-run-per-session
///   lock (409 `session_busy`) isn't hit in normal use. If it is anyway (a
///   stopped run the server is still finishing), the reply shows the server's
///   message and Send stays off for a few seconds.
/// - An `error` event ends the reply; nothing after it is read.
@MainActor
@Observable
final class MimoChat {
    private(set) var transcript: MimoTranscript

    /// True while a reply streams.
    private(set) var isReplying = false
    /// True for a few seconds after a 409 `session_busy`.
    private(set) var isCoolingDown = false

    @ObservationIgnored private let store: MimoTranscriptStore
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var replyingTurn: UUID?
    @ObservationIgnored private var lookupTasks: [Task<Void, Never>] = []
    /// `show_places` calls being looked up now, so one is never looked up twice.
    @ObservationIgnored private var lookupsInFlight: Set<String> = []
    @ObservationIgnored private var cooldownTask: Task<Void, Never>?

    /// The tab's conversation, loaded from the device on first use.
    static let shared = MimoChat()

    init(store: MimoTranscriptStore = .standard, transcript: MimoTranscript? = nil) {
        self.store = store
        self.transcript = transcript ?? store.loadCurrent()
        store.setCurrent(self.transcript.sessionId)
    }

    var sessionId: String { transcript.sessionId }
    var turns: [MimoTurn] { transcript.turns }
    var isEmpty: Bool { transcript.isEmpty }

    /// Whether a new message can go now.
    var canSend: Bool { !isReplying && !isCoolingDown }

    // MARK: Sending

    /// Sends `text` (trimmed, at most 2,000 characters) and streams the reply.
    func send(_ text: String, context: MimoSendContext) {
        let message = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MimoFeature.messageLimit))
        guard !message.isEmpty, canSend else { return }
        let turn = MimoTurn(message: message)
        transcript.turns.append(turn)
        save()
        start(turn.id, message: message, context: context)
    }

    /// Asks again after a failed or stopped reply, replacing it.
    func retry(_ turnID: UUID, context: MimoSendContext) {
        guard canSend, let turn = turns.first(where: { $0.id == turnID }) else { return }
        update(turnID) { turn in
            turn.segments = []
            turn.toolLine = nil
            turn.status = .streaming
        }
        start(turnID, message: turn.message, context: context)
    }

    /// Stops the reply that's streaming. Cancelling the request closes the
    /// connection, and the server aborts the run.
    func stop() {
        guard let turnID = replyingTurn else { return }
        update(turnID) { turn in
            turn.toolLine = nil
            if turn.isStreaming { turn.status = .stopped }
        }
        runTask?.cancel()
        RyokoLog.mimo.info("Stopped the reply")
    }

    /// New chat: a new session id and an empty transcript. The old session
    /// stays on the device.
    func newChat() {
        leaveCurrent()
        transcript = MimoTranscript()
        store.setCurrent(transcript.sessionId)
        store.prune()
        RyokoLog.mimo.info("New chat \(self.transcript.sessionId, privacy: .public)")
    }

    /// Opens a saved chat from the history. The one on screen stays on the device.
    func open(sessionId: String) {
        guard sessionId != transcript.sessionId,
              let saved = store.loadSettled(sessionId: sessionId) else { return }
        leaveCurrent()
        transcript = saved
        store.setCurrent(sessionId)
        RyokoLog.mimo.info("Opened chat \(sessionId, privacy: .public)")
    }

    /// The saved chats, most recent first.
    func history() -> [MimoChatSummary] {
        store.history()
    }

    /// Deletes a saved chat. Deleting the one on screen starts a new chat.
    func delete(sessionId: String) {
        if sessionId == transcript.sessionId {
            leaveCurrent()
            transcript = MimoTranscript()
            store.setCurrent(transcript.sessionId)
        }
        store.delete(sessionId: sessionId)
    }

    /// Stops any reply and lookups, and saves the chat before another replaces it.
    private func leaveCurrent() {
        if let turnID = replyingTurn {
            update(turnID) { turn in
                turn.toolLine = nil
                if turn.isStreaming { turn.status = .stopped }
            }
        }
        runTask?.cancel()
        runTask = nil
        replyingTurn = nil
        isReplying = false
        lookupTasks.forEach { $0.cancel() }
        lookupTasks = []
        lookupsInFlight = []
        save()
    }

    /// Looks up places that were still being looked up when the app quit.
    func resumeLookups(resolver: any PlaceResolver) {
        for turn in turns {
            for (index, segment) in turn.segments.enumerated() {
                if case let .places(places) = segment, places.found == nil {
                    lookUp(places, turnID: turn.id, segmentIndex: index, resolver: resolver)
                }
            }
        }
    }

    // MARK: Streaming

    private func start(_ turnID: UUID, message: String, context: MimoSendContext) {
        let nearby = context.nearby.map { Array($0.prefix(MimoFeature.nearbyLimit)) }
        let request = MimoMessageRequest(
            clientMessageId: UUID().uuidString.lowercased(),
            message: message,
            profile: context.profile,
            situation: context.situation,
            nearby: nearby?.isEmpty == false ? nearby : nil,
            subjectPlace: context.subjectPlace
        )
        let stream = context.api.mimoMessages(sessionId: sessionId, request: request)
        isReplying = true
        replyingTurn = turnID
        RyokoLog.mimo.info(
            "Sending to \(self.sessionId, privacy: .public): \(request.situation.localLanguage, privacy: .public), \(nearby?.count ?? 0) nearby, subject \(context.subjectPlace?.name ?? "none", privacy: .public)"
        )
        runTask = Task { [weak self] in
            await self?.consume(stream, turnID: turnID, context: context)
        }
    }

    private func consume(
        _ stream: AsyncThrowingStream<MimoEvent, any Error>,
        turnID: UUID,
        context: MimoSendContext
    ) async {
        var ended = false
        do {
            for try await event in stream {
                ended = apply(event, to: turnID, context: context)
                if ended { break } // `done` and `error` are terminal
            }
            if !ended && !Task.isCancelled {
                fail(turnID, MimoFailure(message: "The reply was cut off.", retryable: true))
            }
        } catch is CancellationError {
            // Stopped, or New chat.
        } catch let error as RyokoAPIError {
            if error.code == .sessionBusy { coolDown() }
            fail(turnID, MimoFailure(
                message: error.errorDescription ?? "Something went wrong.",
                retryable: error.isRetryable,
                code: error.code
            ))
        } catch {
            fail(turnID, MimoFailure(message: "Something went wrong.", retryable: true))
        }
        // New chat may have replaced the transcript, and a newer run may own the flags.
        guard replyingTurn == turnID else { return }
        update(turnID) { turn in
            turn.toolLine = nil
            if turn.isStreaming { turn.status = .stopped }
        }
        isReplying = false
        replyingTurn = nil
        runTask = nil
        save()
    }

    /// Applies one event. Returns true when the reply has ended.
    private func apply(_ event: MimoEvent, to turnID: UUID, context: MimoSendContext) -> Bool {
        switch event {
        case .start, .unknown:
            return false
        case let .text(delta):
            update(turnID) { $0.appendText(delta) }
            return false
        case let .phrase(phrase):
            update(turnID) { $0.segments.append(.phrase(phrase)) }
            return false
        case let .toolStart(_, _, label):
            update(turnID) { $0.toolLine = label }
            return false
        case let .toolEnd(end):
            update(turnID) { $0.toolLine = nil }
            appendToolResult(end, to: turnID, context: context)
            return false
        case let .done(stopReason):
            update(turnID) { turn in
                turn.toolLine = nil
                turn.status = .done(stopReason)
            }
            RyokoLog.mimo.info("Reply done: \(stopReason.rawValue, privacy: .public)")
            return true
        case let .error(body):
            if body.code == .sessionBusy { coolDown() }
            fail(turnID, MimoFailure(message: body.message, retryable: body.retryable, code: body.code))
            return true
        }
    }

    private func appendToolResult(_ end: MimoToolEnd, to turnID: UUID, context: MimoSendContext) {
        guard end.ok else { return } // a failed tool has empty details
        switch end.details {
        case let .showPlaces(details) where !details.places.isEmpty:
            let places = MimoPlaces(
                callId: end.id,
                shown: details.places,
                language: context.situation.localLanguage,
                near: context.anchor,
                found: nil
            )
            var segmentIndex: Int?
            update(turnID) { turn in
                turn.segments.append(.places(places))
                segmentIndex = turn.segments.count - 1
            }
            if let segmentIndex {
                lookUp(places, turnID: turnID, segmentIndex: segmentIndex, resolver: context.resolver)
            }
        case let .webSearch(details):
            let sources = details.sources.filter { source in
                guard let scheme = source.link?.scheme?.lowercased() else { return false }
                return scheme == "https" || scheme == "http"
            }
            if !sources.isEmpty {
                update(turnID) { $0.segments.append(.sources(sources)) }
            }
        default:
            break
        }
    }

    /// Finds each name with the shared resolver, one at a time, dropping misses
    /// silently (design §4.7). Runs beside the stream, so text keeps coming.
    private func lookUp(_ places: MimoPlaces, turnID: UUID, segmentIndex: Int, resolver: any PlaceResolver) {
        let key = "\(turnID.uuidString)/\(places.callId)"
        guard lookupsInFlight.insert(key).inserted else { return }
        let sessionId = self.sessionId
        let task = Task { [weak self] in
            defer { self?.lookupsInFlight.remove(key) }
            var found: [MimoFoundPlace] = []
            if let near = places.near {
                for shown in places.lookupOrder {
                    if Task.isCancelled { return }
                    let query = PlaceQuery(name: shown.name, localName: shown.localName, category: nil, near: near)
                    guard let resolved = await resolver.resolve(query) else { continue }
                    let candidate = MimoFoundPlace(resolved, shown: shown)
                    if !found.contains(where: { $0.id == candidate.id }) {
                        found.append(candidate)
                    }
                }
            }
            guard let self, !Task.isCancelled, self.sessionId == sessionId else { return }
            self.update(turnID) { turn in
                guard turn.segments.indices.contains(segmentIndex),
                      case var .places(segment) = turn.segments[segmentIndex],
                      segment.callId == places.callId
                else { return }
                segment.found = found
                turn.segments[segmentIndex] = .places(segment)
            }
            RyokoLog.mimo.info("Found \(found.count) of \(places.shown.count) places")
            if !self.isReplying { self.save() }
        }
        lookupTasks.append(task)
    }

    // MARK: Helpers

    private func fail(_ turnID: UUID, _ failure: MimoFailure) {
        update(turnID) { turn in
            turn.toolLine = nil
            turn.status = .failed(failure)
        }
        RyokoLog.mimo.error("Reply failed: \(failure.code?.rawValue ?? "client", privacy: .public)")
    }

    /// Keeps Send off for a moment after `session_busy`: the server is still
    /// finishing the last run.
    private func coolDown() {
        isCoolingDown = true
        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(for: MimoFeature.busyCooldown)
            guard !Task.isCancelled else { return }
            self?.isCoolingDown = false
        }
    }

    private func update(_ turnID: UUID, _ change: (inout MimoTurn) -> Void) {
        guard let index = transcript.turns.firstIndex(where: { $0.id == turnID }) else { return }
        change(&transcript.turns[index])
    }

    private func save() {
        transcript.updatedAt = .now
        store.save(transcript)
    }
}

#if DEBUG
extension MimoChat {
    /// DEBUG: replaces the conversation (launch hooks only).
    func debugReplaceTranscript(_ replacement: MimoTranscript) {
        transcript = replacement
        store.setCurrent(replacement.sessionId)
    }
}
#endif
