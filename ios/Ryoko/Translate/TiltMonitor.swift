import CoreMotion
import Foundation
import Observation

/// Gravity from CoreMotion, through `TiltRule`, to Translate's layout (design
/// §4.8). Show mode uses it too: face-to-face turns the card toward the other person. Device motion needs no permission. It only works on a device: in the
/// simulator `isAvailable` is false and the layout stays upright (use the
/// toolbar toggle).
@MainActor
@Observable
final class TiltMonitor {
    /// The layout the phone's angle asks for.
    private(set) var layout: TranslateLayout = .upright

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Translate tilt"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    @ObservationIgnored private var rule = TiltRule()
    @ObservationIgnored private var running = false

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        manager.deviceMotionUpdateInterval = 1.0 / 15
        manager.startDeviceMotionUpdates(to: queue, withHandler: Self.handler { [weak self] x, y, z, time in
            self?.ingest(x: x, y: y, z: z, at: time)
        })
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
    }

    private func ingest(x: Double, y: Double, z: Double, at time: TimeInterval) {
        guard running else { return }
        let next = rule.update(x: x, y: y, z: z, at: time)
        if next != layout { layout = next }
    }

    /// The CoreMotion callback runs on `queue`, off the main actor, so it's
    /// built in a nonisolated context and only hops to the main actor with plain values.
    private nonisolated static func handler(
        _ deliver: @escaping @MainActor @Sendable (Double, Double, Double, TimeInterval) -> Void
    ) -> CMDeviceMotionHandler {
        { motion, _ in
            guard let motion else { return }
            let g = motion.gravity
            let time = motion.timestamp
            Task { @MainActor in deliver(g.x, g.y, g.z, time) }
        }
    }
}
