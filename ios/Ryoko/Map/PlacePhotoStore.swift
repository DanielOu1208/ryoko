import CryptoKit
import Foundation
import ImageIO
import Observation
import SwiftUI
import UIKit
import os

// MARK: - Store

/// Which places have a photo (`POST /v1/place-photos`, Foursquare), for
/// `PlaceThumbnail` and the place card's header. One for the app, shared by
/// the Map's lists and Mimo's places cards.
///
/// - **Batching:** places asked for within about 150 ms go to the server
///   together, at most 25 per request. A row that disappears before its batch
///   is sent leaves it (so nobody pays to look it up); one that disappears
///   after gets nil at once, and the answer is still kept.
/// - **Answers** live in memory, keyed like the thumbnails (`MapPlace.key`):
///   a photo for the session, "no photo" for 10 minutes (the server keeps it
///   for a week; this only lets a server that gains a key show photos), a
///   failed request for a minute.
/// - **Fixtures vs live:** answers belong to the API that gave them. When the
///   environment's API changes kind, they're dropped.
///
/// `photoKeys` is the one observed property: views that credit Foursquare
/// read it through `hasPhoto(forAnyOf:)`. Thumbnails don't, so a new answer
/// doesn't redraw every row.
@MainActor
@Observable
final class PlacePhotoStore {
    static let shared = PlacePhotoStore()

    enum Answer: Equatable {
        case photo(URL)
        case noPhoto

        var url: URL? {
            if case let .photo(url) = self { url } else { nil }
        }
    }

    /// Keys of places known to have a photo.
    private(set) var photoKeys: Set<String> = []

    @ObservationIgnored private var answers: [String: (answer: Answer, until: ContinuousClock.Instant?)] = [:]
    /// Waiting for the next batch.
    @ObservationIgnored private var pending: [String: Pending] = [:]
    /// Keys whose batch is with the server, and who's waiting for them.
    @ObservationIgnored private var sent: [String: [Int: CheckedContinuation<URL?, Never>]] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var api: (any RyokoAPI)?
    @ObservationIgnored private var apiKind: String?
    @ObservationIgnored private var lastWaiterID = 0

    private struct Pending {
        var query: PlacePhotoQuery
        var waiters: [Int: CheckedContinuation<URL?, Never>] = [:]
    }

    static let batchDelay: Duration = .milliseconds(150)
    static let noPhotoLifetime: Duration = .seconds(600)
    static let failureLifetime: Duration = .seconds(60)

    private init() {}

    // MARK: Asking

    /// What's known about the place's photo right now, or nil when it hasn't
    /// been asked for (or the answer has expired, or came from another API).
    /// Only reads, so views can call it while they draw.
    func answer(for place: Place, api: any RyokoAPI) -> Answer? {
        guard Self.kind(of: api) == apiKind else { return nil }
        return answer(forKey: Self.key(for: place))
    }

    /// The place's photo url, or nil when it has none, the request failed, or
    /// the task was cancelled.
    func url(for place: Place, api: any RyokoAPI) async -> URL? {
        use(api)
        let key = Self.key(for: place)
        if let known = answer(forKey: key) { return known.url }
        guard !Task.isCancelled else { return nil }
        lastWaiterID += 1
        let id = lastWaiterID
        let query = Self.query(for: place, key: key)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if sent[key] != nil {
                    sent[key]?[id] = continuation
                } else {
                    pending[key, default: Pending(query: query)].waiters[id] = continuation
                    scheduleFlush()
                }
            }
        } onCancel: {
            Task { @MainActor in self.leave(key: key, id: id) }
        }
    }

    /// Whether any of these places has a photo on screen, so the view credits
    /// Foursquare. Observed: the view updates as photos come in.
    func hasPhoto(forAnyOf places: some Sequence<Place>) -> Bool {
        guard !photoKeys.isEmpty else { return false }
        return places.contains { photoKeys.contains(Self.key(for: $0)) }
    }

    // MARK: Keys and queries

    /// `MapPlace.key(for:)`, which the thumbnails use too, kept within the
    /// contract's 120 characters.
    static func key(for place: Place) -> String {
        let key = MapPlace.key(for: place)
        guard key.count > 120 else { return key }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "h:\(digest)"
    }

    static func query(for place: Place, key: String) -> PlacePhotoQuery {
        let name = String(place.name.prefix(120))
        let local = place.localName.map { String($0.prefix(120)) }.flatMap { $0.isEmpty || $0 == name ? nil : $0 }
        return PlacePhotoQuery(key: key, name: name, localName: local, coordinate: place.coordinate)
    }

    // MARK: Answers

    private func answer(forKey key: String) -> Answer? {
        guard let entry = answers[key] else { return nil }
        if let until = entry.until, ContinuousClock.now >= until { return nil }
        return entry.answer
    }

    private func record(_ answer: Answer, for key: String, lifetime: Duration?) {
        answers[key] = (answer, lifetime.map { ContinuousClock.now + $0 })
        if case .photo = answer {
            if !photoKeys.contains(key) { photoKeys.insert(key) }
        } else if photoKeys.contains(key) {
            photoKeys.remove(key)
        }
    }

    private static func kind(of api: any RyokoAPI) -> String {
        String(reflecting: type(of: api))
    }

    /// Keeps answers to the API that gave them.
    private func use(_ api: any RyokoAPI) {
        let kind = Self.kind(of: api)
        self.api = api
        guard kind != apiKind else { return }
        if apiKind != nil {
            answers = [:]
            if !photoKeys.isEmpty { photoKeys = [] }
        }
        apiKind = kind
    }

    // MARK: Batches

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.batchDelay)
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard let api, let apiKind else { return }
        while !pending.isEmpty {
            let batch = Array(pending.prefix(PlacePhotosRequest.maxPlaces))
            for (key, item) in batch {
                pending[key] = nil
                sent[key] = item.waiters
            }
            let queries = batch.map(\.value.query)
            Task { await self.send(queries, api: api, kind: apiKind) }
        }
    }

    private func send(_ queries: [PlacePhotoQuery], api: any RyokoAPI, kind: String) async {
        let result: Result<PlacePhotosResponse, any Error>
        do {
            result = .success(try await api.placePhotos(PlacePhotosRequest(places: queries)))
        } catch {
            result = .failure(error)
        }
        // The API changed while this was out: its answers don't belong to the new one.
        let current = kind == apiKind
        switch result {
        case let .success(response):
            let byKey = Dictionary(response.photos.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            var found = 0
            for query in queries {
                let url = byKey[query.key]?.url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                if url != nil { found += 1 }
                if current { record(url.map(Answer.photo) ?? .noPhoto, for: query.key, lifetime: url == nil ? Self.noPhotoLifetime : nil) }
                resolve(query.key, with: url)
            }
            RyokoLog.thumbnails.info("Place photos: \(found, privacy: .public) of \(queries.count, privacy: .public)")
        case let .failure(error):
            // A stand-in API without the endpoint never will have it; anything else may pass.
            let lifetime: Duration = if case .notConfigured = error as? RyokoAPIError { .seconds(3600) } else { Self.failureLifetime }
            for query in queries {
                if current { record(.noPhoto, for: query.key, lifetime: lifetime) }
                resolve(query.key, with: nil)
            }
            RyokoLog.thumbnails.error("Place photos failed for \(queries.count, privacy: .public) place(s): \(String(describing: error), privacy: .public)")
        }
    }

    private func resolve(_ key: String, with url: URL?) {
        guard let waiters = sent.removeValue(forKey: key) else { return }
        for continuation in waiters.values { continuation.resume(returning: url) }
    }

    /// A cancelled waiter: out of its batch if it isn't sent yet (with no one
    /// left waiting, the place leaves the batch), or answered nil at once.
    private func leave(key: String, id: Int) {
        if let continuation = pending[key]?.waiters.removeValue(forKey: id) {
            continuation.resume(returning: nil)
            if pending[key]?.waiters.isEmpty == true { pending[key] = nil }
        } else if let continuation = sent[key]?.removeValue(forKey: id) {
            continuation.resume(returning: nil)
        }
    }
}

// MARK: - Images

/// Downloads, decodes and caches place photos.
///
/// - **Memory:** decoded images by url and pixel size (a thumbnail and the
///   card's header are different sizes of one download).
/// - **Disk:** the downloaded bytes in `PlaceThumbnailDisk` (Caches, pruned
///   after two weeks), so a relaunch doesn't download them again.
/// - **Decoding** happens off the main actor, with ImageIO downsampling to
///   just what fills the frame.
/// - A url that failed isn't tried again for five minutes.
@MainActor
final class PlacePhotoImages {
    static let shared = PlacePhotoImages()

    private let images = NSCache<NSString, UIImage>()
    private var failedUntil: [URL: ContinuousClock.Instant] = [:]

    private init() {
        images.countLimit = 120
        images.totalCostLimit = 32 * 1024 * 1024
    }

    func cachedImage(at url: URL, filling points: CGSize, scale: CGFloat) -> UIImage? {
        images.object(forKey: Self.memoryKey(url, points, scale))
    }

    /// The photo sized to fill `points`, or nil when it can't be loaded (or
    /// the task was cancelled).
    func image(at url: URL, filling points: CGSize, scale: CGFloat) async -> UIImage? {
        let key = Self.memoryKey(url, points, scale)
        if let cached = images.object(forKey: key) { return cached }
        if let until = failedUntil[url], ContinuousClock.now < until { return nil }
        let diskName = "photo|v1|\(url.absoluteString)"
        var data = await PlaceThumbnailDisk.data(named: diskName)
        let fromDisk = data != nil
        if data == nil {
            data = await Self.download(url)
        }
        guard let data else {
            if !Task.isCancelled { markFailed(url) }
            return nil
        }
        let pixels = CGSize(width: points.width * scale, height: points.height * scale)
        guard let image = await Self.decode(data, filling: pixels, scale: scale) else {
            markFailed(url)
            return nil
        }
        if !fromDisk { Task { await PlaceThumbnailDisk.save(data, named: diskName) } }
        let bytes = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        images.setObject(image, forKey: key, cost: bytes)
        return image
    }

    private func markFailed(_ url: URL) {
        failedUntil[url] = .now + .seconds(300)
        RyokoLog.thumbnails.debug("Couldn't load a place photo")
    }

    private static func memoryKey(_ url: URL, _ points: CGSize, _ scale: CGFloat) -> NSString {
        "\(url.absoluteString)|\(Int(points.width * scale))x\(Int(points.height * scale))" as NSString
    }

    /// The bytes of an image, or nil (an error, not an image, or cancelled).
    @concurrent
    private static func download(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 20)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true else { return nil }
        return data
    }

    /// Downsampled so it just covers `pixels` (aspect fill), never larger than the photo.
    @concurrent
    private static func decode(_ data: Data, filling pixels: CGSize, scale: CGFloat) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        var longest = max(pixels.width, pixels.height)
        if width > 0, height > 0 {
            // Enough to cover the frame whichever way EXIF turns the photo.
            let cover = max(pixels.width, pixels.height) / min(width, height)
            longest = max(width, height) * min(cover, 1)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longest.rounded(.up))),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image, scale: max(scale, 1), orientation: .up)
    }
}

// MARK: - Credit

/// "Powered by Foursquare", which Foursquare's terms ask for on any screen
/// that shows its data. It shows only while one of `places` has a photo.
///
/// In a lazy list or the Mimo chat, pass `keepsSpace`: the line then always
/// takes its height and only fades in, so nothing moves as photos arrive (a
/// lazy stack whose end grows then can lose its scroll position).
struct FoursquareCredit: View {
    let places: [Place]
    var keepsSpace = false

    var body: some View {
        let shown = PlacePhotoStore.shared.hasPhoto(forAnyOf: places)
        if shown || keepsSpace {
            Text("Powered by Foursquare")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(!shown)
                .animation(.smooth, value: shown)
        }
    }
}
