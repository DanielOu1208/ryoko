import Foundation

/// `RyokoAPI` that answers from the bundled contract examples, with a little
/// latency so loading states show. Use it in previews, and to work on the app
/// without a server.
///
/// - Place cards: the Tokyo example when the situation's language is Japanese,
///   otherwise the Shanghai one.
/// - Discover: the Jing'an example. Allergy card: the Japanese buckwheat example.
/// - Mimo: replays `mimo.sse.txt` event by event, with the requested session id.
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
        let file: FixtureFile = LangCode(tag: request.situation.localLanguage) == .ja
            ? .placeCardTokyoResponse
            : .placeCardResponse
        return try load(PlaceCardResponse.self, file)
    }

    func discover(_ request: DiscoverRequest) async throws -> DiscoverResponse {
        try await respond()
        return try load(DiscoverResponse.self, .discoverResponse)
    }

    func allergyCard(_ request: AllergyCardRequest) async throws -> AllergyCardResponse {
        try await respond()
        return try load(AllergyCardResponse.self, .allergyCardResponse)
    }

    func mimoMessages(sessionId: String, request: MimoMessageRequest) -> AsyncThrowingStream<MimoEvent, any Error> {
        let fixture = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await fixture.respond()
                    let events = try SSELineReader.events(inTranscript: fixture.source.text(.mimoStream))
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
