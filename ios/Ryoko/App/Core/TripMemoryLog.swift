import Foundation
import os

/// Trip memory (design §8.3): what you did on the trip, sent to the server for
/// Mimo's `<trip_memory>`. Places you said you're at, phrases you showed or
/// played, and what you typed in Translate.
///
/// - Each event is stamped with the active situation (city, country and place)
///   and the local time now, in the situation's time zone. A preview's
///   committed time is when you're looking ahead to, not when this happened,
///   and a preview's place is somewhere you aren't, so it isn't attached.
/// - Events go in batches (`POST /v1/trip-events`): after 3 s without a new
///   one, at 10, or when the app goes to the background.
/// - Fire and forget: nothing waits on it and nothing is shown. A failed batch
///   is logged and dropped, never retried.
/// - The same event (kind, text and place) within 2 minutes is kept once.
/// - Text is cut to the contract's limits (`TripEvent.cleaned()`), so a batch
///   is never refused for one long phrase.
///
/// `RyokoApp` owns the one instance; features read it with
/// `@Environment(\.tripMemory)`. Previews get `.disabled`, which keeps nothing.
@MainActor
final class TripMemoryLog {
    /// How long the log waits for another event before sending.
    static let quietPeriod: Duration = .seconds(3)
    /// Sends at once when this many are waiting.
    static let batchSize = 10
    /// A repeat within this long is skipped.
    static let repeatWindow: TimeInterval = 120

    /// The API to send through, read at send time so a switch between fixtures
    /// and the live server applies. nil keeps nothing.
    private let api: () -> (any RyokoAPI)?
    /// The active situation, re-stamped to now.
    private let situation: () -> Situation?

    private var queue: [TripEvent] = []
    /// When each recent event (by `repeatKey`) was last kept.
    private var recent: [String: Date] = [:]
    private var pendingSend: Task<Void, Never>?

    init(api: @escaping () -> (any RyokoAPI)?, situation: @escaping () -> Situation?) {
        self.api = api
        self.situation = situation
    }

    /// Keeps nothing. The environment's default, for previews.
    static var disabled: TripMemoryLog { TripMemoryLog(api: { nil }, situation: { nil }) }

    // MARK: Events

    /// "I'm here": you confirmed you're at `place`.
    func placeConfirmed(_ place: Place) {
        record(.placeConfirmed, text: place.name, place: place)
    }

    /// Show mode opened. The taxi card is an address, not a phrase, so it isn't kept.
    func shown(_ content: ShowContent) {
        guard let phrase = content.rememberedPhrase else { return }
        record(.phraseShown, text: phrase.local, meaning: phrase.gloss, language: phrase.lang)
    }

    /// Speak started playing `phrase`.
    func spoken(_ phrase: Phrase) {
        record(.phraseSpoken, text: phrase.local, meaning: phrase.gloss, language: phrase.lang)
    }

    /// A typed or edited turn in Translate, with its translation. `language` is the typed text's.
    func typed(_ text: String, translation: String, language: String) {
        record(.typedTranslation, text: text, meaning: translation, language: language)
    }

    /// Queues one event, stamped with the active situation. `place` overrides
    /// the situation's place, which is only used when it's live.
    func record(_ kind: TripEventKind, text: String, meaning: String? = nil, language: String? = nil, place: Place? = nil) {
        guard api() != nil else { return }
        let situation = situation()
        let now = DebugClock.now
        let event = TripEvent(
            kind: kind,
            at: Situation.clock(for: now, in: situation?.zone ?? .current).localTime,
            text: text,
            meaning: meaning,
            language: language,
            place: (place ?? (situation?.mode == .live ? situation?.place : nil)).map(TripEventPlace.init),
            city: situation?.city,
            countryCode: situation?.countryCode
        ).cleaned()
        guard let event else { return }

        recent = recent.filter { now.timeIntervalSince($0.value) < Self.repeatWindow }
        let key = Self.repeatKey(event)
        guard recent[key] == nil else { return }
        recent[key] = now

        queue.append(event)
        if queue.count >= Self.batchSize {
            flush()
        } else {
            pendingSend?.cancel()
            pendingSend = Task { [weak self] in
                try? await Task.sleep(for: Self.quietPeriod)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    /// Sends what's waiting now, without waiting for it.
    func flush() {
        pendingSend?.cancel()
        pendingSend = nil
        guard !queue.isEmpty, let api = api() else {
            queue.removeAll()
            return
        }
        let batch = Array(queue.prefix(TripEventsRequest.maxEvents))
        queue.removeAll()
        Task {
            do {
                let response = try await api.tripEvents(TripEventsRequest(events: batch))
                RyokoLog.memory.info("Trip memory: sent \(batch.count), stored \(response.stored)")
            } catch {
                RyokoLog.memory.info("Trip memory: dropped \(batch.count): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func repeatKey(_ event: TripEvent) -> String {
        [event.kind.rawValue, event.text, event.place?.name ?? ""].joined(separator: "\u{1F}")
    }
}

extension ShowContent {
    /// What trip memory keeps when this is shown: the phrase, or the allergy
    /// card's lines and request with your language as the meaning. nil for the
    /// taxi card, which is an address.
    var rememberedPhrase: Phrase? {
        switch self {
        case let .phrase(phrase):
            return phrase
        case let .allergy(card):
            let local = (card.lines.map(\.local) + [card.requestLocal]).filter { !$0.isEmpty }.joined(separator: "\n")
            let home = (card.lines.map(\.home) + [card.requestHome]).filter { !$0.isEmpty }.joined(separator: "\n")
            return Phrase(id: id, lang: card.language, local: local, romanization: nil, gloss: home)
        case .taxi:
            return nil
        }
    }
}

extension RyokoLog {
    /// Trip memory's batches: how many were sent and stored, or dropped.
    nonisolated static let memory = Logger(subsystem: subsystem, category: "memory")
}
