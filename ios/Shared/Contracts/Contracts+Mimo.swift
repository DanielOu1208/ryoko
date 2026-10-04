import Foundation

// Mirrors of contracts/src/mimo.ts and tools.ts (design §6.4, §7.7).
// POST /v1/sessions/:id/messages, answered with an SSE stream of `MimoEvent`s.

// MARK: - Request

/// A MapKit POI near the situation, attached to every Mimo message (at most 20).
nonisolated struct NearbyPlace: Codable, Hashable, Sendable {
    var name: String
    var localName: String?
    var category: CategorySlug
    var distanceMeters: Int
}

nonisolated struct MimoMessageRequest: Codable, Hashable, Sendable {
    /// Unique per message, e.g. a UUID string.
    var clientMessageId: String
    /// At most 2,000 characters.
    var message: String
    var profile: Profile
    var situation: Situation
    var nearby: [NearbyPlace]?
    /// Set by "Ask Mimo about this place"; doesn't change the active situation.
    var subjectPlace: Place?
}

// MARK: - Tools

/// Mimo's tool names. Open set: an unknown tool still decodes.
nonisolated struct ToolName: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let showPlaces = ToolName(rawValue: "show_places")
    static let webSearch = ToolName(rawValue: "web_search")
    /// The travel guides in Snowflake (design §8.4). Its details are sources, like web_search's.
    static let searchGuides = ToolName(rawValue: "search_guides")
}

/// A place Mimo names. Mimo never sends coordinates; the device resolves the name.
nonisolated struct ShownPlace: Codable, Hashable, Sendable {
    var name: String
    var localName: String?
    /// One line in the home language.
    var why: String
    /// Stop number (1–5) when this is part of a plan.
    var order: Int?
    /// Suggested local clock time for a plan stop, `HH:mm`.
    var when: String?
}

nonisolated struct ShowPlacesDetails: Codable, Hashable, Sendable {
    var places: [ShownPlace]
}

nonisolated struct WebSource: Codable, Hashable, Sendable {
    var title: String
    /// Always http or https.
    var url: String

    var link: URL? { URL(string: url) }
}

nonisolated struct WebSearchDetails: Codable, Hashable, Sendable {
    var sources: [WebSource]
}

// MARK: - Stream events

/// Why a Mimo run ended. Open set: an unknown reason still decodes.
nonisolated struct StopReason: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let stop = StopReason(rawValue: "stop")
    static let length = StopReason(rawValue: "length")
    static let turnLimit = StopReason(rawValue: "turn_limit")
    static let toolLimit = StopReason(rawValue: "tool_limit")
    static let aborted = StopReason(rawValue: "aborted")
}

/// The end of a tool call. `details` is typed by tool name.
nonisolated struct MimoToolEnd: Hashable, Sendable {
    nonisolated enum Details: Hashable, Sendable {
        case showPlaces(ShowPlacesDetails)
        /// Sources from `web_search` or `search_guides`.
        case webSearch(WebSearchDetails)
        /// A tool this build doesn't know. Its details are dropped.
        case unknown
    }

    var id: String
    var name: ToolName
    /// On failure `ok` is false and the list in `details` is empty.
    var ok: Bool
    var details: Details
}

/// One SSE event: a single `data: {json}` line (design §7.7).
/// Event types this build doesn't know decode as `.unknown` and should be ignored.
nonisolated enum MimoEvent: Hashable, Sendable {
    case start(sessionId: String, runId: String)
    case text(delta: String)
    case phrase(Phrase)
    case toolStart(id: String, name: ToolName, label: String)
    case toolEnd(MimoToolEnd)
    case done(stopReason: StopReason)
    /// An error inside the stream. The stream ends after it.
    case error(ErrorBody)
    /// An event type this build doesn't know. Ignore it.
    case unknown(type: String)
}

nonisolated extension MimoEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, sessionId, runId, delta, phrase, id, name, label, ok, details, stopReason, code, message, retryable
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "start":
            self = .start(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                runId: try c.decode(String.self, forKey: .runId)
            )
        case "text":
            self = .text(delta: try c.decode(String.self, forKey: .delta))
        case "phrase":
            self = .phrase(try c.decode(Phrase.self, forKey: .phrase))
        case "tool_start":
            self = .toolStart(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(ToolName.self, forKey: .name),
                label: try c.decode(String.self, forKey: .label)
            )
        case "tool_end":
            let name = try c.decode(ToolName.self, forKey: .name)
            let details: MimoToolEnd.Details
            switch name {
            case .showPlaces: details = .showPlaces(try c.decode(ShowPlacesDetails.self, forKey: .details))
            case .webSearch, .searchGuides: details = .webSearch(try c.decode(WebSearchDetails.self, forKey: .details))
            default: details = .unknown
            }
            self = .toolEnd(MimoToolEnd(
                id: try c.decode(String.self, forKey: .id),
                name: name,
                ok: try c.decode(Bool.self, forKey: .ok),
                details: details
            ))
        case "done":
            self = .done(stopReason: try c.decode(StopReason.self, forKey: .stopReason))
        case "error":
            self = .error(ErrorBody(
                code: try c.decode(ErrorCode.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message),
                retryable: try c.decode(Bool.self, forKey: .retryable)
            ))
        default:
            self = .unknown(type: type)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .start(sessionId, runId):
            try c.encode("start", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(runId, forKey: .runId)
        case let .text(delta):
            try c.encode("text", forKey: .type)
            try c.encode(delta, forKey: .delta)
        case let .phrase(phrase):
            try c.encode("phrase", forKey: .type)
            try c.encode(phrase, forKey: .phrase)
        case let .toolStart(id, name, label):
            try c.encode("tool_start", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(label, forKey: .label)
        case let .toolEnd(end):
            try c.encode("tool_end", forKey: .type)
            try c.encode(end.id, forKey: .id)
            try c.encode(end.name, forKey: .name)
            try c.encode(end.ok, forKey: .ok)
            switch end.details {
            case let .showPlaces(details): try c.encode(details, forKey: .details)
            case let .webSearch(details): try c.encode(details, forKey: .details)
            case .unknown: try c.encode([String: String](), forKey: .details)
            }
        case let .done(stopReason):
            try c.encode("done", forKey: .type)
            try c.encode(stopReason, forKey: .stopReason)
        case let .error(body):
            try c.encode("error", forKey: .type)
            try c.encode(body.code, forKey: .code)
            try c.encode(body.message, forKey: .message)
            try c.encode(body.retryable, forKey: .retryable)
        case let .unknown(type):
            try c.encode(type, forKey: .type)
        }
    }
}
