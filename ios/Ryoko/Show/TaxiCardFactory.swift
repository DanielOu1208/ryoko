import Foundation

/// Builds the taxi card for a place (design §4.6). No model is involved.
///
/// The Nearby and cards workstream (W3) owns this file and replaces the body
/// with the real card:
/// - the address from `MKReverseGeocodingRequest` with the local `preferredLocale`
/// - the name rule from §4.6 (the map item's name only if its script matches,
///   otherwise `placeNameLocal`)
/// - the fixed phrase from `contracts/tables/allergy-templates.json`
/// - an `MKMapSnapshotter` image
///
/// The Map workstream (W4) calls it from place details. Nearby's quick card calls
/// it too. Keep this signature stable.
enum TaxiCardFactory {
    /// The taxi card for `place`, in `language` (BCP-47, e.g. `zh-Hans`).
    /// `placeNameLocal` comes from that place's place card, when there is one.
    @MainActor
    static func card(for place: Place, language: String, placeNameLocal: String? = nil) async -> TaxiShowCard {
        // Placeholder until W3 lands: the place's own name and address, no snapshot.
        TaxiShowCard(
            language: language,
            name: placeNameLocal ?? place.localName ?? place.name,
            address: place.address ?? "",
            phrase: Phrase(id: "taxi-\(language)", lang: language, local: "", romanization: nil, gloss: "Please take me here"),
            coordinate: place.coordinate,
            snapshot: nil
        )
    }
}
