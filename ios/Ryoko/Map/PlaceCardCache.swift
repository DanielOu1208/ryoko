import Foundation
import os

/// The last place card shown for each place, saved on the device, so a failed
/// load can fall back to it (design §4.12: offline shows the last cached card,
/// marked as such). Only the Map's place card reads it; the server keeps its
/// own cache, and `MapHomeModel` keeps this session's cards in memory.
///
/// Keyed by the place (its MapKit id, or name plus coordinates) and the local
/// language, or by the city for a city-only situation. Holds the most recent
/// `limit` cards in `Caches/Ryoko/place-cards.json`.
@MainActor
final class PlaceCardCache {
    static let shared = PlaceCardCache()

    struct Entry: Codable {
        var key: String
        var card: PlaceCardResponse
        var savedAt: Date
    }

    private var entries: [Entry]
    private let fileURL: URL?
    private let limit: Int

    init(fileURL: URL? = PlaceCardCache.defaultFileURL, limit: Int = 30) {
        self.fileURL = fileURL
        self.limit = limit
        entries = Self.load(from: fileURL)
    }

    /// The saved card for this situation's place, if there is one.
    func entry(for situation: Situation) -> Entry? {
        let key = Self.key(for: situation)
        return entries.first { $0.key == key }
    }

    func save(_ card: PlaceCardResponse, for situation: Situation, at date: Date = .now) {
        let key = Self.key(for: situation)
        entries.removeAll { $0.key == key }
        entries.insert(Entry(key: key, card: card, savedAt: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        write()
    }

    nonisolated static func key(for situation: Situation) -> String {
        let where_: String
        if let place = situation.place {
            where_ = place.id ?? "\(place.name)@\(String(format: "%.4f,%.4f", place.coordinate.lat, place.coordinate.lon))"
        } else {
            where_ = "city:\(situation.city),\(situation.countryCode)"
        }
        return "\(where_)|\(situation.localLanguage)"
    }

    // MARK: Storage

    static var defaultFileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appending(path: "Ryoko", directoryHint: .isDirectory).appending(path: "place-cards.json")
    }

    private static func load(from url: URL?) -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func write() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            RyokoLog.placeCards.error("Couldn't save the place card: \(String(describing: error), privacy: .public)")
        }
    }
}

extension RyokoLog {
    nonisolated static let placeCards = Logger(subsystem: subsystem, category: "place-cards")
}
