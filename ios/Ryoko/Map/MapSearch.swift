import MapKit
import Observation
import os

/// The Map's search (design §4.7): `MKLocalSearchCompleter` suggestions while
/// typing, in English or local script ("Heytea Jing'an", "喜茶 静安"), and an
/// `MKLocalSearch` for a picked suggestion or a submitted query.
///
/// Searches are biased to the visible map region (`regionPriority .default`),
/// not limited to it: look-ahead means finding places in other cities. A picked
/// suggestion resolves to one exact map item, so nothing leaks in from elsewhere.
@MainActor
@Observable
final class MapSearch {
    /// The search field's text. Each change asks the completer for suggestions.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            let fragment = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if fragment.isEmpty {
                completer.cancel()
                suggestions = []
            } else {
                completer.queryFragment = fragment
            }
        }
    }

    /// Whether the search field is active.
    var isPresented = false

    private(set) var suggestions: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private let relay = CompleterRelay()

    init() {
        completer.resultTypes = [.pointOfInterest, .address]
        completer.regionPriority = .default
        relay.onUpdate = { [weak self] in
            guard let self else { return }
            suggestions = completer.results
        }
        relay.onEmpty = { [weak self] in self?.suggestions = [] }
        relay.onError = { error in
            RyokoLog.places.error("Search suggestions failed: \(String(describing: error), privacy: .public)")
        }
        completer.delegate = relay
    }

    /// Biases suggestions to what's on screen.
    func setRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    /// The map item for a suggestion.
    func item(for completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.pointOfInterest, .address]
        do {
            return try await MKLocalSearch(request: request).start().mapItems.first
        } catch {
            RyokoLog.places.error("Couldn't open a suggestion: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Places matching a typed query, near `region` first. Empty when nothing matches.
    func items(for query: String, near region: MKCoordinateRegion?) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let region {
            request.region = region
            request.regionPriority = .default
        }
        do {
            return try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            RyokoLog.places.error("Search failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

/// The completer's delegate. MapKit calls it on the main thread.
private final class CompleterRelay: NSObject, MKLocalSearchCompleterDelegate {
    var onUpdate: (() -> Void)?
    var onEmpty: (() -> Void)?
    var onError: ((any Error) -> Void)?

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            onUpdate?()
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            // No results is reported as an error; it isn't one.
            if (error as? MKError)?.code == .placemarkNotFound {
                onEmpty?()
            } else {
                onError?(error)
            }
        }
    }
}
