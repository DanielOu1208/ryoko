import Foundation
import os

/// `RyokoAPI` over URLSession, against the agent server.
///
/// Every request carries `Authorization: Bearer <app token>`, `X-Install-Id` and
/// `X-Client-Version` (design §7). The configuration is read on every request, so
/// a base-URL override from Me applies without a relaunch.
nonisolated struct LiveRyokoAPI: RyokoAPI {
    private let session: URLSession
    private let configuration: @Sendable () throws -> RyokoAPIConfiguration

    /// Seconds a JSON request may take. Place cards target under 3 s.
    static let jsonTimeout: TimeInterval = 30
    /// Seconds a Mimo stream may go without a byte. The server pings every 15 s
    /// and gives up on a run after 25–30 s.
    static let streamIdleTimeout: TimeInterval = 45

    init(
        session: URLSession = .shared,
        configuration: @escaping @Sendable () throws -> RyokoAPIConfiguration = { try RyokoAPIConfiguration.current() }
    ) {
        self.session = session
        self.configuration = configuration
    }

    func placeCard(_ request: PlaceCardRequest) async throws -> PlaceCardResponse {
        try await postJSON("v1/place-card", body: request)
    }

    func discover(_ request: DiscoverRequest) async throws -> DiscoverResponse {
        try await postJSON("v1/discover", body: request)
    }

    func allergyCard(_ request: AllergyCardRequest) async throws -> AllergyCardResponse {
        try await postJSON("v1/allergy-card", body: request)
    }

    func mimoMessages(sessionId: String, request: MimoMessageRequest) -> AsyncThrowingStream<MimoEvent, any Error> {
        let session = self.session
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.stream(
                        session: session,
                        configuration: configuration,
                        sessionId: sessionId,
                        request: request,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - JSON endpoints

    @concurrent
    private func postJSON<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        let config = try configuration()
        let urlRequest = try Self.makeRequest(
            url: config.baseURL.appending(path: path),
            config: config,
            body: body,
            accept: "application/json",
            timeout: Self.jsonTimeout
        )
        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.mapped(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        RyokoLog.api.info("POST /\(path, privacy: .public) → \(status) in \(ContinuousClock.now - started, privacy: .public)")
        guard (200..<300).contains(status) else {
            throw Self.error(status: status, body: data)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            RyokoLog.api.error("POST /\(path, privacy: .public) returned an off-contract body: \(String(describing: error), privacy: .public)")
            throw RyokoAPIError.invalidResponse(String(describing: error))
        }
    }

    // MARK: - Mimo stream

    private static func stream(
        session: URLSession,
        configuration: @Sendable () throws -> RyokoAPIConfiguration,
        sessionId: String,
        request: MimoMessageRequest,
        continuation: AsyncThrowingStream<MimoEvent, any Error>.Continuation
    ) async throws {
        let config = try configuration()
        let url = config.baseURL
            .appending(path: "v1/sessions")
            .appending(component: sessionId)
            .appending(path: "messages")
        var urlRequest = try makeRequest(
            url: url,
            config: config,
            body: request,
            accept: "text/event-stream",
            timeout: streamIdleTimeout
        )
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (bytes, response) = try await session.bytes(for: urlRequest)
        // `AsyncBytes` doesn't stop reading when its task is cancelled, so cancel
        // the data task itself. That closes the connection, and the server aborts the run.
        let dataTask = bytes.task
        try await withTaskCancellationHandler {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            RyokoLog.api.info("POST /v1/sessions/…/messages → \(status)")
            guard (200..<300).contains(status) else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 64 * 1024 { break }
                }
                throw error(status: status, body: body)
            }
            try await SSELineReader.read(bytes.lines) { event in
                continuation.yield(event)
            }
        } onCancel: {
            dataTask.cancel()
        }
    }

    // MARK: - Helpers

    private static func makeRequest(
        url: URL,
        config: RyokoAPIConfiguration,
        body: some Encodable,
        accept: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.appToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.installId, forHTTPHeaderField: "X-Install-Id")
        request.setValue(config.clientVersion, forHTTPHeaderField: "X-Client-Version")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// The typed error for a non-2xx response: the error envelope when there is one.
    static func error(status: Int, body: Data) -> RyokoAPIError {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
            return .server(status: status, envelope.error)
        }
        return .http(status: status)
    }

    /// Maps URLSession errors to `RyokoAPIError`, and a cancelled request to `CancellationError`.
    static func mapped(_ error: any Error) -> any Error {
        if error is RyokoAPIError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : RyokoAPIError.transport(urlError.code)
        }
        return error
    }
}
