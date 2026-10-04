import MapKit
import SwiftUI

/// A place card's row of round buttons with labels under them, Apple Maps
/// style (design §4.7): Directions, Taxi, Allergy (only where it helps) and
/// Ask Mimo. Two by two at accessibility text sizes.
struct MapPlaceActions: View {
    struct Action: Identifiable {
        var id: String { title }
        let title: String
        let systemImage: String
        var isBusy = false
        var isEnabled = true
        var hint: String?
        let perform: () -> Void
    }

    let actions: [Action]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : max(actions.count, 1)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Theme.grid, alignment: .top), count: columns),
            spacing: Theme.grid * 2
        ) {
            ForEach(actions) { action in
                MapRoundActionButton(action: action)
            }
        }
    }
}

/// One round button with its label underneath.
private struct MapRoundActionButton: View {
    let action: MapPlaceActions.Action

    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 52

    var body: some View {
        Button(action: action.perform) {
            VStack(spacing: Theme.grid * 0.75) {
                ZStack {
                    Circle()
                        .fill(Theme.cardFill)
                    if action.isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: action.systemImage)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(action.isEnabled ? .primary : .tertiary)
                    }
                }
                .frame(width: diameter, height: diameter)
                Text(action.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(action.isEnabled ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(MapRowButtonStyle())
        .disabled(!action.isEnabled || action.isBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.hint ?? "")
        .accessibilityValue(action.isBusy ? "Loading" : "")
        .accessibilityAddTraits(.isButton)
    }
}

/// Apple Maps with directions to a place (the Directions button).
enum MapDirections {
    /// Opens Apple Maps with directions to `place` in the user's usual mode:
    /// its MapKit map item when it has an identifier, otherwise one built
    /// from its coordinate and name.
    static func open(_ place: MapPlace) async {
        var item: MKMapItem?
        if let id = place.place.id, let identifier = MKMapItem.Identifier(rawValue: id) {
            item = try? await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
        }
        let destination = item ?? {
            let built = MKMapItem(location: place.place.coordinate.mapKitLocation, address: nil)
            built.name = place.title
            return built
        }()
        _ = destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault,
        ])
    }
}
