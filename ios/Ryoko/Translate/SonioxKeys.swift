import Foundation
import os

/// Where a listening session's Soniox key came from. Logged; the key never is.
nonisolated enum SonioxKeySource: String, Sendable {
    /// A short-lived, single-use key from the Ryoko server (`POST /v1/soniox-key`, T2.6).
    case server
    /// The key built into the app (Secrets.xcconfig): the fallback.
    case bundled
}

/// A key for one Soniox session (design §6.4, T2.6).
///
/// Before each session it asks the Ryoko server for a temporary key. It falls
/// back to the build's own key only when the server can't hand one out:
/// - there's no server (fixture mode, or no base URL or token in this build),
/// - the server can't be reached (offline, timed out, or a gateway error such
///   as Funnel's 502 while the server is down),
/// - the server doesn't offer keys (404 from an older server, or 503 when it
///   has no Soniox key of its own).
///
/// Any other answer from the server (a refused app token, its rate limit,
/// Soniox refusing to mint) stops the session with `.keyServer`: the bundled
/// key would hit the same wall, or hide a setup problem.
nonisolated struct SonioxKeyProvider: Sendable {
    var api: any RyokoAPI
    /// The build's key. Injectable for checks.
    var bundledKey: @Sendable () -> String? = { SonioxCredentials.apiKey() }

    /// A key and where it came from. Throws `TranslateProblem`, or
    /// `CancellationError` when the session stops first.
    func key() async throws -> (value: String, source: SonioxKeySource) {
        let reason: String
        do {
            let minted = try await api.sonioxKey()
            RyokoLog.translate.notice("Soniox key: temporary, from the server (expires \(minted.expiresAt, privacy: .public))")
            return (minted.apiKey, .server)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RyokoAPIError {
            guard let fallback = Self.fallbackReason(error) else {
                RyokoLog.translate.error("Soniox key: the server refused (\(Self.describe(error), privacy: .public))")
                throw TranslateProblem.keyServer(error.errorDescription)
            }
            reason = fallback
        } catch {
            reason = "the request failed"
        }
        guard let bundled = bundledKey() else {
            RyokoLog.translate.error("Soniox key: none (\(reason, privacy: .public), and this build has no key of its own)")
            throw TranslateProblem.missingKey
        }
        RyokoLog.translate.notice("Soniox key: this build's own, because \(reason, privacy: .public)")
        return (bundled, .bundled)
    }

    /// Why falling back to the build's key is right for `error`, or nil when
    /// the session should stop instead.
    static func fallbackReason(_ error: RyokoAPIError) -> String? {
        switch error {
        case .notConfigured:
            "there's no server in this mode"
        case let .transport(code):
            "the server is unreachable (URLError \(code.rawValue))"
        case let .http(status):
            "the server is unreachable (HTTP \(status) from a gateway)"
        case .invalidResponse:
            "the server's answer wasn't a key"
        case let .server(status, _) where status == 404:
            "the server has no key endpoint (an older server)"
        case let .server(status, body) where status == 503 && body.code == .modelError:
            "the server has no Soniox key"
        case .server:
            nil
        }
    }

    /// For logs: the status and code, never a message body.
    private static func describe(_ error: RyokoAPIError) -> String {
        switch error {
        case let .server(status, body): "\(status) \(body.code.rawValue)"
        case let .http(status): "HTTP \(status)"
        case let .transport(code): "URLError \(code.rawValue)"
        case .invalidResponse: "invalid response"
        case .notConfigured: "not configured"
        }
    }
}
