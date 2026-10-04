import MapKit
import SwiftUI

/// The place a message asks about (design §4.9), above your message like a
/// location shared in Messages: a small map with its pin, then its name and
/// what it is. Tap it to open the place's card on the Map.
struct MimoPlacePreview: View {
    static let width: CGFloat = 240
    static let mapHeight: CGFloat = 112

    let place: Place
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                Map(initialPosition: .region(region), interactionModes: []) {
                    Marker(place.name, systemImage: place.category.sfSymbol, coordinate: place.coordinate.mapKitCoordinate)
                        .tint(.teal)
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .allowsHitTesting(false)
                .frame(height: Self.mapHeight)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Theme.grid * 1.5)
                .padding(.vertical, Theme.grid * 1.25)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: Self.width)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(Self.shape)
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place.name), \(place.category.displayName)")
        .accessibilityHint("Opens the map on this place")
        .accessibilityAddTraits(.isButton)
    }

    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    /// A few streets around the pin.
    private var region: MKCoordinateRegion {
        MKCoordinateRegion(center: place.coordinate.mapKitCoordinate, latitudinalMeters: 500, longitudinalMeters: 500)
    }

    /// "Bookstore · 8888 University Dr W": what it is, and where when known.
    private var subtitle: String {
        [place.category.displayName, place.address]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
