import Foundation
import os

/// Keeps Mimo transcripts on the device (design §4.9 "The transcript is kept on
/// the device"): one JSON file per session in `Application Support/Ryoko/Mimo/`,
/// plus the current session id in UserDefaults. Nothing goes to the server
/// except the messages themselves.
nonisolated struct MimoTranscriptStore: Sendable {
    /// Where the files go; nil keeps everything in memory (previews).
    let directory: URL?
    /// Where the current session id is kept; nil for previews.
    private let defaultsKey: String?

    static let currentSessionKey = "RyokoMimoSessionId"

    init(directory: URL?, defaultsKey: String? = Self.currentSessionKey) {
        self.directory = directory
        self.defaultsKey = defaultsKey
    }

    /// The app's store, in Application Support.
    static let standard = MimoTranscriptStore(directory: defaultDirectory)

    /// An in-memory store for previews.
    static let inMemory = MimoTranscriptStore(directory: nil, defaultsKey: nil)

    /// `Application Support/Ryoko/Mimo/`.
    static var defaultDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base
            .appending(path: "Ryoko", directoryHint: .isDirectory)
            .appending(path: "Mimo", directoryHint: .isDirectory)
    }

    // MARK: Current session

    /// The session the tab shows: the saved current one, or a new empty one.
    /// A reply that was streaming when the app quit is marked stopped, and
    /// tool lines are cleared.
    func loadCurrent() -> MimoTranscript {
        guard let defaultsKey,
              let sessionId = UserDefaults.standard.string(forKey: defaultsKey),
              let transcript = loadSettled(sessionId: sessionId)
        else { return MimoTranscript() }
        return transcript
    }

    /// A saved session to show again: a reply still marked streaming is
    /// marked stopped, and tool lines are cleared.
    func loadSettled(sessionId: String) -> MimoTranscript? {
        guard var transcript = load(sessionId: sessionId) else { return nil }
        for index in transcript.turns.indices {
            transcript.turns[index].toolLine = nil
            if transcript.turns[index].isStreaming {
                transcript.turns[index].status = .stopped
            }
        }
        return transcript
    }

    /// Makes `sessionId` the one the tab opens with next time.
    func setCurrent(_ sessionId: String) {
        guard let defaultsKey else { return }
        UserDefaults.standard.set(sessionId, forKey: defaultsKey)
    }

    // MARK: Files

    func load(sessionId: String) -> MimoTranscript? {
        guard let url = fileURL(for: sessionId),
              let data = try? Data(contentsOf: url)
        else { return nil }
        do {
            return try Self.decoder.decode(MimoTranscript.self, from: data)
        } catch {
            RyokoLog.mimo.error("Couldn't read a saved Mimo transcript: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Saves `transcript`. An empty transcript isn't written.
    func save(_ transcript: MimoTranscript) {
        guard !transcript.isEmpty, let directory, let url = fileURL(for: transcript.sessionId) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(transcript)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            RyokoLog.mimo.error("Couldn't save the Mimo transcript: \(String(describing: error), privacy: .public)")
        }
    }

    /// The saved chats, most recent first, for the history sidebar.
    func history() -> [MimoChatSummary] {
        guard let directory else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { load(sessionId: $0.deletingPathExtension().lastPathComponent) }
            .compactMap { transcript in
                guard let first = transcript.turns.first else { return nil }
                return MimoChatSummary(id: transcript.sessionId, title: first.message, updatedAt: transcript.updatedAt)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(sessionId: String) {
        guard let url = fileURL(for: sessionId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes all but the `keeping` most recently saved sessions.
    func prune(keeping: Int = MimoFeature.keptSessions) {
        guard let directory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let sessions = files
            .filter { $0.pathExtension == "json" }
            .map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in sessions.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for sessionId: String) -> URL? {
        // Session ids are our own UUIDs; refuse anything that could leave the folder.
        guard let directory,
              !sessionId.isEmpty,
              sessionId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return directory.appending(path: "\(sessionId).json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A saved chat in the history sidebar: its first message and when it last changed.
nonisolated struct MimoChatSummary: Identifiable, Hashable, Sendable {
    /// The session id.
    let id: String
    let title: String
    let updatedAt: Date
}
