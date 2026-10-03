import SwiftUI

/// "Previewing · Menya Kaze · Sun 7:00 PM" with "Back to here" (design §4.2).
/// Tapping the summary reopens the date and time picker.
///
/// At accessibility text sizes the button moves under the summary, so neither
/// gets squeezed into a narrow column and broken mid-word.
struct PreviewBanner: View {
    let situation: Situation
    let onChangeTime: () -> Void
    let onBack: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.grid * 1.5))
            : AnyLayout(HStackLayout(spacing: Theme.grid * 1.5))
        layout {
            Button(action: onChangeTime) {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint("Opens the date and time picker")

            Button("Back to here", action: onBack)
                .buttonStyle(.bordered)
                .controlSize(.small)
                // Beside the summary, never compressed; below it, free to wrap between words.
                .fixedSize(horizontal: !isLarge, vertical: false)
        }
        .cardSurface(padding: Theme.grid * 1.5)
    }

    /// The clock icon flows inline with the text, glued to "Previewing".
    private var summary: some View {
        let icon = Text(Image(systemName: "clock")).foregroundStyle(.secondary)
        return Text("\(icon)\u{00A0}\(summaryText)")
            .font(.subheadline.weight(.medium))
    }

    /// Each "·" is glued to the word before it, so no line starts with one.
    private var summaryText: String {
        [String(localized: "Previewing"), situation.place?.name, situation.nearbyClockText ?? situation.localTime]
            .compactMap(\.self)
            .joined(separator: "\u{00A0}· ")
    }

    private var accessibilitySummary: String {
        let place = situation.place.map { " \($0.name)" } ?? ""
        let time = situation.nearbyClockText ?? situation.localTime
        return String(localized: "Previewing\(place), \(time)")
    }
}

extension Situation {
    /// "Shinjuku, Tokyo": the district and city.
    var nearbyAreaText: String {
        [district, city].compactMap(\.self).joined(separator: ", ")
    }

    /// "Sun 7:00 PM" in the place's time zone, or nil if the clock doesn't parse.
    /// The time and its AM/PM are joined by a no-break space, so they never
    /// split across lines; the weekday can still wrap on its own.
    var nearbyClockText: String? {
        guard let date, let zone else { return nil }
        var full = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        full.timeZone = zone
        var time = Date.FormatStyle.dateTime.hour().minute()
        time.timeZone = zone
        let timeText = date.formatted(time)
        let gluedTime = timeText.replacing(/\s/, with: "\u{00A0}")
        return date.formatted(full).replacingOccurrences(of: timeText, with: gluedTime)
    }
}
