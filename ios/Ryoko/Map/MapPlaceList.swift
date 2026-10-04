import SwiftUI

// MARK: - Header

/// Where you are, on top of the list (design §4.7):
///
/// - **At a place:** "You're at Menya Kaze ›" with "Shinjuku, Tokyo · Sun
///   7:04 PM". Tapping it opens that place's card.
/// - **No place yet** (city only, or nothing): "Near you" with the city and
///   time, or what live mode is doing.
/// - **Previewing:** the previewed place and its committed time, with a small
///   Previewing badge and a small Back to here. Tapping it opens its card.
///
/// Live, the clock ticks by the minute in the place's time zone.
struct MapListHeader: View {
    let situation: Situation?
    let liveState: AppSituationStore.LiveState
    let onOpenPlace: () -> Void
    let onRefresh: () -> Void
    let onBackToHere: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The control sits beside the title, so the subtitle gets the full width.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 4) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.grid))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.grid * 1.5))
                layout {
                    tappable(title)
                    trailingControl
                }
                tappable(subtitle(at: context.date))
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, Theme.grid * 1.5)
    }

    private var isPreview: Bool { situation?.mode == .preview }
    private var place: Place? { situation?.place }

    // MARK: Summary

    /// With a place, the title and subtitle open its card.
    @ViewBuilder
    private func tappable(_ content: some View) -> some View {
        let line = content
            .frame(maxWidth: .infinity, alignment: .leading)
            // Wrap rather than truncate when the panel is short.
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
        if place != nil {
            Button(action: onOpenPlace) { line }
                .buttonStyle(MapRowButtonStyle())
                .accessibilityHint("Opens this place's card")
        } else {
            line
        }
    }

    /// "You're at Menya Kaze ›", the previewed place, or "Near you".
    private var title: some View {
        let text: String = if let place {
            isPreview ? place.name : "You're at \(place.name)"
        } else {
            "Near you"
        }
        let chevron = Text(Image(systemName: "chevron.right"))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tertiary)
        return Group {
            if place != nil {
                Text("\(text)\u{00A0}\(chevron)")
            } else {
                Text(text)
            }
        }
        .font(.headline)
        .lineLimit(2)
    }

    @ViewBuilder
    private func subtitle(at date: Date) -> some View {
        if let situation {
            // Live, the clock ticks; a preview keeps its committed time.
            let clocked = isPreview ? situation : situation.stamped(at: date)
            let text = [situation.mapAreaText, clocked.mapClockText()]
                .compactMap(\.self)
                .filter { !$0.isEmpty }
                .joined(separator: "\u{00A0}· ")
            // The badge goes above the text at accessibility sizes, so the
            // text keeps the full width.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.grid / 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.grid * 0.75))
            layout {
                if isPreview { PreviewingBadge() }
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        } else if let status {
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var status: String? {
        switch liveState {
        case .locating, .searching: "Finding where you are"
        case .denied: "Location is off"
        case .failed: "Can't find where you are"
        case .idle, .ready: nil
        }
    }

    // MARK: Trailing

    @ViewBuilder
    private var trailingControl: some View {
        if isPreview {
            Button("Back to here", action: onBackToHere)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
                .accessibilityHint("Ends the preview")
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

/// A small, quiet "Previewing" capsule (design §4.7: preview is subtle).
struct PreviewingBadge: View {
    var body: some View {
        Text("\(Image(systemName: "clock"))\u{00A0}Previewing")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .fixedSize()
    }
}

// MARK: - List

/// Mimo picks first, then the nearest places (design §4.7), each section in
/// one solid card. Tapping a row opens that place's card; nothing else
/// changes.
struct MapPlaceList: View {
    let picks: MapHomeModel.PicksState
    let nearby: MapHomeModel.NearbyState
    /// BCP-47 tag for local names.
    let languageTag: String?
    let hasSituation: Bool
    let liveState: AppSituationStore.LiveState
    let onSelect: (MapPlace) -> Void
    let onRetryPicks: () -> Void
    let onFindMe: () -> Void

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
            .padding(.bottom, Theme.grid * 3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .debugLaunchScrollAnchor()
    }

    // MARK: Mimo picks

    @ViewBuilder
    private var picksSection: some View {
        let places = picks.places
        if !(isLoaded(picks) && places.isEmpty) {
            HStack(spacing: Theme.grid) {
                MimoAvatarView(mood: places.isEmpty && !isLoaded(picks) ? .thinking : .idle, size: 26)
                Text("Mimo picks")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, Theme.grid / 2)
            .padding(.bottom, Theme.grid)

            MapListCard {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    if index > 0 { MapListDivider() }
                    MapPlaceRow(place: place, languageTag: languageTag) { onSelect(place) }
                }
                switch picks {
                case let .loading(found) where found.count < 2:
                    if !found.isEmpty { MapListDivider() }
                    placeholderRows(found.isEmpty ? 3 : 1, why: true)
                case let .failed(message):
                    VStack(alignment: .leading, spacing: Theme.grid) {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Try again", action: onRetryPicks)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MapListLayout.inset)
                default:
                    EmptyView()
                }
            }
        }
    }

    // MARK: Nearest places

    @ViewBuilder
    private var nearbySection: some View {
        let pickIDs = Set(picks.places.map(\.id))
        let places = nearby.places.filter { !pickIDs.contains($0.id) }
        Text("Nearby")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Theme.margin)
            .padding(.top, picks.places.isEmpty && isLoaded(picks) ? Theme.grid / 2 : Theme.grid * 3)
            .padding(.bottom, Theme.grid)
        MapListCard {
            switch nearby {
            case .idle, .loading:
                placeholderRows(3, why: false)
            case let .failed(message):
                note(message)
            case .loaded:
                if places.isEmpty {
                    note("No places within \(Int(MapHome.nearbyRadius)) m.")
                }
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    if index > 0 { MapListDivider() }
                    MapPlaceRow(place: place, languageTag: languageTag) { onSelect(place) }
                }
            }
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
                Button("Find places near me", systemImage: "location", action: onFindMe)
                    .buttonStyle(.monochromeProminent)
                Text("Or search, or long-press the map to look around.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, Theme.grid)
    }

    // MARK: Pieces

    private func placeholderRows(_ count: Int, why: Bool) -> some View {
        ForEach(0..<count, id: \.self) { index in
            if index > 0 { MapListDivider() }
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
                    source: why ? .pick(why: "A short line on why it fits you", bestTime: nil) : .nearby,
                    distanceMeters: 300
                ),
                languageTag: nil,
                onSelect: {}
            )
            .redacted(reason: .placeholder)
            .disabled(true)
            .accessibilityHidden(true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MapListLayout.inset)
    }

    private func isLoaded(_ state: MapHomeModel.PicksState) -> Bool {
        if case .loaded = state { true } else { false }
    }
}

/// Spacing for the panel's cards.
enum MapListLayout {
    /// Inside a card: a row's side padding.
    static let inset: CGFloat = Theme.grid * 2
    /// A card's side margin inside the panel; with the panel's own inset it
    /// lines up with the page margin.
    static let sideMargin: CGFloat = Theme.margin - MapSheetMetrics.sideInset
}

/// One solid, rounded card of rows on the panel (design §9.4).
struct MapListCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: Theme.cardShape)
        .padding(.horizontal, MapListLayout.sideMargin)
    }
}

/// A row separator, inset past the row's icon.
struct MapListDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, MapListLayout.inset + MapPlaceRow.iconColumn + Theme.grid * 1.5)
    }
}

// MARK: - Row

/// One place in two lines: the name with its local name, then Mimo's why
/// (picks, with the distance at the side) or the category and distance.
/// Tapping it opens the place's card.
struct MapPlaceRow: View {
    static let iconColumn: CGFloat = 36

    let place: MapPlace
    let languageTag: String?
    let onSelect: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = MapPlaceRow.iconColumn
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
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
            .padding(.horizontal, MapListLayout.inset)
            .padding(.vertical, Theme.grid * 1.5)
            .contentShape(.rect)
        }
        .buttonStyle(MapRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this place's card")
    }

    /// "Omoide Yokocho 思い出横丁": the local name follows in secondary,
    /// tagged with its language, when both fit on one line. Otherwise just the
    /// name (the card always shows the local name).
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

/// A plain row that dims while pressed, like a list row's highlight.
struct MapRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
