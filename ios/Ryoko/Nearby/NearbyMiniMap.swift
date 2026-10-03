import MapKit
import SwiftUI

/// Nearby's mini map tile (design §4.3): a live, non-interactive map centred on
/// the place. Tapping it opens the Map tab centred here
/// (`router.openMap(centeredOn:)`).
struct NearbyMiniMap: View {
    let coordinate: Coordinate
    let title: String
    let systemImage: String

    @Environment(AppRouter.self) private var router
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 150

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lon)
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 600, longitudinalMeters: 600)
        Button {
            router.openMap(centeredOn: coordinate)
        } label: {
            Map(position: .constant(.region(region)), interactionModes: []) {
                Marker(title, systemImage: systemImage, coordinate: center)
            }
            .mapControlVisibility(.hidden)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .frame(height: min(height, 280))
            .clipShape(Theme.cardShape)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .padding(Theme.grid * 1.25)
                    .glassEffect(.regular, in: .circle)
                    .padding(Theme.grid * 1.5)
            }
            .contentShape(Theme.cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map around \(title)")
        .accessibilityHint("Opens the Map tab centred here")
    }
}
