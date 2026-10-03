import Foundation

/// Translate's two layouts (design §4.8).
nonisolated enum TranslateLayout: String, Hashable, Sendable, CaseIterable {
    /// Phone held normally: what was said on top, the translation below.
    case upright
    /// Phone flat between two people: the top half turned 180° toward them.
    case faceToFace
}

/// Picks the layout from gravity, with hysteresis and a debounce (design §4.8).
/// Pure, so the harness can run it.
///
/// - **Elevation** is how far the phone's top edge is raised above horizontal:
///   90° held upright, 0° flat, negative once the top tips away past flat.
/// - It switches to face-to-face below about 30° (near flat, or tipped away),
///   and back to upright above about 50°. In between nothing changes.
/// - A new layout must hold for `debounce` seconds before it's used.
/// - Readings that say nothing about the table case are ignored: face down, or
///   turned sideways (landscape), where elevation is near 0 without being flat.
nonisolated struct TiltRule: Hashable, Sendable {
    var enterBelowDegrees = 30.0
    var exitAboveDegrees = 50.0
    var debounce: TimeInterval = 0.4

    private(set) var layout: TranslateLayout = .upright
    private var candidate: TranslateLayout?
    private var candidateSince: TimeInterval = 0

    init(layout: TranslateLayout = .upright) {
        self.layout = layout
    }

    /// Feeds one gravity reading (device coordinates, in g) taken at `time`
    /// (seconds, any monotonic clock). Returns the layout to show.
    @discardableResult
    mutating func update(x: Double, y: Double, z: Double, at time: TimeInterval) -> TranslateLayout {
        guard let wanted = target(x: x, y: y, z: z) else {
            candidate = nil
            return layout
        }
        guard wanted != layout else {
            candidate = nil
            return layout
        }
        if candidate != wanted {
            candidate = wanted
            candidateSince = time
        } else if time - candidateSince >= debounce {
            layout = wanted
            candidate = nil
        }
        return layout
    }

    /// The layout this reading asks for, or nil to keep the current one.
    private func target(x: Double, y: Double, z: Double) -> TranslateLayout? {
        let magnitude = (x * x + y * y + z * z).squareRoot()
        guard magnitude > 0.5 else { return nil } // free fall or bad data
        let nx = x / magnitude, nz = z / magnitude
        if nz > 0.35 { return nil } // face down: the screen can't be read
        if abs(nx) > 0.7 { return nil } // turned sideways
        let elevation = Self.elevation(x: x, y: y, z: z)
        if elevation < enterBelowDegrees { return .faceToFace }
        if elevation > exitAboveDegrees { return .upright }
        return nil
    }

    /// Degrees the top edge is raised above horizontal.
    static func elevation(x: Double, y: Double, z: Double) -> Double {
        let magnitude = max((x * x + y * y + z * z).squareRoot(), .ulpOfOne)
        let sine = min(max(-y / magnitude, -1), 1)
        return asin(sine) * 180 / .pi
    }
}
