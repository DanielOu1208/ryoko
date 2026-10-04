import SwiftUI
import UIKit

/// The swipe that opens and closes the history sidebar: a sideways pan
/// anywhere on the chat.
///
/// A UIKit pan rather than a SwiftUI `DragGesture`: inside the chat's scroll
/// view, a SwiftUI drag could be left without an end when the scroll took
/// over, and the chat stayed stuck partway across. A pan always ends,
/// cancels or fails.
/// - It only starts when the finger moves mostly sideways, so scrolling is
///   untouched, and it recognizes alongside everything else (scrolling,
///   buttons, text selection). `MimoView.unlessSwiping` keeps a swipe that
///   crosses a place or phrase from also tapping it.
/// - Never inside the text field or a sideways scroller (the source pills),
///   which keep their own swipes.
struct MimoSidebarSwipe: UIGestureRecognizerRepresentable {
    /// Shared with `MimoView`, for its stuck-swipe checks.
    let tracker: Tracker
    /// The swipe's sideways distance so far, in points.
    var onChange: (CGFloat) -> Void
    /// Where the swipe would come to rest (its distance plus a flick's
    /// momentum), or nil when it was cancelled.
    var onEnd: (CGFloat?) -> Void

    /// Whether a swipe is under way. A plain reference, not observed: only
    /// `MimoView`'s checks read it.
    @MainActor
    final class Tracker {
        var isActive = false
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // In window space: the chat moves with the swipe, so its own space would too.
        let distance = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began, .changed:
            tracker.isActive = true
            onChange(distance)
        case .ended:
            tracker.isActive = false
            onEnd(distance + recognizer.velocity(in: nil).x * 0.2)
        case .cancelled, .failed:
            tracker.isActive = false
            onEnd(nil)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Mostly sideways.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: nil)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextView || current is UITextField { return false }
                if let scroller = current as? UIScrollView, scroller.contentSize.width > scroller.bounds.width + 1 {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
