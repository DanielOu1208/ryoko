import CoreLocation
import MapKit
import UIKit
import os

/// Builds the taxi card for a place (design §4.6). **No model is involved.**
///
/// - **Name:** the map item's name (`place.name`) only if its script matches
///   the target language (`ScriptMatch`; MapKit names follow the UI language),
///   otherwise `placeNameLocal` from the place card, otherwise `place.localName`.
/// - **Address:** `MKReverseGeocodingRequest` with `preferredLocale` from the
///   `LangCode` table (`zh_Hans_CN`, `ja_JP`). It falls back to the
///   device-language address, then to the place's own address.
/// - **Phrase:** the fixed "Please take me here" from the bundled templates.
/// - **Snapshot:** an `MKMapSnapshotter` image with a pin, shown whole so its
///   attribution stays visible.
///
/// The Map workstream (W4) calls `card(for:language:placeNameLocal:)` from place
/// card (Taxi). Keep that signature stable.
/// Cards are cached for the session per place, language and appearance.
enum TaxiCardFactory {
    /// The taxi card for `place`, in `language` (BCP-47, e.g. `zh-Hans`).
    /// `placeNameLocal` comes from that place's place card, when there is one.
    @MainActor
    static func card(for place: Place, language: String, placeNameLocal: String? = nil) async -> TaxiShowCard {
        await build(place: place, language: language, placeNameLocal: placeNameLocal, storedAddress: nil)
    }

    /// The taxi card for the home base (when no place is
    /// known). The home base keeps its own `localName` and `addressLocal`; the
    /// stored address is used when it's in the target language's script.
    @MainActor
    static func card(forHomeBase home: HomeBase, language: String) async -> TaxiShowCard {
        let place = Place(
            id: nil,
            name: home.name,
            localName: home.localName,
            category: .hotel,
            address: home.address,
            coordinate: home.coordinate
        )
        return await build(place: place, language: language, placeNameLocal: nil, storedAddress: home.addressLocal)
    }

    // MARK: Building

    @MainActor private static var cache: [String: TaxiShowCard] = [:]

    @MainActor
    private static func build(place: Place, language: String, placeNameLocal: String?, storedAddress: String?) async -> TaxiShowCard {
        let traits = sceneTraits()
        let key = [
            place.id ?? String(format: "%.5f,%.5f", place.coordinate.lat, place.coordinate.lon),
            place.name, language, placeNameLocal ?? "", storedAddress ?? "",
            String(traits.userInterfaceStyle.rawValue),
        ].joined(separator: "|")
        if let cached = cache[key] { return cached }

        async let address = address(for: place, language: language, storedAddress: storedAddress)
        async let snapshot = snapshot(of: place.coordinate, traits: traits)
        let card = TaxiShowCard(
            language: language,
            name: name(for: place, language: language, placeNameLocal: placeNameLocal),
            address: await address,
            phrase: phrase(for: language),
            coordinate: place.coordinate,
            snapshot: await snapshot
        )
        // Keep it only when complete, so a missing map or address is tried again next time.
        if card.snapshot != nil, !card.address.isEmpty { cache[key] = card }
        return card
    }

    /// The design §4.6 name rule.
    nonisolated static func name(for place: Place, language: String, placeNameLocal: String?) -> String {
        if ScriptMatch.matches(place.name, language: language, fromMapKit: true) { return place.name }
        if let local = placeNameLocal?.trimmingCharacters(in: .whitespaces), !local.isEmpty { return local }
        if let local = place.localName?.trimmingCharacters(in: .whitespaces), !local.isEmpty { return local }
        return place.name
    }

    /// The fixed phrase for `language`, or English when there's no template.
    nonisolated static func phrase(for language: String) -> Phrase {
        if let (tag, phrase) = AllergyTemplates.bundled?.taxiPhrase(for: language) {
            return Phrase(id: "taxi-\(tag)", lang: tag, local: phrase.local, romanization: phrase.romanization, gloss: phrase.gloss)
        }
        let english = "Please take me here"
        return Phrase(id: "taxi-en", lang: LangCode.en.tag, local: english, romanization: nil, gloss: english)
    }

    // MARK: Address

    @MainActor
    private static func address(for place: Place, language: String, storedAddress: String?) async -> String {
        if let stored = storedAddress?.trimmingCharacters(in: .whitespaces), !stored.isEmpty,
           ScriptMatch.matches(stored, language: language) {
            return stored
        }
        let row = LangCode(tag: language)
        let locale = row?.locale ?? Locale(identifier: language)
        let cjk = row == .zhHans || row == .zhHant || row == .ja
        if let local = await reverseGeocode(place.coordinate, locale: locale, cjk: cjk) { return local }
        RyokoLog.show.info("Taxi card: no \(language, privacy: .public) address, using the device language")
        if let device = await reverseGeocode(place.coordinate, locale: nil, cjk: false) { return device }
        return place.address ?? storedAddress ?? ""
    }

    /// One address line from `MKReverseGeocodingRequest` (`CLGeocoder` is deprecated).
    /// `locale` nil means the device's language. MapKit's single-line form joins
    /// parts with ", " even in Japanese (`東京都新宿区, 西新宿1丁目`), so for CJK
    /// the lines are joined the local way (`joinedCJK`).
    @MainActor
    private static func reverseGeocode(_ coordinate: Coordinate, locale: Locale?, cjk: Bool) async -> String? {
        let location = CLLocation(latitude: coordinate.lat, longitude: coordinate.lon)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        if let locale { request.preferredLocale = locale }
        do {
            for item in try await request.mapItems {
                let representations = item.addressRepresentations
                let line = cjk
                    ? representations?.fullAddress(includingRegion: false, singleLine: false).map(joinedCJK)
                    : representations?.fullAddress(includingRegion: false, singleLine: true)
                if let line = (line ?? item.address?.fullAddress)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    return line
                }
            }
        } catch let error as MKError where error.code == .placemarkNotFound {
            return nil
        } catch {
            RyokoLog.show.error("Taxi card geocoding failed: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    /// Address lines joined with nothing between CJK text (`東京都新宿区西新宿1丁目`),
    /// and a space where Latin letters or digits meet (`〒160-0022 東京都…`).
    nonisolated static func joinedCJK(_ multiline: String) -> String {
        let parts = multiline
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))) }
            .filter { !$0.isEmpty }
        func isCJK(_ character: Character?) -> Bool {
            guard let scalar = character?.unicodeScalars.first else { return false }
            let value = scalar.value
            return scalar.properties.isIdeographic || (0x3000...0x30FF).contains(value) || (0xFF00...0xFFEF).contains(value)
        }
        return parts.dropFirst().reduce(parts.first ?? "") { joined, part in
            isCJK(joined.last) && isCJK(part.first) ? joined + part : joined + " " + part
        }
    }

    // MARK: Snapshot

    /// The current scene's appearance and scale, so the map matches Show mode.
    @MainActor
    private static func sceneTraits() -> UITraitCollection {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.traitCollection ?? UITraitCollection.current
    }

    @MainActor
    private static func snapshot(of coordinate: Coordinate, traits: UITraitCollection) async -> UIImage? {
        let center = CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lon)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: 900, longitudinalMeters: 900)
        options.size = CGSize(width: 360, height: 240)
        options.traitCollection = traits
        options.preferredConfiguration = MKStandardMapConfiguration()
        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            return withPin(snapshot, at: center, dark: traits.userInterfaceStyle == .dark)
        } catch {
            RyokoLog.show.error("Taxi card snapshot failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Draws a monochrome pin on the snapshot. The image keeps its full size, so
    /// MapKit's attribution in the corner isn't cropped.
    @MainActor
    private static func withPin(_ snapshot: MKMapSnapshotter.Snapshot, at center: CLLocationCoordinate2D, dark: Bool) -> UIImage {
        let image = snapshot.image
        let point = snapshot.point(for: center)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let symbol = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: dark ? [.black, .white] : [.white, .black]))
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
            guard let pin = UIImage(systemName: "mappin.circle.fill", withConfiguration: symbol) else { return }
            pin.draw(in: CGRect(
                x: point.x - pin.size.width / 2,
                y: point.y - pin.size.height / 2,
                width: pin.size.width,
                height: pin.size.height
            ))
        }
    }
}
