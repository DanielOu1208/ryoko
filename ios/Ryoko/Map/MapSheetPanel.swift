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
///
/// **Dragging follows the finger 1:1** and animates only on release:
/// - The live offset is panel-local state with no implicit animation on it;
///   only snaps (and sizes set from code) animate.
/// - The header and content are built once by the caller and stored, so a
///   drag frame re-renders only the panel's frame, not the list or card.
/// - While dragging, the content keeps one fixed layout (the large size) and
///   the panel just clips it, so the list or card isn't laid out again on
///   every frame. It goes back to the snapped size on release.
/// - The shadow is drawn from the background shape, not from the content.
/// - Release snaps to the detent nearest the gesture's predicted end, with a
///   spring that carries on at the finger's speed.
/// - The camera re-frames a card only after the snap (`MapView` follows
///   `detent`, which changes once, on release).
///
/// Pulling down on scroll content that's already at its top doesn't resize
/// the panel (Apple Maps does that): drag the grabber or header instead.
struct MapSheetPanel<Header: View, Content: View>: View {
    @Binding var detent: MapSheetDetent
    /// Heights for each detent, from the space the panel has.
    let metrics: MapSheetMetrics
    private let header: Header
    private let content: Content

    init(
        detent: Binding<MapSheetDetent>,
        metrics: MapSheetMetrics,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        _detent = detent
        self.metrics = metrics
        self.header = header()
        self.content = content()
    }

    /// The finger's vertical travel while dragging (down is positive).
    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 32, style: .continuous) }

    var body: some View {
        let resting = metrics.height(for: detent)
        let height = liveHeight(resting: resting)

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                grabber
                header
            }
            .contentShape(.rect)
            // Ahead of the header's buttons once the finger moves, so a drag
            // that starts on "You're at …" or Back moves the panel at once;
            // a tap still reaches the button.
            .highPriorityGesture(drag(from: resting))

            MapSheetContentFrame(fixedHeight: isDragging ? metrics.large : nil) {
                content
            }
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .clipShape(Self.shape)
        .background {
            Self.shape
                .fill(Theme.pageBackground)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 4)
        }
        .overlay(Self.shape.strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        .padding(.horizontal, MapSheetMetrics.sideInset)
        .padding(.bottom, MapSheetMetrics.bottomGap)
        // Sizes set from code (a card opening, Back) glide; a release brings
        // its own spring, which this leaves alone.
        .transaction(value: detent) { transaction in
            if transaction.animation == nil { transaction.animation = .smooth }
        }
        .animation(.smooth, value: metrics)
        .onChange(of: isDragging) { _, dragging in
            // A drag the system cancelled (no `onEnded`): settle back.
            if !dragging, dragOffset != 0 {
                withAnimation(.smooth) { dragOffset = 0 }
            }
        }
    }

    private func liveHeight(resting: CGFloat) -> CGFloat {
        min(max(resting - dragOffset, metrics.small * 0.8), metrics.large)
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
        // Global, so the panel's own movement doesn't feed back into the
        // translation.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                // No animation: the panel's edge stays under the finger.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dragOffset = value.translation.height }
            }
            .onEnded { value in
                let current = liveHeight(resting: resting)
                // Where the panel would come to rest, then the nearest snap point.
                let projected = resting - value.predictedEndTranslation.height
                let target = MapSheetDetent.allCases.min {
                    abs(metrics.height(for: $0) - projected) < abs(metrics.height(for: $1) - projected)
                } ?? detent
                // Carry the finger's speed into the spring: SwiftUI's initial
                // velocity is in units of the whole distance per second.
                let distance = metrics.height(for: target) - current
                let speed = -value.velocity.height
                let initialVelocity = abs(distance) > 1 ? min(max(speed / distance, -20), 20) : 0
                withAnimation(.interpolatingSpring(duration: 0.35, bounce: 0.05, initialVelocity: initialVelocity)) {
                    detent = target
                    dragOffset = 0
                }
            }
    }
}

/// The panel's content area. While a drag is under way it's laid out once at
/// `fixedHeight` (the large size) and clipped by the panel, rather than laid
/// out again at every frame's height; otherwise it fills the panel.
private struct MapSheetContentFrame<Content: View>: View {
    let fixedHeight: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        // One chain (no branch), so the content keeps its identity and its
        // scroll position when a drag starts and ends.
        content
            .frame(maxWidth: .infinity)
            .frame(height: fixedHeight, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The panel's snap heights for the space it has (design §4.7). The list and
/// a place card share them, so a card opens at the list's size and Back
/// returns to it:
///
/// - **small:** collapsed: just the header, or for a card its name and round
///   buttons (`pinned`).
/// - **medium:** about 60% of the space between the search field and the tab
///   bar: the header and 5–6 rows, with the map above. The list rests here.
/// - **large:** for the list, up to the search field; for a place card, almost
///   the whole screen, leaving a strip of map (`cardMapStrip`) above it for
///   the place's pin. The search field and map buttons step aside for it.
struct MapSheetMetrics: Equatable {
    static let sideInset: CGFloat = 8
    static let bottomGap: CGFloat = 8
    /// Space left between the large list and the search bar.
    static let topGap: CGFloat = 8
    static let grabberHeight: CGFloat = 20
    /// Share of the space under the search field the panel rests at.
    static let restingShare: CGFloat = 0.6
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
    ///   - pinned: what else shows when collapsed: a card's round buttons.
    ///   - isCard: whether the panel shows a place card.
    init(screen: CGFloat, belowSearch: CGFloat, header: CGFloat, pinned: CGFloat = 0, isCard: Bool) {
        let available = max(screen - belowSearch, 240)
        let listLarge = max(available - Self.topGap - Self.bottomGap, 200)
        let small = min(max(Self.grabberHeight + header + pinned + Theme.grid, 88), listLarge * 0.45)
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
        case .medium: "Medium height"
        case .large: "Full height"
        }
    }
}
