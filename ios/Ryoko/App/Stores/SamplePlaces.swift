#if DEBUG
import Foundation

/// DEBUG-only places to preview, so the app can be exercised in the simulator
/// without location or the Map tab. Names and addresses are typed by hand
/// (never MapKit output; AGENTS.md).
enum SamplePlaces {
    /// A ramen shop with a ticket machine in Nishi-Shinjuku, matching the
    /// `place-card.tokyo` fixture.
    static func tokyoRamen(at date: Date) -> SituationPreview {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        return SituationPreview(
            place: Place(
                id: nil,
                name: "Menya Kaze",
                localName: "麺屋 風",
                category: .ramen,
                address: "Nishi-Shinjuku, Shinjuku City, Tokyo",
                coordinate: Coordinate(lat: 35.6896, lon: 139.7006)
            ),
            date: date,
            timeZone: tokyo,
            city: "Tokyo",
            district: "Shinjuku",
            countryCode: "JP"
        )
    }

    /// The quick-chip hours from design §4.2, plus one at night for the gradient.
    static let hours: [(label: String, hour: Int)] = [
        ("Morning 9 AM", 9),
        ("Afternoon 3 PM", 15),
        ("Evening 7 PM", 19),
        ("Night 10 PM", 22),
    ]

    /// The next time it's `hour`:00 in `timeZone`, at most 24 hours from `now`.
    static func next(hour: Int, in timeZone: TimeZone, after now: Date = .now) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.nextDate(
            after: now,
            matching: DateComponents(hour: hour, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now
    }
}

extension AppSituationStore {
    /// DEBUG: previews the Tokyo ramen shop at the next `hour`:00 Tokyo time.
    func previewSample(hour: Int = 19) {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        startPreview(SamplePlaces.tokyoRamen(at: SamplePlaces.next(hour: hour, in: tokyo)))
    }
}
#endif
