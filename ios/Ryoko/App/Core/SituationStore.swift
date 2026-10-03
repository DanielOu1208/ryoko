import Foundation
import Observation

/// What a look-ahead preview needs (design §4.2). The Map's place sheet fills it
/// from the `MKMapItem`; the store works out the local language and clock.
nonisolated struct SituationPreview: Hashable, Sendable {
    var place: Place
    /// The committed date and time.
    var date: Date
    /// The place's time zone (`MKMapItem.timeZone`, then reverse geocoding, then the device's).
    var timeZone: TimeZone
    var city: String
    var district: String?
    /// ISO 3166-1 alpha-2.
    var countryCode: String
}

/// The active situation, live or previewed (design §4.2, W2.3). Everything
/// follows it: the Nearby card, Mimo picks, Translate's pair and Mimo's context.
/// Features read `situation`; only the store builds one.
///
/// **The clock.** `situation` changes when the place or the preview changes,
/// and when the local hour turns (`hourBucket`), not every minute, so it's safe
/// as a `.task(id:)` key. A live situation's `localTime` is therefore only as
/// fresh as its hour. So:
/// - build every request body from `currentSituation()` (a live clock re-stamped
///   to now; a preview keeps its committed time), never from `situation` as is;
/// - show a live clock with `TimelineView(.everyMinute)` and
///   `currentSituation(at: context.date)`.
///
/// Only the protocol and a fixture live here. The shell builds the real store.
@MainActor
protocol SituationStore: AnyObject, Observable {
    /// The active situation, or nil while no place or city is known.
    var situation: Situation? { get }
    /// Live mode: the nearest places to confirm (up to three).
    var nearbyCandidates: [Place] { get }

    /// Confirms where you are (live mode).
    func confirm(_ place: Place)
    /// Starts previewing a place at a chosen time.
    func startPreview(_ preview: SituationPreview)
    /// "Back to here": ends the preview.
    func endPreview()
}

extension SituationStore {
    var isPreviewing: Bool { situation?.mode == .preview }

    /// The active situation as of `date`, for a request body or a clock: a live
    /// situation is re-stamped to `date` in its own time zone; a preview keeps
    /// its committed time. Key `.task(id:)` on `situation`, not on this.
    func currentSituation(at date: Date = .now) -> Situation? {
        situation?.stamped(at: date)
    }

    /// The situation's local language, if it's one Ryoko has a table row for.
    var localLanguage: LangCode? { situation.flatMap { LangCode(tag: $0.localLanguage) } }
}

/// A store that starts in the Shanghai fixture situation and keeps changes in memory.
@MainActor
@Observable
final class FixtureSituationStore: SituationStore {
    private(set) var situation: Situation?
    private(set) var nearbyCandidates: [Place]
    @ObservationIgnored private var liveSituation: Situation?

    init(situation: Situation? = Fixtures.shanghai, nearbyCandidates: [Place]? = nil) {
        self.situation = situation
        self.liveSituation = situation?.mode == .live ? situation : nil
        self.nearbyCandidates = nearbyCandidates ?? situation?.place.map { [$0] } ?? []
    }

    func confirm(_ place: Place) {
        let base = liveSituation ?? situation
        let zone = base?.zone ?? .current
        let live = Situation(
            mode: .live,
            date: .now,
            timeZone: zone,
            place: place,
            city: base?.city ?? "Unknown",
            district: base?.district,
            countryCode: base?.countryCode ?? "CA",
            localLanguage: base?.localLanguage ?? LangCode.en.tag
        )
        liveSituation = live
        situation = live
    }

    func startPreview(_ preview: SituationPreview) {
        if situation?.mode == .live { liveSituation = situation }
        situation = Situation(
            mode: .preview,
            date: preview.date,
            timeZone: preview.timeZone,
            place: preview.place,
            city: preview.city,
            district: preview.district,
            countryCode: preview.countryCode,
            localLanguage: (LangCode.forRegion(preview.countryCode) ?? .en).tag
        )
    }

    func endPreview() {
        situation = liveSituation
    }
}
