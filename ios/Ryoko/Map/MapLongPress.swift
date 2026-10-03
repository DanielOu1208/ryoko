import SwiftUI
import UIKit

/// Long-press anywhere on the map to drop a pin (design §4.7). A UIKit long
/// press, because SwiftUI's `LongPressGesture` doesn't report where it
/// happened. `MapReader`'s proxy turns the point into a MapKit coordinate.
struct MapLongPress: UIGestureRecognizerRepresentable {
    /// Called once per press, with the point in the map's local space.
    var onPress: (CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.5
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        guard recognizer.state == .began else { return }
        onPress(context.converter.localLocation)
    }
}
