import Foundation

// Mirror of contracts/src/situation.ts (design §7.1).
// The device owns geography and the clock; the server never uses its own.

/// A place as the device knows it from MapKit. Also used for Mimo's `subjectPlace`.
nonisolated struct Place: Codable, Hashable, Sendable {
    /// `MKMapItem.Identifier` raw value; nil when MapKit has none.
    var id: String?
    var name: String
    var localName: String?
    var category: CategorySlug
    var address: String?
    var coordinate: Coordinate
}

nonisolated enum SituationMode: String, Codable, Hashable, Sendable, CaseIterable {
    case live
    case preview
}

nonisolated struct Situation: Codable, Hashable, Sendable {
    var mode: SituationMode
    /// Local wall-clock time with its UTC offset, e.g. `2026-10-05T15:00:00+08:00`.
    /// Build it with `Situation.clock(for:in:)`.
    var localTime: String
    /// IANA time zone, e.g. `Asia/Shanghai`.
    var timeZone: String
    /// Local date and hour, e.g. `2026-10-05T15`.
    var hourBucket: String
    /// nil in city-only mode; written as `null`.
    var place: Place?
    var city: String
    var district: String?
    /// ISO 3166-1 alpha-2, e.g. `CN`.
    var countryCode: String
    /// BCP-47 tag worked out on the device (design §4.2), e.g. `zh-Hans`.
    var localLanguage: String

    private enum CodingKeys: String, CodingKey {
        case mode, localTime, timeZone, hourBucket, place, city, district, countryCode, localLanguage
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(localTime, forKey: .localTime)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(hourBucket, forKey: .hourBucket)
        try c.encode(place, forKey: .place) // required key, `null` in city-only mode
        try c.encode(city, forKey: .city)
        try c.encodeIfPresent(district, forKey: .district)
        try c.encode(countryCode, forKey: .countryCode)
        try c.encode(localLanguage, forKey: .localLanguage)
    }
}

nonisolated extension Situation {
    /// Builds a situation whose `localTime` and `hourBucket` are `date` as seen in `timeZone`.
    init(
        mode: SituationMode,
        date: Date,
        timeZone: TimeZone,
        place: Place?,
        city: String,
        district: String? = nil,
        countryCode: String,
        localLanguage: String
    ) {
        let clock = Situation.clock(for: date, in: timeZone)
        self.init(
            mode: mode,
            localTime: clock.localTime,
            timeZone: timeZone.identifier,
            hourBucket: clock.hourBucket,
            place: place,
            city: city,
            district: district,
            countryCode: countryCode,
            localLanguage: localLanguage
        )
    }

    /// Formats `date` in `timeZone` as the contract's `localTime`
    /// (`2026-10-05T15:00:00+08:00`) and `hourBucket` (`2026-10-05T15`).
    static func clock(for date: Date, in timeZone: TimeZone) -> (localTime: String, hourBucket: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        let day = "\(pad(c.year ?? 0, 4))-\(pad(c.month ?? 0))-\(pad(c.day ?? 0))"
        let hour = pad(c.hour ?? 0)
        let localTime = "\(day)T\(hour):\(pad(c.minute ?? 0)):\(pad(c.second ?? 0))"
            + "\(sign)\(pad(magnitude / 3600)):\(pad(magnitude % 3600 / 60))"
        return (localTime, "\(day)T\(hour)")
    }

    /// The situation as of `date`. A live situation gets `localTime` and
    /// `hourBucket` re-stamped in its own time zone; a preview keeps its
    /// committed time. Requests send this, so the server always gets the actual
    /// local time (design §4.2), however long ago the situation was built.
    func stamped(at date: Date = .now) -> Situation {
        guard mode == .live, let zone else { return self }
        let clock = Situation.clock(for: date, in: zone)
        var stamped = self
        stamped.localTime = clock.localTime
        stamped.hourBucket = clock.hourBucket
        return stamped
    }

    /// The first instant after `date` that starts a local hour in `timeZone`,
    /// which is when `hourBucket` can next change. Not always on the device's
    /// hour: Kolkata is UTC+05:30.
    static func nextHour(after date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.nextDate(
            after: date,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(3600)
    }

    /// The instant `localTime` describes, or nil if it doesn't parse.
    var date: Date? {
        try? Date(localTime, strategy: .iso8601)
    }

    /// The situation's time zone, or nil for an unknown identifier.
    var zone: TimeZone? {
        TimeZone(identifier: timeZone)
    }

    private static func pad(_ value: Int, _ width: Int = 2) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
