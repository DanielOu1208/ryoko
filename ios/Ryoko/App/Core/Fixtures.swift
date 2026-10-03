import Foundation
import os

/// The contract examples bundled with the app. The files in `Core/Fixtures/` are
/// copies of `contracts/examples/`; refresh them with `ios/scripts/sync-fixtures.sh`.
///
/// They're copied to the root of the app bundle under these names, so no other
/// folder in the app target may add a file with the same name.
nonisolated enum FixtureFile: String, CaseIterable, Sendable {
    case profileSeed = "profile.seed.json"
    case situationShanghai = "situation.shanghai-cafe.json"
    case situationTokyo = "situation.tokyo-ramen.json"
    case placeCardRequest = "place-card.request.json"
    case placeCardResponse = "place-card.response.json"
    case placeCardTokyoRequest = "place-card.tokyo.request.json"
    case placeCardTokyoResponse = "place-card.tokyo.response.json"
    case discoverRequest = "discover.request.json"
    case discoverResponse = "discover.response.json"
    case allergyCardRequest = "allergy-card.request.json"
    case allergyCardResponse = "allergy-card.response.json"
    case mimoMessageRequest = "mimo-message.request.json"
    case mimoStream = "mimo.sse.txt"
    case errorInvalidRequest = "error.invalid-request.response.json"
    case errorSessionBusy = "error.session-busy.response.json"

    var fileName: String { rawValue }
}

/// Where fixtures are read from: the app bundle, or a directory (for the macOS
/// contract check in `ios/scripts/`, which reads `contracts/examples/` directly).
nonisolated struct FixtureSource: Sendable {
    private let directory: URL?

    static let mainBundle = FixtureSource(directory: nil)

    static func directory(_ url: URL) -> FixtureSource {
        FixtureSource(directory: url)
    }

    func url(for file: FixtureFile) throws -> URL {
        if let directory {
            return directory.appending(path: file.fileName)
        }
        let name = (file.fileName as NSString).deletingPathExtension
        let ext = (file.fileName as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw RyokoAPIError.invalidResponse("Fixture \(file.fileName) isn't in the app bundle")
        }
        return url
    }

    func data(_ file: FixtureFile) throws -> Data {
        try Data(contentsOf: url(for: file))
    }

    func text(_ file: FixtureFile) throws -> String {
        String(decoding: try data(file), as: UTF8.self)
    }

    func decode<T: Decodable>(_ type: T.Type, from file: FixtureFile) throws -> T {
        try JSONDecoder().decode(type, from: data(file))
    }
}

/// Decoded fixtures from the app bundle, for previews and fixture implementations.
/// Each is read once; it's nil (and logged) if the file is missing or off-contract.
nonisolated enum Fixtures {
    static let profile: Profile? = load(Profile.self, .profileSeed)
    static let shanghai: Situation? = load(Situation.self, .situationShanghai)
    static let tokyo: Situation? = load(Situation.self, .situationTokyo)
    static let shanghaiCard: PlaceCardResponse? = load(PlaceCardResponse.self, .placeCardResponse)
    static let tokyoCard: PlaceCardResponse? = load(PlaceCardResponse.self, .placeCardTokyoResponse)
    static let discover: DiscoverResponse? = load(DiscoverResponse.self, .discoverResponse)
    static let allergyCard: AllergyCardResponse? = load(AllergyCardResponse.self, .allergyCardResponse)
    static let mimoRequest: MimoMessageRequest? = load(MimoMessageRequest.self, .mimoMessageRequest)

    static let mimoEvents: [MimoEvent] = {
        do {
            return try SSELineReader.events(inTranscript: FixtureSource.mainBundle.text(.mimoStream))
        } catch {
            RyokoLog.fixtures.error("Couldn't read mimo.sse.txt: \(String(describing: error), privacy: .public)")
            return []
        }
    }()

    private static func load<T: Decodable>(_ type: T.Type, _ file: FixtureFile) -> T? {
        do {
            return try FixtureSource.mainBundle.decode(type, from: file)
        } catch {
            RyokoLog.fixtures.error("Couldn't load \(file.fileName, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
