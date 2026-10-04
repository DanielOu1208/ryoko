import Foundation

/// The agent server's API (design §6.4, §7). `LiveRyokoAPI` talks to the server;
/// `FixtureRyokoAPI` returns the bundled contract examples.
///
/// Every method throws `RyokoAPIError` (or `CancellationError` when the caller's
/// task is cancelled).
nonisolated protocol RyokoAPI: Sendable {
    /// `POST /v1/place-card`: phrases and tips for the active situation.
    func placeCard(_ request: PlaceCardRequest) async throws -> PlaceCardResponse

    /// `POST /v1/discover`: Mimo picks nearby and the Hidden gems layer.
    func discover(_ request: DiscoverRequest) async throws -> DiscoverResponse

    /// `POST /v1/allergy-card`: free-text allergens only. Chip allergens use the templates.
    func allergyCard(_ request: AllergyCardRequest) async throws -> AllergyCardResponse

    /// `POST /v1/translate`: typed or edited text in Translate (tier 2).
    /// Cancelling the calling task cancels the request, and the server stops
    /// the generation unless someone else is waiting for the same text.
    func translate(_ request: TranslateRequest) async throws -> TranslateResponse

    /// `POST /v1/soniox-key`: a short-lived, single-use Soniox key for one
    /// listening session (tier 2). The key is a secret: never log it.
    func sonioxKey() async throws -> SonioxKeyResponse

    /// `GET /v1/mimo-models`: the models and thinking levels Mimo's picker offers.
    func mimoModels() async throws -> MimoModelsResponse

    /// `POST /v1/trip-events`: a batch of what you did on the trip, for Mimo's
    /// trip memory (design §8.3). Fire and forget: `TripMemoryLog` sends it
    /// and nothing waits on the answer.
    func tripEvents(_ request: TripEventsRequest) async throws -> TripEventsResponse

    /// `POST /v1/sessions/:id/messages`: one Mimo run as a stream of events.
    ///
    /// - The stream throws `RyokoAPIError` if the request fails before streaming
    ///   (for example 409 `session_busy`).
    /// - An `error` event inside the stream arrives as `.error(_)`, not as a throw.
    /// - Event types this build doesn't know arrive as `.unknown(_)`; ignore them.
    /// - Stopping iteration (or cancelling the consuming task) cancels the request,
    ///   which aborts the run on the server.
    func mimoMessages(sessionId: String, request: MimoMessageRequest) -> AsyncThrowingStream<MimoEvent, any Error>
}

/// Endpoints that a stand-in API (a DEBUG script, a preview) may not
/// implement: they answer as if there's no server, so Translate falls back the
/// way it does offline, Mimo hides its model picker and trip memory drops its
/// batch. `LiveRyokoAPI` and `FixtureRyokoAPI` implement them all.
nonisolated extension RyokoAPI {
    func translate(_ request: TranslateRequest) async throws -> TranslateResponse {
        throw RyokoAPIError.notConfigured("translate")
    }

    func sonioxKey() async throws -> SonioxKeyResponse {
        throw RyokoAPIError.notConfigured("soniox-key")
    }

    func mimoModels() async throws -> MimoModelsResponse {
        throw RyokoAPIError.notConfigured("mimo-models")
    }

    func tripEvents(_ request: TripEventsRequest) async throws -> TripEventsResponse {
        throw RyokoAPIError.notConfigured("trip-events")
    }
}

/// Everything that can go wrong talking to the server, typed.
nonisolated enum RyokoAPIError: Error, Sendable, Equatable {
    /// The server answered with the JSON error envelope (design §7.8).
    case server(status: Int, ErrorBody)
    /// A non-2xx response without a readable error envelope.
    case http(status: Int)
    /// A 2xx response that doesn't match the contract.
    case invalidResponse(String)
    /// The server couldn't be reached, or the connection dropped.
    case transport(URLError.Code)
    /// The base URL or app token is missing from Info.plist (Secrets.xcconfig).
    case notConfigured(String)

    /// The contract error code, when the server sent one.
    var code: ErrorCode? {
        if case let .server(_, body) = self { body.code } else { nil }
    }

    /// Whether trying again may help.
    var isRetryable: Bool {
        switch self {
        case let .server(_, body): body.retryable
        case let .http(status): status >= 500 || status == 429
        case .transport: true
        case .invalidResponse, .notConfigured: false
        }
    }
}

nonisolated extension RyokoAPIError: LocalizedError {
    /// Short, sentence-case text that's safe to show in the UI.
    var errorDescription: String? {
        switch self {
        case let .server(_, body):
            body.message
        case .http:
            "The server had a problem. Try again in a moment."
        case .invalidResponse:
            "The server sent something unexpected."
        case .transport(.notConnectedToInternet), .transport(.networkConnectionLost):
            "You're offline."
        case .transport(.timedOut):
            "The server took too long to answer."
        case .transport:
            "Can't reach the server."
        case .notConfigured:
            "The server isn't set up in this build."
        }
    }
}
