import SwiftUI

/// The Map's Apple Maps-style bottom sheet (design §4.7, W4.5), built as a
/// panel inside the tab rather than a `.sheet`.
///
/// Why not a native sheet: inside `TabView`, a `.sheet` with
/// `presentationDetents` and `presentationBackgroundInteraction` covers the
/// tab bar at every detent (checked on the iOS 27 simulator), and the tab bar
/// must stay usable. So this is the closest native-looking alternative: a
/// floating panel above the tab bar with a grabber and three snap points
/// (`MapSheetMetrics`). Drag the grabber or header to resize; tap the grabber
/// to step up; VoiceOver can adjust it. The content scrolls inside at every
/// size, and the map above stays usable.
///
/// The panel is solid (the grouped background, like a native grouped sheet),
/// with solid cards on it: no glass on content (design §9.4).
struct MapSheetPanel<Header: View, Content: View>: View {
    @Binding var detent: MapSheetDetent
    /// Heights for each detent, from the space the panel has.
    let metrics: MapSheetMetrics
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var dragOffset: CGFloat = 0

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 32, style: .continuous) }

    var body: some View {
        let resting = metrics.height(for: detent)
        let height = min(max(resting - dragOffset, metrics.small * 0.8), metrics.large)

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                grabber
                header()
            }
            .contentShape(.rect)
            .gesture(drag(from: resting))

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Theme.pageBackground, in: Self.shape)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 4)
        .padding(.horizontal, MapSheetMetrics.sideInset)
        .padding(.bottom, MapSheetMetrics.bottomGap)
        .animation(.snappy, value: detent)
        .animation(.snappy, value: metrics)
    }

    private var grabber: some View {
        Button {
            detent = detent == .large ? .small : detent.next
        } label: {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: MapSheetMetrics.grabberHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sheet")
        .accessibilityValue(detent.accessibilityName)
        .accessibilityHint("Swipe up or down to resize")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: detent = detent.next
            case .decrement: detent = detent.previous
            @unknown default: break
            }
        }
    }

    private func drag(from resting: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($dragOffset) { value, offset, _ in
                offset = value.translation.height
            }
            .onEnded { value in
                // Where the panel would come to rest, then the nearest snap point.
                let projected = resting - value.predictedEndTranslation.height
                detent = MapSheetDetent.allCases.min {
                    abs(metrics.height(for: $0) - projected) < abs(metrics.height(for: $1) - projected)
                } ?? detent
            }
    }
}

/// The panel's snap heights for the space it has (design §4.7):
///
/// - **small:** just the header (collapsed).
/// - **medium:** about 45% of the space under the search field. The list rests here.
/// - **large:** for the list, up to the search field; for a place card, almost
///   the whole screen, leaving a strip of map (`cardMapStrip`) above it for
///   the place's pin. The search field and map buttons step aside for it.
struct MapSheetMetrics: Equatable {
    static let sideInset: CGFloat = 8
    static let bottomGap: CGFloat = 8
    /// Space left between the large list and the search bar.
    static let topGap: CGFloat = 8
    static let grabberHeight: CGFloat = 20
    /// Share of the space under the search field the list rests at.
    static let restingShare: CGFloat = 0.45
    /// The map left above a card at its large size, under the status bar.
    /// With the status bar the visible strip is about 160 pt.
    static let cardMapStrip: CGFloat = 100

    var small: CGFloat
    var medium: CGFloat
    var large: CGFloat

    /// - Parameters:
    ///   - screen: the height between the status bar and the tab bar.
    ///   - belowSearch: where the search field ends, from the top of `screen`.
    ///   - header: the header's height (under the grabber).
    ///   - isCard: whether the panel shows a place card.
    init(screen: CGFloat, belowSearch: CGFloat, header: CGFloat, isCard: Bool) {
        let available = max(screen - belowSearch, 240)
        let listLarge = max(available - Self.topGap - Self.bottomGap, 200)
        let small = min(max(Self.grabberHeight + header + Theme.grid, 88), listLarge * 0.4)
        let medium = min(max(available * Self.restingShare, small + 120), listLarge)
        let cardLarge = max(screen - Self.cardMapStrip - Self.bottomGap, medium + 80)
        self.small = small
        self.medium = medium
        large = isCard ? min(cardLarge, screen - Self.bottomGap) : listLarge
    }

    func height(for detent: MapSheetDetent) -> CGFloat {
        switch detent {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    /// The map's bottom safe-area padding: the resting list and its gap, so
    /// the map's legal notice, your location and fitted pins stay above it.
    /// It doesn't follow the panel, so resizing the panel never moves the map.
    var mapBottomPadding: CGFloat { medium + Self.bottomGap }
}

extension MapSheetDetent {
    var accessibilityName: String {
        switch self {
        case .small: "Collapsed"
        case .medium: "Half height"
        case .large: "Full height"
        }
    }
}
