import Foundation

/// Where the server is and how to authenticate (design §7, AGENTS.md "Networking").
///
/// - The base URL and app token come from the Info.plist keys `RyokoAgentBaseURL`
///   and `RyokoAppToken`, which are filled from the gitignored Secrets.xcconfig.
/// - Me's developer section can override the base URL at runtime; the override is
///   kept in UserDefaults and read on every request, so it applies immediately.
/// - The install id is a random UUID kept in UserDefaults. It's anonymous.
nonisolated struct RyokoAPIConfiguration: Sendable, Equatable {
    var baseURL: URL
    var appToken: String
    var installId: String
    var clientVersion: String

    static let baseURLKey = "RyokoAgentBaseURL"
    static let appTokenKey = "RyokoAppToken"
    static let baseURLOverrideDefaultsKey = "RyokoAgentBaseURLOverride"
    static let installIdDefaultsKey = "RyokoInstallId"

    /// Reads the current configuration from the main bundle and standard defaults.
    static func current(bundle: Bundle = .main, defaults: UserDefaults = .standard) throws -> RyokoAPIConfiguration {
        let infoBaseURL = (bundle.object(forInfoDictionaryKey: baseURLKey) as? String) ?? ""
        let override = defaults.string(forKey: baseURLOverrideDefaultsKey) ?? ""
        let raw = override.isEmpty ? infoBaseURL : override
        guard let baseURL = validBaseURL(raw) else {
            throw RyokoAPIError.notConfigured(baseURLKey)
        }
        let token = ((bundle.object(forInfoDictionaryKey: appTokenKey) as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !token.hasPrefix("$(") else {
            throw RyokoAPIError.notConfigured(appTokenKey)
        }
        return RyokoAPIConfiguration(
            baseURL: baseURL,
            appToken: token,
            installId: installId(defaults: defaults),
            clientVersion: clientVersion(bundle: bundle)
        )
    }

    // MARK: Base URL override (Me → developer section)

    /// The runtime base-URL override, or nil when the Info.plist value is used.
    static func baseURLOverride(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: baseURLOverrideDefaultsKey) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Sets or clears (nil or empty) the runtime base-URL override.
    /// Returns false, and changes nothing, if the URL isn't a usable http(s) URL.
    @discardableResult
    static func setBaseURLOverride(_ value: String?, defaults: UserDefaults = .standard) -> Bool {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: baseURLOverrideDefaultsKey)
            return true
        }
        guard validBaseURL(trimmed) != nil else { return false }
        defaults.set(trimmed, forKey: baseURLOverrideDefaultsKey)
        return true
    }

    /// An http or https URL with a host, or nil.
    static func validBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: Install id and client version

    /// The anonymous install id, created on first use.
    static func installId(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: installIdDefaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: installIdDefaultsKey)
        return fresh
    }

    /// `ios/<marketing version>+<build>`, e.g. `ios/1.0+1`.
    static func clientVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "ios/\(version)+\(build)"
    }
}
