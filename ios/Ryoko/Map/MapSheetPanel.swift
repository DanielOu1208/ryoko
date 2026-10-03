import SwiftUI

/// The Map's Apple Maps-style bottom sheet (design §4.7, W4.5), built as a
/// panel inside the tab rather than a `.sheet`.
///
/// Why not a native sheet: inside `TabView`, a `.sheet` with
/// `presentationDetents` and `presentationBackgroundInteraction` covers the
/// tab bar at every detent (checked on the iOS 27 simulator), and the tab bar
/// must stay usable. So this is the closest native-looking alternative: a
/// floating material panel above the tab bar with a grabber and three snap
/// points (small, about three rows; medium; large). Drag the grabber or header
/// to resize; tap the grabber to step up; VoiceOver can adjust it. The content
/// scrolls inside at every size, and the map above stays usable.
struct MapSheetPanel<Header: View, Content: View>: View {
    @Binding var detent: MapSheetDetent
    /// Heights for each detent, from the space between the search bar and the tab bar.
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
        .background(.regularMaterial, in: Self.shape)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 4)
        .padding(.horizontal, MapSheetMetrics.sideInset)
        .padding(.bottom, MapSheetMetrics.bottomGap)
        .animation(.snappy, value: detent)
    }

    private var grabber: some View {
        Button {
            detent = detent == .large ? .small : detent.next
        } label: {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 20)
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

/// The panel's snap heights for the space it has.
struct MapSheetMetrics: Equatable {
    static let sideInset: CGFloat = 8
    static let bottomGap: CGFloat = 8
    /// Space left between the large panel and the search bar.
    static let topGap: CGFloat = 8

    var small: CGFloat
    var medium: CGFloat
    var large: CGFloat

    /// - Parameters:
    ///   - available: the height between the search bar and the tab bar.
    ///   - smallContent: the header plus about three rows.
    init(available: CGFloat, smallContent: CGFloat) {
        let large = max(available - Self.topGap - Self.bottomGap, 200)
        let small = min(max(smallContent, 140), large * 0.55)
        self.large = large
        self.small = small
        medium = min(max(large * 0.55, small + 120), large)
    }

    func height(for detent: MapSheetDetent) -> CGFloat {
        switch detent {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    /// The map's bottom safe-area padding: the small panel and its gap, so the
    /// map's legal notice and centring stay above it.
    var mapBottomPadding: CGFloat { small + Self.bottomGap }
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
