import CryptoKit
import Foundation

/// Spoken audio saved in Caches, keyed by a hash of (text, language, voice,
/// model), so a phrase heard once plays instantly and costs no credits again
/// (design §8.1). The system may clear it; files older than 30 days are removed.
nonisolated enum SpeechAudioCache {
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private static let directory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "SpeechAudio", directoryHint: .isDirectory)

    static func key(text: String, language: String, voiceID: String, model: String) -> String {
        let digest = SHA256.hash(data: Data([text, language, voiceID, model].joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @concurrent static func data(for key: String) async -> Data? {
        guard let url = url(for: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    @concurrent static func save(_ data: Data, for key: String) async {
        guard let directory, let url = url(for: key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    @concurrent static func prune() async {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return }
        let cutoff = Date.now.addingTimeInterval(-maxAge)
        for file in files {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func url(for key: String) -> URL? {
        directory?.appending(path: "\(key).mp3", directoryHint: .notDirectory)
    }
}
