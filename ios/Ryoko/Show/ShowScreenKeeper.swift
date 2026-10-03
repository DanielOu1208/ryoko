import SwiftUI
import UIKit
import os

/// Keeps the screen bright and awake while Show mode is up (design §4.4):
/// brightness goes to max on the window scene's own screen (`UIScreen.main` is
/// deprecated in iOS 26) and the idle timer is off. Both go back to what they
/// were when Show mode closes, and while the app is in the background.
///
/// Put it in the background of the Show mode view; `isActive` follows the scene phase.
struct ShowScreenKeeper: UIViewRepresentable {
    var isActive: Bool

    func makeUIView(context: Context) -> KeeperView {
        KeeperView()
    }

    func updateUIView(_ view: KeeperView, context: Context) {
        view.isActive = isActive
    }

    static func dismantleUIView(_ view: KeeperView, coordinator: ()) {
        view.restore()
    }

    final class KeeperView: UIView {
        var isActive = false {
            didSet { apply() }
        }

        private weak var engagedScreen: UIScreen?
        private var savedBrightness: CGFloat?
        private var savedIdleTimerDisabled: Bool?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            if isActive, let screen = window?.windowScene?.screen {
                engage(screen)
            } else {
                restore()
            }
        }

        private func engage(_ screen: UIScreen) {
            guard savedBrightness == nil else { return }
            savedBrightness = screen.brightness
            savedIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            engagedScreen = screen
            screen.brightness = 1
            UIApplication.shared.isIdleTimerDisabled = true
            RyokoLog.show.info("Show mode: brightness \(Double(self.savedBrightness ?? 0), format: .fixed(precision: 2)) → 1.00, idle timer off")
        }

        func restore() {
            guard let brightness = savedBrightness else { return }
            engagedScreen?.brightness = brightness
            UIApplication.shared.isIdleTimerDisabled = savedIdleTimerDisabled ?? false
            RyokoLog.show.info("Show mode: brightness restored to \(Double(brightness), format: .fixed(precision: 2)), idle timer \(self.savedIdleTimerDisabled == true ? "off" : "on", privacy: .public)")
            savedBrightness = nil
            savedIdleTimerDisabled = nil
            engagedScreen = nil
        }
    }
}
