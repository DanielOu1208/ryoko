import Foundation
import Observation
import os

/// A model and how much it thinks, as a message sends them (design §4.9).
nonisolated struct MimoModelChoice: Codable, Hashable, Sendable {
    /// An id from `GET /v1/mimo-models`.
    var model: String
    var effort: MimoEffort
}

/// The models Mimo's picker offers (`GET /v1/mimo-models`) and the one you
/// picked, kept on the device.
///
/// Until you pick, messages name no model and the server uses its default.
/// A pick the server no longer offers falls back to the default; a level the
/// model doesn't take moves to the nearest one it does. Without the list (an
/// older server, fixtures off, offline) the picker hides and messages go as before.
@MainActor
@Observable
final class MimoModelStore {
    /// The app's one store, shared by every Mimo chat.
    static let shared = MimoModelStore()

    /// The server's list, once loaded.
    private(set) var catalog: MimoModelsResponse?
    /// Your pick, or nil for the server's default.
    private(set) var picked: MimoModelChoice? {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let pickedKey = "RyokoMimoModelChoice"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        picked = defaults.data(forKey: Self.pickedKey).flatMap { try? JSONDecoder().decode(MimoModelChoice.self, from: $0) }
    }

    /// The model and level the next message runs on, as the picker shows them.
    var current: (model: MimoModel, effort: MimoEffort)? {
        guard let catalog else { return nil }
        if let picked, let model = catalog.models.first(where: { $0.id == picked.model }) {
            return (model, picked.effort.nearest(in: model.efforts))
        }
        guard let model = catalog.models.first(where: { $0.id == catalog.defaultModel }) ?? catalog.models.first else { return nil }
        return (model, model.defaultEffort)
    }

    /// Whether the picker shows the server's default model at its own level.
    var isDefault: Bool {
        guard let catalog, let current else { return true }
        return current.model.id == catalog.defaultModel && current.effort == current.model.defaultEffort
    }

    /// What a message sends: nil leaves the model to the server.
    var choice: MimoModelChoice? {
        guard let picked else { return nil }
        // Before the list loads, trust the pick; the server checks it.
        guard catalog != nil, let current else { return picked }
        return isDefault ? nil : MimoModelChoice(model: current.model.id, effort: current.effort)
    }

    /// Fetches the list. A failure keeps the last one (or none, hiding the picker).
    func load(api: any RyokoAPI) async {
        do {
            let catalog = try await api.mimoModels()
            guard !Task.isCancelled else { return }
            self.catalog = catalog
        } catch {
            if !(error is CancellationError) {
                RyokoLog.mimo.info("No model list: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Picks a model, keeping the level as near as the model allows.
    func pick(model: MimoModel) {
        let effort = current?.effort.nearest(in: model.efforts) ?? model.defaultEffort
        picked = MimoModelChoice(model: model.id, effort: effort)
    }

    /// Picks a level for the model the picker shows.
    func pick(effort: MimoEffort) {
        guard let model = current?.model else { return }
        picked = MimoModelChoice(model: model.id, effort: effort)
    }

    /// Back to the server's default model and level.
    func reset() {
        picked = nil
    }

    private func save() {
        if let picked, let data = try? JSONEncoder().encode(picked) {
            defaults.set(data, forKey: Self.pickedKey)
        } else {
            defaults.removeObject(forKey: Self.pickedKey)
        }
    }
}

nonisolated extension MimoEffort {
    /// The levels, lowest first.
    static let ordered: [MimoEffort] = [.off, .minimal, .low, .medium, .high]

    /// What the picker calls it. Thinking off answers at once, so it's "Instant".
    var title: String {
        switch self {
        case .off: "Instant"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        default: rawValue.capitalized
        }
    }

    /// The level in `levels` nearest to this one, the higher on a tie (as the server does).
    func nearest(in levels: [MimoEffort]) -> MimoEffort {
        guard !levels.contains(self), let best = levels.first else { return self }
        let rank = { (effort: MimoEffort) in Self.ordered.firstIndex(of: effort) ?? 2 }
        return levels.dropFirst().reduce(best) { best, candidate in
            let distance = abs(rank(candidate) - rank(self)), bestDistance = abs(rank(best) - rank(self))
            return distance < bestDistance || (distance == bestDistance && rank(candidate) > rank(best)) ? candidate : best
        }
    }
}
