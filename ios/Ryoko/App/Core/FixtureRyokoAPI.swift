import Foundation

/// `RyokoAPI` that answers from the bundled contract examples, with a little
/// latency so loading states show. Use it in previews, and to work on the app
/// without a server.
///
/// Each call answers with the example for its local language, picked the way the
/// faux server picks (`FixtureVariants`):
/// - Place card and discover: by `situation.localLanguage`. Japanese gets Tokyo
///   (Menya Kaze, Shinjuku picks); anything else gets Shanghai (Wutong Coffee, Jing'an picks).
/// - Allergy card: by `request.language`. Chinese gets the kiwi card; anything else
///   the Japanese buckwheat card.
/// - Translate: by `request.to`. Japanese gets the ramen order; anything else the
///   café order, whatever was typed. The same language comes back as typed.
/// - Soniox key: there's no key server, so it throws `.notConfigured` and
///   Translate falls back to the build's key, as it does offline.
/// - Place photos: every place has none, as on a server without a Foursquare
///   key, so thumbnails show Look Around or a satellite tile.
/// - Mimo: by `situation.localLanguage`. Chinese replays `mimo.zh-hans.sse.txt`;
///   anything else `mimo.sse.txt`. Event by event, with the requested session id.
nonisolated struct FixtureRyokoAPI: RyokoAPI {
    var source: FixtureSource = .mainBundle
    /// Delay before a JSON response, and before the first stream event.
    var latency: Duration = .milliseconds(350)
    /// Delay between stream events.
    var eventInterval: Duration = .milliseconds(90)
    /// When set, every call fails with this error, to show error states.
    var failure: RyokoAPIError?

    /// A fixture that fails like the server does when a Mimo run is already going
    /// (the `error.session-busy.response.json` example).
    static func sessionBusy(source: FixtureSource = .mainBundle) -> FixtureRyokoAPI {
        let body = (try? source.decode(ErrorEnvelope.self, from: .errorSessionBusy))?.error
            ?? ErrorBody(code: .sessionBusy, message: "Mimo is still answering your last message.", retryable: true)
        return FixtureRyokoAPI(source: source, failure: .server(status: 409, body))
    }

    func placeCard(_ request: PlaceCardRequest) async throws -> PlaceCardResponse {
        try await respond()
        return try load(PlaceCardResponse.self, FixtureVariants.placeCard.file(for: request.situation.localLanguage))
    }

    func discover(_ request: DiscoverRequest) async throws -> DiscoverResponse {
        try await respond()
        return try load(DiscoverResponse.self, FixtureVariants.discover.file(for: request.situation.localLanguage))
    }

    func allergyCard(_ request: AllergyCardRequest) async throws -> AllergyCardResponse {
        try await respond()
        return try load(AllergyCardResponse.self, FixtureVariants.allergyCard.file(for: request.language))
    }

    func translate(_ request: TranslateRequest) async throws -> TranslateResponse {
        try await respond()
        if request.from.lowercased() == request.to.lowercased() {
            return TranslateResponse(translation: request.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try load(TranslateResponse.self, FixtureVariants.translate.file(for: request.to))
    }

    func sonioxKey() async throws -> SonioxKeyResponse {
        try await respond()
        throw RyokoAPIError.notConfigured("fixtures have no Soniox key server")
    }

    func placePhotos(_ request: PlacePhotosRequest) async throws -> PlacePhotosResponse {
        try await respond()
        var seen = Set<String>()
        return PlacePhotosResponse(photos: request.places.compactMap { place in
            seen.insert(place.key).inserted ? PlacePhoto(key: place.key) : nil
        })
    }

    func mimoMessages(sessionId: String, request: MimoMessageRequest) -> AsyncThrowingStream<MimoEvent, any Error> {
        let fixture = self
        let transcript = FixtureVariants.mimoStream.file(for: request.situation.localLanguage)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await fixture.respond()
                    let events = try SSELineReader.events(inTranscript: fixture.source.text(transcript))
                    for event in events {
                        if case let .start(_, runId) = event {
                            continuation.yield(.start(sessionId: sessionId, runId: runId))
                        } else {
                            continuation.yield(event)
                        }
                        try await Task.sleep(for: fixture.eventInterval)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func respond() async throws {
        try await Task.sleep(for: latency)
        if let failure { throw failure }
    }

    private func load<T: Decodable>(_ type: T.Type, _ file: FixtureFile) throws -> T {
        do {
            return try source.decode(type, from: file)
        } catch let error as RyokoAPIError {
            throw error
        } catch {
            throw RyokoAPIError.invalidResponse("Fixture \(file.fileName): \(error)")
        }
    }
}
