import Foundation

// The Soniox real-time WebSocket protocol (design §4.8, tracker D2 notes),
// written from the public docs. Foundation only, so the turn-rule harness
// (`TurnRuleCheck.swift`) compiles it on the Mac too.
//
// - Endpoint: `wss://stt-rt.soniox.com/transcribe-websocket`.
// - The first message is the JSON configuration, with the API key in it.
// - Then binary frames of 16 kHz mono `pcm_s16le`, about 120 ms each.
// - An empty frame ends the stream; Soniox answers with `finished: true`.
// - Errors arrive as a JSON message with `error_code` (an HTTP-style number).

/// One token from Soniox. Final tokens are sent once; non-final tokens are
/// re-sent in every response until they become final, so each response's
/// non-final tokens replace the previous ones.
nonisolated struct SonioxToken: Decodable, Hashable, Sendable {
    var text: String
    var isFinal: Bool
    /// Soniox language code of this token's text, e.g. `zh`.
    var language: String?
    /// `original`, `translation` or `none` (no translation for this token).
    var translationStatus: String?
    /// For a translation token: the language it was translated from.
    var sourceLanguage: String?
    var startMs: Double?
    var endMs: Double?

    private enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
        case language
        case translationStatus = "translation_status"
        case sourceLanguage = "source_language"
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    init(
        text: String,
        isFinal: Bool,
        language: String?,
        translationStatus: String? = nil,
        sourceLanguage: String? = nil,
        startMs: Double? = nil,
        endMs: Double? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.language = language
        self.translationStatus = translationStatus
        self.sourceLanguage = sourceLanguage
        self.startMs = startMs
        self.endMs = endMs
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language)
        translationStatus = try c.decodeIfPresent(String.self, forKey: .translationStatus)
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage)
        startMs = try c.decodeIfPresent(Double.self, forKey: .startMs)
        endMs = try c.decodeIfPresent(Double.self, forKey: .endMs)
    }

    /// Soniox's endpoint marker: the speaker finished an utterance.
    static let endMarker = "<end>"
    /// Marks the end of a manual finalize request: everything said before the
    /// request is final by now. Translate sends one when you hand over the turn.
    static let finalizeMarker = "<fin>"

    var isEndpoint: Bool { text == Self.endMarker }
    var isMarker: Bool { text == Self.endMarker || text == Self.finalizeMarker }
    var isTranslation: Bool { translationStatus == "translation" }
    /// What someone said (as opposed to a translation of it or a marker).
    var isOriginal: Bool { !isTranslation && !isMarker }
}

/// One message from Soniox: tokens, the end of the stream, or an error.
nonisolated struct SonioxResponse: Decodable, Hashable, Sendable {
    var tokens: [SonioxToken]
    var finished: Bool
    var errorCode: Int?
    var errorType: String?
    var errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
    }

    init(tokens: [SonioxToken], finished: Bool = false, errorCode: Int? = nil, errorType: String? = nil, errorMessage: String? = nil) {
        self.tokens = tokens
        self.finished = finished
        self.errorCode = errorCode
        self.errorType = errorType
        self.errorMessage = errorMessage
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decodeIfPresent([SonioxToken].self, forKey: .tokens) ?? []
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode)
        errorType = try c.decodeIfPresent(String.self, forKey: .errorType)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    /// The problem this message reports, if it's an error.
    var problem: TranslateProblem? {
        errorCode.map { TranslateProblem.soniox(code: $0, type: errorType, message: errorMessage) }
    }
}

/// The configuration message (the first frame), minus the key.
nonisolated struct SonioxConfig: Hashable, Sendable {
    static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    static let model = "stt-rt-v5"
    static let sampleRate = 16_000

    /// Soniox codes, e.g. `en` and `zh`.
    var languageA: String
    var languageB: String
    /// The one language to transcribe, the speaker's (manual turns, #74), or
    /// nil for either of the pair. Soniox can't change it mid-session, so a
    /// hand-over opens a new session.
    var lockedLanguage: String? = nil

    /// The JSON text of the first frame. It carries the key: never log it.
    func message(apiKey: String) throws -> String {
        let body = Body(
            api_key: apiKey,
            model: Self.model,
            audio_format: "pcm_s16le",
            sample_rate: Self.sampleRate,
            num_channels: 1,
            language_hints: lockedLanguage.map { [$0] } ?? [languageA, languageB],
            // Only ever these: no other language guessed from an accent.
            language_hints_strict: true,
            enable_language_identification: true,
            enable_endpoint_detection: true,
            translation: .init(type: "two_way", language_a: languageA, language_b: languageB)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(body), as: UTF8.self)
    }

    private nonisolated struct Body: Encodable {
        var api_key: String
        var model: String
        var audio_format: String
        var sample_rate: Int
        var num_channels: Int
        var language_hints: [String]
        var language_hints_strict: Bool
        var enable_language_identification: Bool
        var enable_endpoint_detection: Bool
        var translation: Translation

        nonisolated struct Translation: Encodable {
            var type: String
            var language_a: String
            var language_b: String
        }
    }
}

/// Everything that can stop Translate, with copy that's safe to show (design §9.6).
nonisolated enum TranslateProblem: Error, Hashable, Sendable {
    /// No Soniox key: the server couldn't hand one out, and this build has none
    /// of its own (Secrets.xcconfig).
    case missingKey
    /// The Ryoko server answered the key request with an error (T2.6). Carries
    /// the server's message, which is written to be shown.
    case keyServer(String?)
    /// 401: Soniox doesn't accept the key.
    case keyRejected
    /// 403: the key isn't allowed to do this, or a temporary key expired.
    case keyNotAllowed
    /// 402: the Soniox balance or budget is used up.
    case balanceExhausted
    /// 429: too many requests or sessions for this key.
    case rateLimited
    /// 408: Soniox stopped waiting for audio.
    case timedOut
    /// 413: the session reached its maximum length.
    case sessionTooLong
    /// 400: Soniox didn't accept the request. Carries Soniox's message.
    case badRequest(String?)
    /// 5xx: Soniox is having trouble.
    case serviceUnavailable
    /// Any other error code.
    case sonioxError(Int)
    /// No internet connection.
    case offline
    /// The network failed some other way.
    case cantReach
    /// The connection closed before Soniox finished.
    case closedUnexpectedly
    /// Microphone permission was denied.
    case microphoneDenied
    /// The microphone couldn't start (busy, no input, a route change).
    case microphoneUnavailable
    /// The other language is the same as yours, or there's no other language.
    case noPair

    static func soniox(code: Int, type: String?, message: String?) -> TranslateProblem {
        switch code {
        case 401: .keyRejected
        case 402: .balanceExhausted
        case 403: .keyNotAllowed
        case 408: .timedOut
        case 413: .sessionTooLong
        case 429: .rateLimited
        case 400: .badRequest(message)
        case 500...599: .serviceUnavailable
        default: .sonioxError(code)
        }
    }

    /// Maps a URLSession error to a problem.
    static func network(_ error: any Error) -> TranslateProblem {
        if let problem = error as? TranslateProblem { return problem }
        guard let urlError = error as? URLError else { return .cantReach }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .keyRejected
        default:
            return .cantReach
        }
    }

    var title: String {
        switch self {
        case .missingKey: "Translate isn't set up"
        case .keyServer: "Couldn't get a Soniox key"
        case .keyRejected: "Soniox key was rejected"
        case .keyNotAllowed: "Soniox key isn't allowed here"
        case .balanceExhausted: "Soniox balance is used up"
        case .rateLimited: "Soniox is busy for this key"
        case .timedOut: "Soniox stopped waiting"
        case .sessionTooLong: "Session reached its limit"
        case .badRequest: "Soniox couldn't start"
        case .serviceUnavailable: "Soniox is having trouble"
        case .sonioxError: "Soniox couldn't start"
        case .offline: "You're offline"
        case .cantReach: "Can't reach Soniox"
        case .closedUnexpectedly: "Translation stopped"
        case .microphoneDenied: "Microphone is off for Ryoko"
        case .microphoneUnavailable: "Can't use the microphone"
        case .noPair: "Choose their language"
        }
    }

    var detail: String {
        switch self {
        case .missingKey:
            "The Ryoko server didn't hand out a Soniox key, and this build has none of its own. Check the server, or add a key to Secrets.xcconfig and rebuild."
        case .keyServer(let message):
            message.map { "The Ryoko server said: \($0)" } ?? "The Ryoko server didn't hand out a key. Try again."
        case .keyRejected:
            "Soniox didn't accept the key. Try again; if it keeps happening, check the Soniox key on the server and in Secrets.xcconfig."
        case .keyNotAllowed:
            "This key can't start live translation. Check it in the Soniox console."
        case .balanceExhausted:
            "Add credit or raise the budget in the Soniox console, then try again."
        case .rateLimited:
            "Too many sessions at once. Wait a moment, then try again."
        case .timedOut:
            "No audio reached Soniox for a while. Try again."
        case .sessionTooLong:
            "Start again to keep translating."
        case .badRequest(let message):
            message.map { "Soniox said: \($0)" } ?? "The request wasn't accepted. Try again."
        case .serviceUnavailable:
            "Try again in a moment."
        case .sonioxError(let code):
            "Soniox returned error \(code). Try again."
        case .offline:
            "Translate needs a connection. Check Wi-Fi or mobile data, then try again."
        case .cantReach:
            "Check your connection, then try again."
        case .closedUnexpectedly:
            "The connection closed before Soniox finished. Try again."
        case .microphoneDenied:
            "Turn on the microphone for Ryoko in Settings to translate speech."
        case .microphoneUnavailable:
            "Another app may be using it. Try again."
        case .noPair:
            "Pick the language the other person speaks."
        }
    }

    var systemImage: String {
        switch self {
        case .missingKey, .keyServer, .keyRejected, .keyNotAllowed: "key.slash"
        case .balanceExhausted: "creditcard"
        case .rateLimited, .timedOut, .sessionTooLong: "hourglass"
        case .badRequest, .serviceUnavailable, .sonioxError, .closedUnexpectedly: "exclamationmark.triangle"
        case .offline, .cantReach: "wifi.slash"
        case .microphoneDenied, .microphoneUnavailable: "mic.slash"
        case .noPair: "character.bubble"
        }
    }

    /// Whether trying again could help without changing the build.
    var isRetryable: Bool {
        switch self {
        case .missingKey, .keyRejected, .keyNotAllowed, .microphoneDenied, .noPair: false
        default: true
        }
    }
}
