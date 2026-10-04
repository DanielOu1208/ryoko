import Foundation
import os

/// The Soniox key, from the Info.plist key `RyokoSonioxAPIKey` (filled from the
/// gitignored Secrets.xcconfig), read the same way `RyokoAPIConfiguration`
/// reads the app token. Never log it.
nonisolated enum SonioxCredentials {
    static let infoKey = "RyokoSonioxAPIKey"

    /// The key, or nil when the build has none (empty, a placeholder, or an
    /// unexpanded `$(SONIOX_API_KEY)`).
    static func apiKey(bundle: Bundle = .main) -> String? {
        let raw = ((bundle.object(forInfoDictionaryKey: infoKey) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("$("), raw != "replace-me" else { return nil }
        return raw
    }
}

/// One Soniox real-time session over `URLSessionWebSocketTask` (there's no
/// Swift SDK). Open it, send ~120 ms PCM frames, end with an empty frame, and
/// read `responses()` until `finished`.
///
/// Safe to use from any thread: the task's methods are thread-safe and
/// everything else is immutable.
nonisolated final class SonioxSession: Sendable {
    private let task: URLSessionWebSocketTask
    private let configMessage: String

    init(apiKey: String, config: SonioxConfig, urlSession: URLSession = .shared) throws {
        configMessage = try config.message(apiKey: apiKey)
        var request = URLRequest(url: SonioxConfig.endpoint)
        request.timeoutInterval = 15
        task = urlSession.webSocketTask(with: request)
    }

    /// Connects and sends the configuration message.
    func open() async throws {
        task.resume()
        do {
            try await task.send(.string(configMessage))
        } catch {
            throw mapped(error)
        }
    }

    /// Sends one frame of 16 kHz mono 16-bit PCM.
    func send(audio: Data) async throws {
        do {
            try await task.send(.data(audio))
        } catch {
            throw mapped(error)
        }
    }

    /// Asks Soniox to finalize everything sent so far now; it answers with
    /// final tokens and then `<fin>`. The session carries on.
    func finalize() async {
        try? await task.send(.string(#"{"type":"finalize"}"#))
    }

    /// Ends the audio: Soniox finalizes what it heard, then sends `finished`.
    func endAudio() async {
        try? await task.send(.string(""))
    }

    /// Closes the socket. Any pending `receive` throws.
    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Soniox's messages, until `finished`. An error message ends the stream
    /// with its `TranslateProblem`.
    func responses() -> AsyncThrowingStream<SonioxResponse, any Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                let decoder = JSONDecoder()
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        guard let response = try? decoder.decode(SonioxResponse.self, from: data) else {
                            RyokoLog.translate.error("Soniox sent a message that isn't a response (\(data.count) bytes)")
                            continue
                        }
                        if let problem = response.problem {
                            RyokoLog.translate.error("Soniox error \(response.errorCode ?? 0) \(response.errorType ?? "", privacy: .public)")
                            throw problem
                        }
                        continuation.yield(response)
                        if response.finished { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapped(error))
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// A URLSession error as a problem. A handshake that came back with an HTTP
    /// status (401, 402…) maps like the JSON error with that code.
    private func mapped(_ error: any Error) -> TranslateProblem {
        if let problem = error as? TranslateProblem { return problem }
        if let http = task.response as? HTTPURLResponse, http.statusCode >= 400 {
            return .soniox(code: http.statusCode, type: nil, message: nil)
        }
        if task.closeCode != .invalid, (error as? URLError) == nil {
            return .closedUnexpectedly
        }
        return .network(error)
    }
}

extension RyokoLog {
    nonisolated static let translate = Logger(subsystem: subsystem, category: "translate")
}
