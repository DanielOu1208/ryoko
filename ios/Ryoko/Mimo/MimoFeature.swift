import Foundation
import os

/// The Mimo tab (design §4.9, §6.2, §7.7, W6).
///
/// - `MimoView`: the tab. Header (the avatar, where and when), transcript,
///   starters and the composer with the model picker (`MimoModelButton`).
/// - `MimoModelStore`: the server's models and your pick, sent with each message.
/// - `MimoChat`: one conversation. Sends messages over SSE, turns events into
///   ordered segments, resolves `show_places` names with the shared
///   `PlaceResolver`, and saves the transcript.
/// - `MimoTranscript`: what is kept on the device, one JSON file per session in
///   `Application Support/Ryoko/Mimo/`.
///
/// Cross-tab hand-offs go through `AppRouter` only: `router.show = .phrase(_)`
/// for a phrase block, `router.openMap(selecting:)` for a place chip,
/// `router.showOnMap(_)` for "Show on map", and `router.mimoQuestion` for
/// "Ask Mimo about this place" (the chat keeps the place as its subject).
nonisolated enum MimoFeature {
    /// The contract's limit on one message (design §7.7).
    static let messageLimit = 2_000
    /// The contract's limit on attached nearby places (design §7.7).
    static let nearbyLimit = 20
    /// How far around the place to look for nearby places to attach.
    static let nearbyRadiusMeters: Double = 500
    /// How long Send stays off after the server answers 409 `session_busy`.
    static let busyCooldown: Duration = .seconds(3)
    /// How many old sessions to keep on the device.
    static let keptSessions = 20
    /// The shortest time "Searching the web…" shows. Exa often answers in well
    /// under a second, too quick to read; the rest of the reply waits for it.
    static let minimumSearchTime: Duration = .seconds(2.5)
}

extension RyokoLog {
    /// The Mimo tab: sends, stream ends, and router hand-offs.
    nonisolated static let mimo = Logger(subsystem: subsystem, category: "mimo")
}
