import Foundation

// Mirror of contracts/src/errors.ts (design §7.8).

/// Error code from the server. Open set: an unknown code still decodes.
nonisolated struct ErrorCode: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let unauthorized = ErrorCode(rawValue: "unauthorized")
    static let rateLimited = ErrorCode(rawValue: "rate_limited")
    static let sessionBusy = ErrorCode(rawValue: "session_busy")
    static let invalidRequest = ErrorCode(rawValue: "invalid_request")
    static let invalidModelOutput = ErrorCode(rawValue: "invalid_model_output")
    static let modelError = ErrorCode(rawValue: "model_error")
    static let timeout = ErrorCode(rawValue: "timeout")
    static let budgetExceeded = ErrorCode(rawValue: "budget_exceeded")

    static let known: [ErrorCode] = [
        .unauthorized, .rateLimited, .sessionBusy, .invalidRequest,
        .invalidModelOutput, .modelError, .timeout, .budgetExceeded,
    ]
}

nonisolated struct ErrorBody: Codable, Hashable, Sendable {
    var code: ErrorCode
    var message: String
    var retryable: Bool
}

/// Body of every non-2xx JSON response: `{ "error": { code, message, retryable } }`.
nonisolated struct ErrorEnvelope: Codable, Hashable, Sendable {
    var error: ErrorBody
}
