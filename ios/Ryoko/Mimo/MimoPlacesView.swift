import SwiftUI

/// The places from one `show_places` call (design §4.9): a chip per place the
/// device found, with Mimo's one-line why, then Show on map. A plan's stops are
/// numbered and carry their suggested times. Names the map didn't find are
/// dropped silently.
struct MimoPlacesView: View {
    let places: MimoPlaces
    var onSelect: (MimoFoundPlace) -> Void
    var onShowOnMap: () -> Void

    var body: some View {
        if let found = places.found {
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, place in
                        if places.isPlan {
                            MimoPlanStop(number: place.shown.order ?? index + 1, shown: place.shown, language: places.language) {
                                onSelect(place)
                            }
                        } else {
                            MimoPlaceChip(shown: place.shown, category: place.place.category, language: places.language) {
                                onSelect(place)
                            }
                        }
                    }
                    Button(action: onShowOnMap) {
                        // The tint is the primary label colour (white in dark
                        // mode), so the label takes the background colour.
                        Label("Show on map", systemImage: "map")
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .padding(.top, Theme.grid / 2)
                        .accessibilityHint(places.isPlan ? "Shows the stops as numbered pins on the map" : "Shows these places on the map")
                }
            }
        } else {
            // Looking the names up on the map.
            VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
                ForEach(Array(places.lookupOrder.enumerated()), id: \.offset) { index, shown in
                    if places.isPlan {
                        MimoPlanStop(number: shown.order ?? index + 1, shown: shown, language: places.language, action: {})
                    } else {
                        MimoPlaceChip(shown: shown, category: .other, language: places.language, action: {})
                    }
                }
            }
            .redacted(reason: .placeholder)
            .disabled(true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Finding places on the map")
        }
    }
}

/// A place as a capsule chip, with Mimo's why under it. Tapping it opens the Map
/// on that place.
private struct MimoPlaceChip: View {
    let shown: ShownPlace
    let category: CategorySlug
    let language: String?
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid / 2) {
            Button(action: action) {
                Label {
                    Text(shown.name)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: category.sfSymbol)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityHint("Opens the map on this place")
            MimoPlaceDetail(shown: shown, language: language)
                .padding(.leading, Theme.grid * 1.5)
        }
    }
}

/// One numbered stop of a plan: the number, the suggested local time, the
/// place's chip and why.
private struct MimoPlanStop: View {
    let number: Int
    let shown: ShownPlace
    let language: String?
    var action: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var badgeSize: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.grid * 1.5) {
            Text(number, format: .number)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(minWidth: badgeSize, minHeight: badgeSize)
                .background(Circle().fill(.primary))
                .accessibilityLabel("Stop \(number)")
            VStack(alignment: .leading, spacing: Theme.grid / 2) {
                if let when = shown.when {
                    Text(MimoPlanStop.clock(when))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Button(action: action) {
                    Text(shown.name)
                        .multilineTextAlignment(.leading)
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityHint("Opens the map on this stop")
                MimoPlaceDetail(shown: shown, language: language)
                    .padding(.leading, Theme.grid * 1.5)
            }
        }
    }

    /// `HH:mm` (local to the place) in the reader's clock style, e.g. "3:00 PM".
    /// The time is never converted between zones.
    static func clock(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return hhmm }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: parts[0], minute: parts[1])) else {
            return hhmm
        }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}

/// The local-script name, when there is one, and Mimo's why.
private struct MimoPlaceDetail: View {
    let shown: ShownPlace
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let localName = shown.localName, localName != shown.name, let language {
                LocalText(localName, languageTag: language)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(shown.why)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
