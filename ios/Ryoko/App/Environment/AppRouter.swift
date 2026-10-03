import Observation
import SwiftUI

/// Hand-offs between tabs (design §4.3, §4.7, §4.9). `RyokoApp` owns the one
/// instance and puts it in the environment; `RootTabView` binds the tab bar to
/// `selectedTab` and presents `show`. Features never edit the shell for these:
///
///     @Environment(AppRouter.self) private var router
///
///     router.openNearby()                      // Map sheet: a place became current (W4)
///     router.openMap(centeredOn: coordinate)   // Nearby's mini map (W3)
///     router.askMimo(about: place)             // place sheet: dismiss it first (W4)
///     router.showOnMap(pins)                   // Mimo's "Show on map" (W6)
///     router.show = .phrase(phrase)            // Show mode from Nearby or Mimo
///
/// The receiving tab reads its hand-off and clears what it has used: Map sets
/// `mapFocus` back to nil once applied, so the same focus can be asked for
/// again.
@MainActor
@Observable
final class AppRouter {
    /// The selected tab.
    var selectedTab: AppTab

    /// Where the Map goes next. Map applies it with
    /// `.onChange(of: router.mapFocus, initial: true)` and then sets it to nil.
    var mapFocus: MapFocus?

    /// The place "Ask Mimo about this place" attached (design §4.9). Mimo sends
    /// it as `subjectPlace` until it clears it (the subject's close button, or
    /// New chat). It never changes the active situation.
    var mimoSubject: Place?

    /// The Map's From Mimo layer (design §4.7): places, or a plan's numbered
    /// stops, from the Mimo tab, already resolved on the device. It stays until
    /// `clearFromMimo()` (the layer's clear action, or Mimo's New chat).
    private(set) var fromMimo: [FromMimoPin] = []

    /// Show mode, presented full screen over the tabs by `RootTabView`. A view
    /// that is itself in a sheet (the Map's place sheet) presents Show mode with
    /// its own `.fullScreenCover`, because the root can't present over a sheet.
    var show: ShowContent?

    init(selectedTab: AppTab = .map) {
        self.selectedTab = selectedTab
    }

    /// Opens Nearby: the Map sheet calls this after a tapped place became the
    /// current place (design §4.7).
    func openNearby() {
        selectedTab = .nearby
    }

    /// Opens the Map centred on `coordinate` (Nearby's mini map tile).
    func openMap(centeredOn coordinate: Coordinate) {
        mapFocus = .coordinate(coordinate)
        selectedTab = .map
    }

    /// Opens the Map on `place`, selected, with its place sheet.
    func openMap(selecting place: Place) {
        mapFocus = .place(place)
        selectedTab = .map
    }

    /// Replaces the From Mimo layer and opens the Map fitted to it ("Show on map").
    func showOnMap(_ pins: [FromMimoPin]) {
        fromMimo = pins
        mapFocus = .fromMimo
        selectedTab = .map
    }

    /// Removes the From Mimo layer.
    func clearFromMimo() {
        fromMimo = []
    }

    /// Opens Mimo with `place` as the subject. Callers in a sheet dismiss it first.
    func askMimo(about place: Place) {
        mimoSubject = place
        selectedTab = .mimo
    }
}

/// Where the Map should go next.
nonisolated enum MapFocus: Hashable, Sendable {
    /// Centre on a point (Nearby's mini map: "opens the Map tab centred here").
    case coordinate(Coordinate)
    /// Centre on a place and select it, opening its place sheet.
    case place(Place)
    /// Fit the From Mimo layer's pins.
    case fromMimo
}

/// One pin on the Map's From Mimo layer: a place Mimo named (`show_places`),
/// found with the shared `PlaceResolver`. Misses never become pins.
nonisolated struct FromMimoPin: Hashable, Sendable, Identifiable {
    /// What Mimo said: the name, the one-line why and, for a plan stop, its
    /// number (`order`, 1–5) and local time (`when`, `HH:mm`).
    var shown: ShownPlace
    var resolved: ResolvedPlace

    var id: String { resolved.id }
}

nonisolated extension [FromMimoPin] {
    /// A plan's stops carry an order: show numbered pins, in that order.
    var isPlan: Bool { contains { $0.shown.order != nil } }
}
