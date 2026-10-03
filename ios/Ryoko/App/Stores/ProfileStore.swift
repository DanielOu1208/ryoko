import Foundation
import Observation
import os

/// The traveller's profile (design §7.2, W2.4). The device owns it and sends it
/// with every request.
///
/// - Starts from the bundled seed profile (`contracts/examples/profile.seed.json`,
///   bundled through `Core/Fixtures/`) until onboarding exists (tier 2).
/// - Edits are saved as JSON in Application Support and survive relaunches.
/// - `version` is always the SHA-256 of the canonical JSON (`CanonicalJSON`),
///   recomputed on every change, so it's a stable cache key for the server.
@MainActor
@Observable
final class ProfileStore {
    /// The current profile, with an up-to-date `version`.
    private(set) var profile: Profile

    /// The seed profile, with its version recomputed.
    let seed: Profile

    /// True while the profile is the seed (nothing edited, or reset).
    var isSeed: Bool { profile == seed }

    /// The last save or load problem, for the developer section. nil when fine.
    private(set) var lastError: String?

    @ObservationIgnored private let fileURL: URL?

    /// - Parameters:
    ///   - fileURL: where edits are saved; nil keeps them in memory (previews).
    ///   - seed: the starting profile; defaults to the bundled seed.
    init(fileURL: URL? = ProfileStore.defaultFileURL, seed: Profile? = nil) {
        let seed = Self.versioned(seed ?? Self.bundledSeed())
        self.seed = seed
        self.fileURL = fileURL
        profile = seed
        if let fileURL, let saved = Self.load(from: fileURL) {
            profile = Self.versioned(saved)
        }
    }

    /// An in-memory store with the bundled seed, for previews.
    static func preview() -> ProfileStore {
        ProfileStore(fileURL: nil)
    }

    // MARK: Editing

    /// Changes the profile, recomputes its version and saves it.
    func update(_ change: (inout Profile) -> Void) {
        var edited = profile
        change(&edited)
        edited = Self.versioned(edited)
        guard edited != profile else { return }
        profile = edited
        save()
    }

    /// Replaces the profile (onboarding, tests), recomputing its version.
    func replace(with newProfile: Profile) {
        update { $0 = newProfile }
    }

    /// Me → developer → "Reset to seed profile". Deletes the saved file.
    func resetToSeed() {
        profile = seed
        lastError = nil
        guard let fileURL else { return }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: fileURL)
            }
            RyokoLog.profile.info("Profile reset to the seed")
        } catch {
            lastError = "Couldn't delete the saved profile."
            RyokoLog.profile.error("Couldn't delete the saved profile: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Version

    /// The content-hash version of `profile` (its own `version` is ignored).
    static func version(of profile: Profile) -> String {
        do {
            return try CanonicalJSON.profileVersion(profile)
        } catch {
            // A Profile always encodes; this only guards against a future bug.
            RyokoLog.profile.fault("Couldn't hash the profile: \(String(describing: error), privacy: .public)")
            return String(repeating: "0", count: 64)
        }
    }

    /// `profile` with `version` set to its content hash.
    static func versioned(_ profile: Profile) -> Profile {
        var copy = profile
        copy.version = version(of: profile)
        return copy
    }

    // MARK: Storage

    /// `Application Support/Ryoko/profile.json`.
    static var defaultFileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appending(path: "Ryoko", directoryHint: .isDirectory).appending(path: "profile.json")
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(profile).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastError = nil
        } catch {
            lastError = "Couldn't save the profile."
            RyokoLog.profile.error("Couldn't save the profile: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> Profile? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            return try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
        } catch {
            // A file from an older build that no longer decodes: fall back to the seed.
            RyokoLog.profile.error("Saved profile didn't load, using the seed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The bundled seed, or a minimal profile in the device language if the
    /// fixture is missing (it never should be).
    private static func bundledSeed() -> Profile {
        if let seed = Fixtures.profile { return seed }
        RyokoLog.profile.fault("profile.seed.json is missing from the bundle")
        let deviceLanguage = Locale.preferredLanguages.first
            .map { Locale.Language(identifier: $0).languageCode?.identifier ?? "en" } ?? "en"
        return Profile(
            version: "",
            nationality: nil,
            homeLanguage: deviceLanguage,
            spokenLanguages: nil,
            diet: nil,
            dietNotes: nil,
            allergies: nil,
            favourites: nil,
            taste: nil,
            personality: nil,
            homeBase: nil
        )
    }
}

extension RyokoLog {
    nonisolated static let profile = Logger(subsystem: subsystem, category: "profile")
    nonisolated static let situation = Logger(subsystem: subsystem, category: "situation")
}
