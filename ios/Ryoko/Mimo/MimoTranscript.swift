import Foundation

/// One Mimo conversation as the device keeps it (design §4.9): the session id
/// the server knows it by, and every turn so far. Saved as JSON per session.
nonisolated struct MimoTranscript: Codable, Hashable, Sendable {
    /// Sent as `:id` in `POST /v1/sessions/:id/messages`. A lowercased UUID.
    var sessionId: String
    var createdAt: Date
    var updatedAt: Date
    /// The place "Ask Mimo" started this chat about (design §4.9). Every
    /// message carries it as `subjectPlace`; the first shows it as a preview.
    var subject: Place?
    var turns: [MimoTurn]

    init(sessionId: String = UUID().uuidString.lowercased(), createdAt: Date = .now, subject: Place? = nil, turns: [MimoTurn] = []) {
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.subject = subject
        self.turns = turns
    }

    var isEmpty: Bool { turns.isEmpty }
}

/// One message you sent and Mimo's reply to it.
nonisolated struct MimoTurn: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    /// What you asked.
    var message: String
    /// The place the message is about, shown above it as a preview that opens
    /// the Map: the chat's subject, on its first message.
    var place: Place?
    var sentAt: Date
    /// Mimo's reply as ordered segments, appended in SSE order.
    var segments: [MimoSegment]
    var status: Status
    /// The quiet tool line ("Finding places…") while a tool runs.
    var toolLine: String?

    enum Status: Codable, Hashable, Sendable {
        /// Sent; the reply is streaming (or hasn't started yet).
        case streaming
        /// The run ended with `done`. A reason other than `stop` means it was cut short.
        case done(StopReason)
        /// You stopped it, or the app quit while it was streaming.
        case stopped
        /// The request failed, or the stream ended with an `error` event.
        case failed(MimoFailure)
    }

    init(message: String, place: Place? = nil, sentAt: Date = .now) {
        id = UUID()
        self.message = message
        self.place = place
        self.sentAt = sentAt
        segments = []
        status = .streaming
    }

    var isStreaming: Bool { status == .streaming }

    /// Every web source in the reply, in order, without repeats. Shown together
    /// under the reply (design §4.9).
    var sources: [WebSource] {
        var seen = Set<String>()
        return segments.flatMap { segment -> [WebSource] in
            if case let .sources(sources) = segment { sources } else { [] }
        }
        .filter { seen.insert($0.url).inserted }
    }

    /// Appends a text delta to the last text segment, or starts a new one after
    /// a phrase, places or sources segment.
    mutating func appendText(_ delta: String) {
        if case let .text(existing)? = segments.last {
            segments[segments.count - 1] = .text(existing + delta)
        } else {
            segments.append(.text(delta))
        }
    }
}

/// Why a reply failed, in words that are safe to show.
nonisolated struct MimoFailure: Codable, Hashable, Sendable {
    var message: String
    var retryable: Bool
    /// The contract error code, when the server sent one.
    var code: ErrorCode?

    var isSessionBusy: Bool { code == .sessionBusy }
}

/// One piece of a reply (design §4.9): text, a phrase block, place chips or
/// web sources.
nonisolated enum MimoSegment: Codable, Hashable, Sendable {
    /// Plain sentences, rendered with inline-only Markdown.
    case text(String)
    /// A sayable phrase from a phrase tag (design §6.2). Opens Show mode.
    case phrase(Phrase)
    /// The places from one `show_places` call.
    case places(MimoPlaces)
    /// The sources from one `web_search` call.
    case sources([WebSource])
}

/// The places from one `show_places` call, and what the device found for them.
nonisolated struct MimoPlaces: Codable, Hashable, Sendable {
    /// The tool call's id.
    var callId: String
    /// What Mimo named, in its order.
    var shown: [ShownPlace]
    /// The local language when Mimo named them, for tagging `localName`.
    var language: String?
    /// Where the names were looked up around; nil when no place is known, and
    /// then nothing can be found.
    var near: Coordinate?
    /// nil while the names are being looked up. Then the places found, in plan
    /// order for a plan and Mimo's order otherwise. Misses are dropped silently.
    var found: [MimoFoundPlace]?

    /// A plan's stops carry an order and a time (design §4.9 "Plan a few hours").
    var isPlan: Bool { shown.contains { $0.order != nil } }

    /// The names to look up: by stop number for a plan, Mimo's order otherwise.
    var lookupOrder: [ShownPlace] {
        guard isPlan else { return shown }
        return shown.enumerated()
            .sorted { ($0.element.order ?? Int.max, $0.offset) < ($1.element.order ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// The From Mimo pins for "Show on map".
    var pins: [FromMimoPin] {
        (found ?? []).map { $0.pin(near: near) }
    }
}

/// A place Mimo named that the device found on the map.
nonisolated struct MimoFoundPlace: Codable, Hashable, Sendable, Identifiable {
    var shown: ShownPlace
    var place: Place
    var distanceMeters: Double

    init(_ resolved: ResolvedPlace, shown: ShownPlace) {
        self.shown = shown
        place = resolved.place
        distanceMeters = resolved.distanceMeters
    }

    var id: String { resolved(near: nil).id }

    /// The resolver's value again, for `FromMimoPin`.
    func resolved(near: Coordinate?) -> ResolvedPlace {
        ResolvedPlace(
            query: PlaceQuery(
                name: shown.name,
                localName: shown.localName,
                category: nil,
                near: near ?? place.coordinate
            ),
            place: place,
            distanceMeters: distanceMeters
        )
    }

    func pin(near: Coordinate?) -> FromMimoPin {
        FromMimoPin(shown: shown, resolved: resolved(near: near))
    }
}
