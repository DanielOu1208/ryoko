import SwiftUI

// MARK: - Header

/// "Near you · Shinjuku, Tokyo · 3:04 PM", or "Previewing · Menya Kaze ·
/// Sun 7:00 PM" with Back to here (design §4.7). Live, the clock ticks by the
/// minute in the place's time zone.
struct MapListHeader: View {
    let situation: Situation?
    let liveState: AppSituationStore.LiveState
    let onRefresh: () -> Void
    let onBackToHere: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.everyMinute) { context in
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.grid))
                : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.grid * 1.5))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle = subtitle(at: context.date) {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Wrap rather than truncate when the panel is short.
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                trailingControl
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, Theme.grid * 1.5)
    }

    private var isPreview: Bool { situation?.mode == .preview }

    private var title: String {
        isPreview ? "Previewing" : "Near you"
    }

    /// Joined with "·", each glued to the word before it.
    private func subtitle(at date: Date) -> String? {
        guard let situation else {
            switch liveState {
            case .locating, .searching: return "Finding where you are"
            case .denied: return "Location is off"
            case .failed: return "Can't find where you are"
            case .idle, .ready: return nil
            }
        }
        if situation.mode == .preview {
            return [situation.place?.name ?? situation.city, situation.mapClockText()]
                .compactMap(\.self)
                .joined(separator: "\u{00A0}· ")
        }
        let clocked = situation.stamped(at: date)
        return [situation.mapAreaText, clocked.mapClockText()]
            .compactMap(\.self)
            .joined(separator: "\u{00A0}· ")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isPreview {
            Button("Back to here", action: onBackToHere)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
        } else if situation != nil || liveState == .ready {
            Button("Check again", systemImage: "arrow.clockwise", action: onRefresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(liveState.isBusy)
        }
    }
}

// MARK: - List

/// Mimo picks first, then the nearest places (design §4.7). Tapping a row
/// makes it the current place; the info button opens its details here.
struct MapPlaceList: View {
    let picks: MapHomeModel.PicksState
    let nearby: MapHomeModel.NearbyState
    /// BCP-47 tag for local names.
    let languageTag: String?
    let hasSituation: Bool
    let liveState: AppSituationStore.LiveState
    let onSelect: (MapPlace) -> Void
    let onDetails: (MapPlace) -> Void
    let onRetryPicks: () -> Void
    let onFindMe: () -> Void
    /// Where the third row ends, from the top of the list: the collapsed
    /// sheet shows that much.
    var onThreeRowsHeight: (CGFloat) -> Void = { _ in }

    private static let space = "ryoko.map.list"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if hasSituation {
                    picksSection
                    nearbySection
                } else {
                    locationPrompt
                }
            }
            .coordinateSpace(.named(Self.space))
            .padding(.bottom, Theme.grid * 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .debugLaunchScrollAnchor()
    }

    // MARK: Mimo picks

    @ViewBuilder
    private var picksSection: some View {
        let places = picks.places
        if !(isLoaded(picks) && places.isEmpty) {
            sectionTitle("Mimo picks")
        }
        ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
            row(place, index: index)
        }
        switch picks {
        case let .loading(found) where found.count < 2:
            placeholderRows(found.isEmpty ? 3 : 1, firstIndex: found.count)
        case let .failed(message):
            VStack(alignment: .leading, spacing: Theme.grid) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try again", action: onRetryPicks)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, Theme.grid)
        default:
            EmptyView()
        }
    }

    // MARK: Nearest places

    @ViewBuilder
    private var nearbySection: some View {
        let pickIDs = Set(picks.places.map(\.id))
        let places = nearby.places.filter { !pickIDs.contains($0.id) }
        sectionTitle("Nearby")
            .padding(.top, picks.places.isEmpty ? 0 : Theme.grid)
        switch nearby {
        case .idle, .loading:
            placeholderRows(3, firstIndex: rowsAbove)
        case let .failed(message):
            note(message)
        case .loaded:
            if places.isEmpty {
                note("No places within \(Int(MapHome.nearbyRadius)) m.")
            }
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                row(place, index: rowsAbove + index)
            }
        }
    }

    /// Rows in the picks section (placeholders included).
    private var rowsAbove: Int {
        switch picks {
        case let .loading(found) where found.count < 2: found.count + (found.isEmpty ? 3 : 1)
        default: picks.places.count
        }
    }

    // MARK: No location

    @ViewBuilder
    private var locationPrompt: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
            switch liveState {
            case .locating, .searching:
                ProgressView()
            case .denied:
                Text("Turn on location for Ryoko in Settings to see places near you. You can still search, or long-press the map to look around.")
                    .foregroundStyle(.secondary)
            case .failed, .idle, .ready:
                Text("See Mimo picks and the places around you.")
                    .foregroundStyle(.secondary)
                Button(action: onFindMe) {
                    Label("Find places near me", systemImage: "location")
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                .buttonStyle(.borderedProminent)
                Text("Or search, or long-press the map to look around.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, Theme.grid)
    }

    // MARK: Pieces

    private func row(_ place: MapPlace, index: Int) -> some View {
        VStack(spacing: 0) {
            MapPlaceRow(
                place: place,
                languageTag: languageTag,
                onSelect: { onSelect(place) },
                onDetails: { onDetails(place) }
            )
            Divider()
                .padding(.leading, Theme.margin + MapPlaceRow.iconColumn + Theme.grid * 1.5)
        }
        .modifier(ThirdRowBottom(index: index, space: Self.space, report: onThreeRowsHeight))
    }

    private func placeholderRows(_ count: Int, firstIndex: Int) -> some View {
        ForEach(0..<count, id: \.self) { offset in
            let index = firstIndex + offset
            MapPlaceRow(
                place: MapPlace(
                    place: Place(
                        id: "placeholder-\(index)",
                        name: "A place nearby",
                        localName: nil,
                        category: .other,
                        address: nil,
                        coordinate: Coordinate(lat: 0, lon: 0)
                    ),
                    source: .pick(why: "A short line on why it fits you", bestTime: nil),
                    distanceMeters: 300
                ),
                languageTag: nil,
                onSelect: {},
                onDetails: {}
            )
            .redacted(reason: .placeholder)
            .disabled(true)
            .accessibilityHidden(true)
            .modifier(ThirdRowBottom(index: index, space: Self.space, report: onThreeRowsHeight))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, Theme.margin)
            .padding(.top, Theme.grid)
            .padding(.bottom, Theme.grid / 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, Theme.grid)
    }

    private func isLoaded(_ state: MapHomeModel.PicksState) -> Bool {
        if case .loaded = state { true } else { false }
    }
}

// MARK: - Row

/// One place in two lines, so about three fit in the collapsed sheet: the
/// name with its local name, then Mimo's why (picks, with the distance at the
/// side) or the category and distance. The row makes the place current; the
/// info button opens its details.
struct MapPlaceRow: View {
    static let iconColumn: CGFloat = 36

    let place: MapPlace
    let languageTag: String?
    var selectHint = "Makes this your place and opens Nearby"
    let onSelect: () -> Void
    let onDetails: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = MapPlaceRow.iconColumn
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .center, spacing: Theme.grid) {
            Button(action: onSelect) {
                HStack(alignment: .center, spacing: Theme.grid * 1.5) {
                    if !isLarge {
                        Image(systemName: place.place.category.sfSymbol)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: iconSize, height: iconSize)
                            .background(.quaternary, in: Circle())
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        titleLine
                        Text(secondLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(isLarge ? nil : 2)
                        if isLarge, place.why != nil, let distance = place.distanceMeters {
                            Text(MapDistanceText.text(distance))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    if !isLarge, place.why != nil, let distance = place.distanceMeters {
                        Text(MapDistanceText.text(distance))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(MapRowButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint(selectHint)

            Button("Details for \(place.title)", systemImage: "info.circle", action: onDetails)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
        }
        .padding(.leading, Theme.margin)
        .padding(.trailing, Theme.margin - Theme.grid / 2)
        .padding(.vertical, Theme.grid)
    }

    /// "Omoide Yokocho 思い出横丁": the local name follows in secondary,
    /// tagged with its language, when both fit on one line. Otherwise just the
    /// name (details always shows the local name).
    @ViewBuilder
    private var titleLine: some View {
        let name = Text(place.title).font(.body.weight(.medium)).foregroundStyle(.primary)
        if let localName, let languageTag {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.grid * 0.75) {
                    name
                    LocalText(localName, languageTag: languageTag)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
                name
            }
        } else {
            name
        }
    }

    /// Shown only when it adds something: not when it's the name again.
    private var localName: String? {
        guard let local = place.place.localName, local != place.title, local != place.place.name else { return nil }
        return local
    }

    /// Mimo's why for picks; otherwise "Ramen · 350 m".
    private var secondLine: String {
        if let why = place.why { return why }
        var parts = [place.place.category.displayName]
        if let distance = place.distanceMeters { parts.append(MapDistanceText.text(distance)) }
        return parts.joined(separator: "\u{00A0}· ")
    }
}

/// Reports where the third row (index 2) ends in the list's space.
private struct ThirdRowBottom: ViewModifier {
    let index: Int
    let space: String
    let report: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if index == 2 {
            content.onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(space)).maxY
            } action: { bottom in
                report(bottom)
            }
        } else {
            content
        }
    }
}

/// A plain row that dims while pressed, like a list row's highlight.
private struct MapRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
