import MapKit
import SwiftUI

/// The places from one `show_places` call (design §4.9), as one card in the
/// reply: a small map with their pins (numbered for a plan) that opens the
/// Map's From Mimo layer, then a row per place the device found, like the Map
/// sheet's rows. Tap a row to open the Map on that place. Names the map didn't
/// find are dropped silently.
struct MimoPlacesView: View {
    let places: MimoPlaces
    var onSelect: (MimoFoundPlace) -> Void
    var onShowOnMap: () -> Void

    var body: some View {
        content
            .animation(.smooth(duration: 0.35), value: places.found == nil)
    }

    @ViewBuilder
    private var content: some View {
        if let found = places.found {
            if !found.isEmpty {
                card {
                    MimoPlacesMap(places: found, isPlan: places.isPlan, onShowOnMap: onShowOnMap)
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, place in
                        if index > 0 { Divider().padding(.leading, MimoPlaceRow.textInset) }
                        MimoPlaceRow(
                            shown: place.shown,
                            place: place.place,
                            number: places.isPlan ? place.shown.order ?? index + 1 : nil,
                            distanceMeters: place.distanceMeters,
                            language: places.language,
                            action: { onSelect(place) }
                        )
                    }
                }
            }
        } else {
            // Looking the names up on the map: the card's shape, so nothing jumps
            // when the places come in.
            card {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: MimoPlacesMap.height)
                ForEach(Array(places.lookupOrder.enumerated()), id: \.offset) { index, shown in
                    if index > 0 { Divider().padding(.leading, MimoPlaceRow.textInset) }
                    MimoPlaceRow(
                        shown: shown,
                        place: Self.placeholderPlace,
                        number: places.isPlan ? shown.order ?? index + 1 : nil,
                        distanceMeters: nil,
                        language: places.language,
                        action: {}
                    )
                }
            }
            .redacted(reason: .placeholder)
            .disabled(true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Finding places on the map")
        }
    }

    /// Shape-only, for the rows while the names are looked up (the
    /// thumbnail loads nothing while redacted).
    private static let placeholderPlace = Place(
        id: nil,
        name: "A place",
        localName: nil,
        category: .other,
        address: nil,
        coordinate: Coordinate(lat: 0, lon: 0)
    )

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Theme.cardFill, in: Theme.cardShape)
        .clipShape(Theme.cardShape)
    }
}

/// The card's map: the places as pins, framed to fit, not interactive. Tapping
/// it (or Show on map) opens the Map's From Mimo layer.
private struct MimoPlacesMap: View {
    static let height: CGFloat = 150

    let places: [MimoFoundPlace]
    let isPlan: Bool
    var onShowOnMap: () -> Void

    /// The pins with some margin, and at least about 700 m across, so places a
    /// few metres apart still show their streets.
    private var region: MKCoordinateRegion {
        let coordinates = places.map(\.place.coordinate.mapKitCoordinate)
        let lats = coordinates.map(\.latitude), lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return MKCoordinateRegion() }
        let minimumSpan = 0.0065
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.8, minimumSpan),
                longitudeDelta: max((maxLon - minLon) * 1.8, minimumSpan)
            )
        )
    }

    var body: some View {
        Button(action: onShowOnMap) {
            Map(initialPosition: .region(region), interactionModes: []) {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    let coordinate = place.place.coordinate.mapKitCoordinate
                    if isPlan {
                        Marker(place.shown.name, monogram: Text(String(place.shown.order ?? index + 1)), coordinate: coordinate)
                            .tint(.teal)
                    } else {
                        Marker(place.shown.name, systemImage: place.place.category.sfSymbol, coordinate: coordinate)
                            .tint(.teal)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
            .frame(height: Self.height)
            .overlay(alignment: .bottomTrailing) {
                Label("Show on map", systemImage: "map")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, Theme.grid * 1.5)
                    .padding(.vertical, Theme.grid * 0.75)
                    .glassEffect(.regular, in: .capsule)
                    .padding(Theme.grid)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show on map")
        .accessibilityHint(isPlan ? "Shows the stops as numbered pins on the map" : "Shows these places on the map")
    }
}

/// One place: its thumbnail (Look Around, or a map tile; in a plan, with the
/// stop number on its corner), the name with its local-script name, Mimo's
/// why (after the time, in a plan), and how far it is.
private struct MimoPlaceRow: View {
    static let textInset: CGFloat = Theme.grid * 2 + PlaceThumbnail.defaultSize + Theme.grid * 1.5

    let shown: ShownPlace
    let place: Place
    /// The stop number, in a plan.
    let number: Int?
    let distanceMeters: Double?
    let language: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Theme.grid * 1.5) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.grid * 0.75) {
                        Text(shown.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if let localName, let language {
                            LocalText(localName, languageTag: language)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(secondLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                if let distanceMeters {
                    Text(MapDistanceText.text(distanceMeters))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, Theme.grid * 2)
            .padding(.vertical, Theme.grid * 1.5)
            .contentShape(.rect)
        }
        .buttonStyle(MimoRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(number == nil ? "Opens the map on this place" : "Opens the map on this stop")
    }

    /// The local-script name, unless it only repeats the English one with a
    /// few local words ("BECK'S COFFEE SHOP 新宿南口").
    private var localName: String? {
        guard let localName = shown.localName, localName != shown.name,
              !localName.contains(where: { $0.isASCII && $0.isLetter }) else { return nil }
        return localName
    }

    private var secondLine: String {
        guard let when = shown.when else { return shown.why }
        return "\(MimoPlanClock.clock(when)) · \(shown.why)"
    }

    private var thumbnail: some View {
        PlaceThumbnail(place: place)
            .overlay(alignment: .topLeading) {
                if let number {
                    Text(number, format: .number)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(.primary))
                        // Set apart from the picture by a ring of the card's colour.
                        .padding(2)
                        .background(Capsule().fill(Theme.cardFill))
                        .fixedSize()
                        .offset(x: -7, y: -7)
                        .accessibilityLabel("Stop \(number)")
                }
            }
    }
}

/// A plain row that dims while pressed, like a list row's highlight.
private struct MimoRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// A plan stop's suggested time.
private enum MimoPlanClock {
    /// `HH:mm` (local to the place) in the reader's clock style, e.g. "3:00 PM".
    /// The time is never converted between zones.
    static func clock(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return hhmm }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: parts[0], minute: parts[1])) else {
            return hhmm
        }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}
