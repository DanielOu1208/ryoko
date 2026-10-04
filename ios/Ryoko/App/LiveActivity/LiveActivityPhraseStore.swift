import Foundation
import os

/// The phrases the Live Activity has shown, kept on the device so its deep link
/// (`ryoko://show?phrase=<id>`) can open the full `Phrase` in Show mode, even on
/// a cold start after the app was closed (design §4.11). The activity's payload
/// only carries the id, the local script and the gloss.
///
/// Holds the last few phrases, newest first, in UserDefaults (a few hundred
/// bytes each).
@MainActor
final class LiveActivityPhraseStore {
    static let defaultsKey = "RyokoLiveActivityPhrases"

    private let defaults: UserDefaults
    private let limit: Int
    private var phrases: [Phrase]

    init(defaults: UserDefaults = .standard, limit: Int = 6) {
        self.defaults = defaults
        self.limit = limit
        phrases = Self.load(from: defaults)
    }

    /// Keeps `phrase`, replacing an older one with the same id.
    func keep(_ phrase: Phrase) {
        phrases.removeAll { $0.id == phrase.id }
        phrases.insert(phrase, at: 0)
        if phrases.count > limit { phrases.removeLast(phrases.count - limit) }
        do {
            defaults.set(try JSONEncoder().encode(phrases), forKey: Self.defaultsKey)
        } catch {
            RyokoLog.liveActivity.error("Couldn't save the activity's phrase: \(String(describing: error), privacy: .public)")
        }
    }

    /// The kept phrase with this id, newest first.
    func phrase(id: String) -> Phrase? {
        phrases.first { $0.id == id }
    }

    private static func load(from defaults: UserDefaults) -> [Phrase] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Phrase].self, from: data)) ?? []
    }
}

nonisolated extension RyokoLog {
    static let liveActivity = Logger(subsystem: subsystem, category: "live-activity")
}
