import Foundation

/// The part of the day at a place, from design §9.3. It always uses the place's
/// time zone (the active situation's), never the device's, so a previewed 8 AM
/// in Shanghai is morning wherever the phone is.
///
/// | Part | Local hours |
/// | --- | --- |
/// | morning | 05:00–10:59 |
/// | midday | 11:00–15:59 |
/// | evening | 16:00–19:59 |
/// | night | 20:00–04:59 |
nonisolated enum PartOfDay: String, CaseIterable, Hashable, Sendable {
    case morning
    case midday
    case evening
    case night

    /// The part of the day for a local hour (0–23). Out-of-range hours wrap.
    init(hour: Int) {
        switch ((hour % 24) + 24) % 24 {
        case 5..<11: self = .morning
        case 11..<16: self = .midday
        case 16..<20: self = .evening
        default: self = .night
        }
    }

    /// The part of the day at `date`, as seen in `timeZone`.
    init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.init(hour: calendar.component(.hour, from: date))
    }

    /// The part of the day of a situation's local time, or nil if it doesn't parse.
    init?(situation: Situation) {
        guard let date = situation.date, let zone = situation.zone else { return nil }
        self.init(date: date, timeZone: zone)
    }

    /// The first local hour of this part of the day.
    var startHour: Int {
        switch self {
        case .morning: 5
        case .midday: 11
        case .evening: 16
        case .night: 20
        }
    }

    /// Sentence-case name for the UI.
    var displayName: String {
        switch self {
        case .morning: "Morning"
        case .midday: "Midday"
        case .evening: "Evening"
        case .night: "Night"
        }
    }
}
