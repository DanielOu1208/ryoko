import CryptoKit
import MapKit
import SwiftUI
import UIKit
import os

// MARK: - View

/// A small, rounded picture of a place, for list rows (the Map's lists,
/// Mimo's places card), in this order:
///
/// 1. A photo of the place from Foursquare (`PlacePhotoStore`, through the
///    server). MapKit has no public API for the photos Apple Maps shows on a
///    listing.
/// 2. Otherwise Apple's Look Around imagery of the street in front of it.
/// 3. Where there's none (mainland China, most small towns), a satellite
///    tile with a pin.
///
/// The category icon shows while it loads, and stays if all fail; the image
/// then fades in. Decorative, so VoiceOver skips it. Inside a `.redacted`
/// placeholder it loads nothing. Look Around's loading, limits and caching
/// are in `PlaceThumbnailLoader`; photos' in `PlacePhotoStore` and
/// `PlacePhotoImages`. A screen that shows these thumbnails credits
/// Foursquare with `FoursquareCredit`.
struct PlaceThumbnail: View {
    static let defaultSize: CGFloat = 56

    let place: Place
    var size: CGFloat = PlaceThumbnail.defaultSize
    var cornerRadius: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.ryokoAPI) private var api
    @State private var loaded: Loaded?

    private struct Loaded {
        var key: PlaceThumbnailLoader.Key
        var image: UIImage
    }

    var body: some View {
        let request = PlaceThumbnailLoader.Request(place: place, points: size, scale: displayScale, dark: colorScheme == .dark)
        // Straight from memory when it's there, so rows scrolled back into view
        // don't flash the icon.
        let image = loaded?.key == request.key ? loaded?.image : cachedImage(for: request)
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: request.key) {
            guard !redactionReasons.contains(.placeholder) else { return }
            if let cached = cachedImage(for: request) {
                loaded = Loaded(key: request.key, image: cached)
                return
            }
            if let url = await PlacePhotoStore.shared.url(for: place, api: api),
               let photo = await PlacePhotoImages.shared.image(at: url, filling: photoSize, scale: displayScale) {
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.35)) {
                    loaded = Loaded(key: request.key, image: photo)
                }
                return
            }
            guard !Task.isCancelled,
                  let image = await PlaceThumbnailLoader.shared.image(for: request), !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.35)) {
                loaded = Loaded(key: request.key, image: image)
            }
        }
    }

    private var photoSize: CGSize { CGSize(width: size, height: size) }

    /// The image from memory: the photo when the place has one; Look Around's
    /// (or the tile) once it's known there's no photo; nil while that's unknown.
    private func cachedImage(for request: PlaceThumbnailLoader.Request) -> UIImage? {
        switch PlacePhotoStore.shared.answer(for: place, api: api) {
        case let .photo(url):
            PlacePhotoImages.shared.cachedImage(at: url, filling: photoSize, scale: displayScale)
                ?? PlaceThumbnailLoader.shared.cachedImage(for: request.key)
        case .noPhoto:
            PlaceThumbnailLoader.shared.cachedImage(for: request.key)
        case nil:
            nil
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                // Sized to the tile, which doesn't grow with Dynamic Type.
                Image(systemName: place.category.sfSymbol)
                    .font(.system(size: size * 0.36))
                    .foregroundStyle(.secondary)
            }
    }
}

// MARK: - Loader

/// Makes, limits and caches `PlaceThumbnail` images, and the Look Around
/// scenes behind them (the place card's preview uses the same scenes).
///
/// - **Scene:** `MKLookAroundSceneRequest` with the place's `MKMapItem` when
///   one passed through the app (`remember(_:for:)`: MapKit search, nearest
///   places, map features, the resolver's hits), else its coordinate. "No
///   scene" is cached too.
/// - **Image:** `MKLookAroundSnapshotter` at the tile's size and the screen's
///   scale; with no scene (or a failed lookup or snapshot), `MKMapSnapshotter`
///   satellite imagery around the place with a pin. Satellite, because the
///   standard map's district and road labels land under the pin as fragments
///   at this size, and only points of interest can be turned off.
/// - **Limits:** at most two places load at once; a row that disappears
///   leaves the queue (or stops after its current request). A
///   `loadingThrottled` error pauses loading for a minute.
/// - **Caches:** images in memory by place key, pixel size and light or dark,
///   and on disk in Caches (`PlaceThumbnailDisk`); scenes and map items in
///   memory. A satellite tile is kept only when there's no Look Around scene
///   there; one drawn because Look Around failed shows on that row but isn't
///   kept, so the place asks for Look Around again next time.
@MainActor
final class PlaceThumbnailLoader {
    static let shared = PlaceThumbnailLoader()

    struct Key: Hashable, Sendable {
        /// `MapPlace.key(for:)`.
        var place: String
        var pixels: Int
        var dark: Bool

        /// For the caches. The version changes with the drawing, so images an
        /// older build saved on disk aren't reused. (v1 kept map tiles drawn
        /// after a failed Look Around, and drew the standard map.)
        var name: String { "v2|\(place)|\(pixels)|\(dark ? "dark" : "light")" }
    }

    struct Request {
        var place: Place
        var points: CGFloat
        var scale: CGFloat
        var dark: Bool
        var key: Key

        init(place: Place, points: CGFloat, scale: CGFloat, dark: Bool) {
            self.place = place
            self.points = points
            self.scale = max(scale, 1)
            self.dark = dark
            key = Key(place: MapPlace.key(for: place), pixels: Int((points * self.scale).rounded(.up)), dark: dark)
        }
    }

    private let images = NSCache<NSString, UIImage>()
    private let scenes = NSCache<NSString, SceneBox>()
    private let mapItems = NSCache<NSString, MKMapItem>()
    private let limiter = AsyncLimiter(limit: 2)
    /// After a `loadingThrottled` error: no MapKit requests before this.
    private var pausedUntil: ContinuousClock.Instant?

    private init() {
        images.countLimit = 150
        images.totalCostLimit = 24 * 1024 * 1024
        scenes.countLimit = 300
        mapItems.countLimit = 400
        Task { await PlaceThumbnailDisk.prune() }
    }

    // MARK: Map items

    /// Keeps a place's map item, so its Look Around scene can be asked for by
    /// item (it then faces the place) rather than by coordinate.
    func remember(_ item: MKMapItem, for place: Place) {
        mapItems.setObject(item, forKey: MapPlace.key(for: place) as NSString)
    }

    // MARK: Images

    func cachedImage(for key: Key) -> UIImage? {
        images.object(forKey: key.name as NSString)
    }

    /// The thumbnail for `request`, or nil when MapKit has nothing (or failed,
    /// or the task was cancelled). Nothing is cached after a failure: not a
    /// missing image, and not a satellite tile drawn because Look Around failed.
    func image(for request: Request) async -> UIImage? {
        if let cached = cachedImage(for: request.key) { return cached }
        if let data = await PlaceThumbnailDisk.data(named: request.key.name),
           let image = UIImage(data: data, scale: request.scale) {
            store(image, for: request.key)
            return image
        }
        guard !Task.isCancelled else { return nil }
        do {
            let rendered = try await limiter.run { try await self.render(request) }
            if rendered.isKept {
                store(rendered.image, for: request.key)
                if let data = rendered.image.jpegData(compressionQuality: 0.85) {
                    Task { await PlaceThumbnailDisk.save(data, named: request.key.name) }
                }
            }
            return rendered.image
        } catch {
            if !(error is CancellationError) {
                RyokoLog.thumbnails.debug("No thumbnail for \(request.place.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// An image from `render`.
    private struct Rendered {
        var image: UIImage
        /// Whether to cache it: a Look Around snapshot, or a satellite tile
        /// where there's no Look Around. Not a tile standing in for a Look
        /// Around that failed, nor an image that's already cached.
        var isKept: Bool
    }

    /// Runs inside a limiter slot. Throws when there's no image at all.
    private func render(_ request: Request) async throws -> Rendered {
        // Another row may have made it while this one waited.
        if let cached = cachedImage(for: request.key) { return Rendered(image: cached, isKept: false) }
        try checkNotPaused()
        let size = CGSize(width: request.points, height: request.points)
        let traits = UITraitCollection { traits in
            traits.displayScale = request.scale
            traits.userInterfaceStyle = request.dark ? .dark : .light
        }
        let lookAroundFailed: Bool
        do {
            if let scene = try await lookUpScene(for: request.place) {
                try Task.checkCancellation()
                return Rendered(image: try await lookAroundImage(of: scene, size: size, traits: traits), isKept: true)
            }
            // MapKit answered: no imagery here.
            lookAroundFailed = false
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MKError where error.code == .loadingThrottled {
            throw error
        } catch {
            // Often a tile fetch that failed for a moment: the tile below
            // stands in on this row only, and the next load tries again.
            lookAroundFailed = true
            RyokoLog.thumbnails.debug("Look Around failed for \(request.place.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        try Task.checkCancellation()
        let tile = try await satelliteImage(at: request.place.coordinate.mapKitCoordinate, size: size, traits: traits)
        return Rendered(image: tile, isKept: !lookAroundFailed)
    }

    private func store(_ image: UIImage, for key: Key) {
        let bytes = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        images.setObject(image, forKey: key.name as NSString, cost: bytes)
    }

    private func lookAroundImage(of scene: MKLookAroundScene, size: CGSize, traits: UITraitCollection) async throws -> UIImage {
        let options = MKLookAroundSnapshotter.Options()
        options.size = size
        options.traitCollection = traits
        options.pointOfInterestFilter = .excludingAll
        let snapshotter = MKLookAroundSnapshotter(scene: scene, options: options)
        return try await snapshotter.snapshot.image
    }

    /// About 350 m of satellite imagery around the place, with a pin in the
    /// middle. Satellite imagery has no labels, so no district name sits in
    /// fragments under the pin as it does on the standard map.
    private func satelliteImage(at coordinate: CLLocationCoordinate2D, size: CGSize, traits: UITraitCollection) async throws -> UIImage {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 350, longitudinalMeters: 350)
        options.size = size
        options.traitCollection = traits
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        let snapshot = try await mapSnapshot(options)
        return Self.drawPin(on: snapshot.image, at: snapshot.point(for: coordinate), traits: traits)
    }

    private func mapSnapshot(_ options: MKMapSnapshotter.Options) async throws -> MKMapSnapshotter.Snapshot {
        do {
            return try await MKMapSnapshotter(options: options).start()
        } catch let error as MKError where error.code == .loadingThrottled {
            pause()
            throw error
        }
    }

    /// A monochrome pin (a dot in the label colour, ringed in the background
    /// colour), so it reads on light and dark maps without adding a colour.
    private static func drawPin(on image: UIImage, at point: CGPoint, traits: UITraitCollection) -> UIImage {
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.scale = image.scale
        format.opaque = true
        let ring = UIColor.systemBackground.resolvedColor(with: traits)
        let dot = UIColor.label.resolvedColor(with: traits)
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            let cg = context.cgContext
            cg.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            ring.setFill()
            UIBezierPath(ovalIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)).fill()
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            dot.setFill()
            UIBezierPath(ovalIn: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)).fill()
        }
    }

    // MARK: Scenes

    /// The scene when it's known: `.some(nil)` means there's none.
    func cachedScene(for place: Place) -> MKLookAroundScene?? {
        scenes.object(forKey: MapPlace.key(for: place) as NSString).map(\.scene)
    }

    /// The place's Look Around scene, or nil when there's none, MapKit
    /// failed, or the task was cancelled.
    func scene(for place: Place) async -> MKLookAroundScene? {
        if let known = cachedScene(for: place) { return known }
        do {
            return try await limiter.run {
                try self.checkNotPaused()
                return try await self.lookUpScene(for: place)
            }
        } catch {
            if !(error is CancellationError) {
                RyokoLog.thumbnails.debug("No Look Around scene for \(place.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// Runs inside a limiter slot. Caches the answer, "none" included; throws
    /// when MapKit failed.
    private func lookUpScene(for place: Place) async throws -> MKLookAroundScene? {
        let key = MapPlace.key(for: place) as NSString
        if let known = scenes.object(forKey: key) { return known.scene }
        let request = if let item = mapItems.object(forKey: key) {
            MKLookAroundSceneRequest(mapItem: item)
        } else {
            MKLookAroundSceneRequest(coordinate: place.coordinate.mapKitCoordinate)
        }
        do {
            let scene = try await request.scene
            scenes.setObject(SceneBox(scene), forKey: key)
            return scene
        } catch let error as MKError where error.code == .placemarkNotFound {
            scenes.setObject(SceneBox(nil), forKey: key)
            return nil
        } catch let error as MKError where error.code == .loadingThrottled {
            pause()
            throw error
        }
    }

    // MARK: Throttling

    private func pause() {
        pausedUntil = .now + .seconds(60)
        RyokoLog.thumbnails.error("MapKit throttled place thumbnails; pausing for a minute")
    }

    private func checkNotPaused() throws {
        if let pausedUntil, ContinuousClock.now < pausedUntil {
            throw MKError(.loadingThrottled)
        }
    }
}

/// An `NSCache` value for a scene or "no scene".
private final class SceneBox {
    let scene: MKLookAroundScene?
    init(_ scene: MKLookAroundScene?) { self.scene = scene }
}

// MARK: - Limiter

/// At most `limit` operations at once; the rest wait their turn. A waiting
/// task that's cancelled leaves the queue without running.
@MainActor
private final class AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var lastID = 0

    init(limit: Int) {
        self.limit = limit
    }

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        if running < limit {
            running += 1
            return
        }
        lastID += 1
        let id = lastID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
    }

    private func leave(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot straight to the next in line, if any.
    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }
}

// MARK: - Disk

/// Thumbnails saved in Caches, so lists open with their images after a
/// relaunch. The system may clear it; files older than two weeks are removed.
nonisolated enum PlaceThumbnailDisk {
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    private static let directory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "PlaceThumbnails", directoryHint: .isDirectory)

    @concurrent static func data(named name: String) async -> Data? {
        guard let url = url(for: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    @concurrent static func save(_ data: Data, named name: String) async {
        guard let directory, let url = url(for: name) else { return }
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

    private static func url(for name: String) -> URL? {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appending(path: "\(digest).jpg")
    }
}

extension RyokoLog {
    nonisolated static let thumbnails = Logger(subsystem: subsystem, category: "thumbnails")
}
