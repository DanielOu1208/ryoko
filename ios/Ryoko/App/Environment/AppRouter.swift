import Observation
import SwiftUI

/// Hand-offs between tabs (design §4.7, §4.9). `RyokoApp` owns the one
/// instance and puts it in the environment; `RootTabView` binds the tab bar to
/// `selectedTab` and presents `show`. Features never edit the shell for these:
///
///     @Environment(AppRouter.self) private var router
///
///     router.openMap(selecting: place)         // the Map, with that place's card open
///     router.openMapAtCurrentPlace()           // the Map, with the current place's card (Live Activity)
///     router.askMimo(about: place)             // a place card's Ask Mimo (W4)
///     router.showOnMap(pins)                   // Mimo's "Show on map" (W6)
///     router.show = .phrase(phrase)            // Show mode from a place card or Mimo
///
/// Places live on the Map: any hand-off that shows a place opens its card in
/// the Map's sheet. None of them changes the situation; only the card's
/// "I'm here" and Preview do.
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

    /// "Ask Mimo" on a place's card (design §4.9): Mimo starts a new chat
    /// about this place and asks about it straight away, then clears it. The
    /// chat keeps the place as its subject (sent as `subjectPlace` with every
    /// message); it never changes the active situation.
    var mimoQuestion: Place?

    /// The Map's From Mimo layer (design §4.7): places, or a plan's numbered
    /// stops, from the Mimo tab, already resolved on the device. It stays until
    /// `clearFromMimo()` (the layer's clear action, or Mimo's New chat).
    private(set) var fromMimo: [FromMimoPin] = []

    /// Show mode, presented full screen over the tabs by `RootTabView`. A view
    /// that is itself in a native sheet presents Show mode with its own
    /// `.fullScreenCover`, because the root can't present over a sheet. (The
    /// Map's sheet is a panel inside the tab, so place cards use this.)
    var show: ShowContent?

    init(selectedTab: AppTab = .map) {
        self.selectedTab = selectedTab
    }

    /// Opens the Map centred on `coordinate`, with the list in the sheet.
    func openMap(centeredOn coordinate: Coordinate) {
        mapFocus = .coordinate(coordinate)
        selectedTab = .map
    }

    /// Opens the Map on `place`, highlighted, with its card in the sheet.
    func openMap(selecting place: Place) {
        mapFocus = .place(place)
        selectedTab = .map
    }

    /// Opens the Map with the current place's card (live or previewed), or
    /// the list when there's no current place. The Live Activity's tap.
    func openMapAtCurrentPlace() {
        mapFocus = .currentPlace
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

    /// Opens Mimo on a new chat about `place`, asked at once (`mimoQuestion`).
    /// Callers in a sheet dismiss it first.
    func askMimo(about place: Place) {
        mimoQuestion = place
        selectedTab = .mimo
    }
}

/// Where the Map should go next.
nonisolated enum MapFocus: Hashable, Sendable {
    /// Centre on a point, with the list in the sheet.
    case coordinate(Coordinate)
    /// Centre on a place and highlight it, with its card in the sheet.
    case place(Place)
    /// The current place's card (live or previewed), if there is one.
    case currentPlace
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
