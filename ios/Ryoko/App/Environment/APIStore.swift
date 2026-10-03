import Foundation
import Observation
import SwiftUI

/// Which `RyokoAPI` the app talks to, and the server base-URL override (Me →
/// developer section). The root view puts `api` into the environment as
/// `\.ryokoAPI`, so features read it with `@Environment(\.ryokoAPI)` and pick up
/// a switch between fixtures and the live server without a relaunch.
@MainActor
@Observable
final class APIStore {
    enum Mode: String, CaseIterable, Identifiable {
        /// The bundled contract examples (`FixtureRyokoAPI`). No server needed.
        case fixture
        /// The agent server (`LiveRyokoAPI`), at the Info.plist URL or the override.
        case live

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fixture: "Fixtures"
            case .live: "Live server"
            }
        }
    }

    /// The API in use. Persisted in UserDefaults.
    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: AppSettings.apiModeKey)
            api = Self.makeAPI(mode)
        }
    }

    /// The API for `mode`. Read it through `@Environment(\.ryokoAPI)` in views.
    private(set) var api: any RyokoAPI {
        didSet { apiGeneration += 1 }
    }

    /// Goes up by one whenever `api` is replaced. `any RyokoAPI` isn't
    /// `Equatable`, so put this in `.task(id:)` keys to reload on a switch.
    private(set) var apiGeneration = 0

    /// The runtime base-URL override, or nil when the Info.plist value is used.
    private(set) var baseURLOverride: String?

    /// Whether this build has a base URL and app token (Secrets.xcconfig).
    let isLiveConfigured: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configured = (try? RyokoAPIConfiguration.current(defaults: defaults)) != nil
        isLiveConfigured = configured
        // Live when the build is configured for a server; fixtures otherwise.
        let stored = defaults.string(forKey: AppSettings.apiModeKey).flatMap(Mode.init(rawValue:))
        let mode = stored ?? (configured ? .live : .fixture)
        self.mode = mode
        api = Self.makeAPI(mode)
        baseURLOverride = RyokoAPIConfiguration.baseURLOverride(defaults: defaults)
    }

    /// Sets or clears (nil or blank) the base-URL override. Returns false, and
    /// changes nothing, if the text isn't an http(s) URL with a host.
    @discardableResult
    func setBaseURLOverride(_ text: String?) -> Bool {
        guard RyokoAPIConfiguration.setBaseURLOverride(text, defaults: defaults) else { return false }
        baseURLOverride = RyokoAPIConfiguration.baseURLOverride(defaults: defaults)
        // `LiveRyokoAPI` reads the configuration on every request, but swap the
        // value anyway so views keyed on the API reload.
        api = Self.makeAPI(mode)
        return true
    }

    private static func makeAPI(_ mode: Mode) -> any RyokoAPI {
        switch mode {
        case .fixture: FixtureRyokoAPI()
        case .live: LiveRyokoAPI()
        }
    }
}

extension EnvironmentValues {
    /// The API features call. The root view sets it from `APIStore`; previews
    /// get the fixture API by default.
    @Entry var ryokoAPI: any RyokoAPI = FixtureRyokoAPI()
}
