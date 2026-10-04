import Foundation

/// The clock the live situation reads. In DEBUG, `-RyokoClockStart <ISO 8601>`
/// (e.g. `2026-10-10T09:41:00+09:00`) starts it at that instant, and it runs on
/// from there, so a live place can be shown at another local time (demo
/// recordings). Otherwise it's the real clock.
nonisolated enum DebugClock {
    static var now: Date { shifted(.now) }

    /// `date` (a real instant) on this clock.
    static func shifted(_ date: Date) -> Date {
        #if DEBUG
        date.addingTimeInterval(offset)
        #else
        date
        #endif
    }

    #if DEBUG
    /// Set on first use (the first situation, moments after launch).
    private static let offset: TimeInterval = {
        guard let text = UserDefaults.standard.string(forKey: "RyokoClockStart"),
              let start = ISO8601DateFormatter().date(from: text) else { return 0 }
        return start.timeIntervalSinceNow
    }()
    #endif
}
