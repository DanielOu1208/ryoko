import SwiftUI

// The Live Activity's views (design §4.11, §9): monochrome, system type, SF
// Symbols. They take plain values, not an `ActivityViewContext`, so the app's
// DEBUG gallery (`LiveActivityGallery`) can show them too; the extension wraps
// them in `ActivityConfiguration` and adds the `widgetURL`.

/// The lock screen (and banner): place name, the place's local time, and the
/// top phrase in local script with its gloss.
struct ActivityLockScreenView: View {
    let attributes: RyokoActivityAttributes
    let state: RyokoActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityHeader(attributes: attributes, state: state)
            ActivityPhraseLines(state: state, style: .lockScreen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// The category symbol, the place and what it is to you (here, or a preview at
/// a time), and the clock in the place's time zone.
struct ActivityHeader: View {
    let attributes: RyokoActivityAttributes
    let state: RyokoActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: attributes.categorySymbol)
                .font(.headline)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.placeName)
                    .font(.headline)
                    .lineLimit(1)
                Text(ActivityFormat.situationLine(attributes, state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                ActivityClock(timeZoneID: attributes.timeZoneID)
                    .font(.headline)
                    .monospacedDigit()
                Text(attributes.city)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Local time in \(attributes.city)"))
            .accessibilityValue(Text(.currentDate, format: ActivityFormat.clockStyle(attributes.timeZoneID)))
            .environment(\.timeZone, ActivityFormat.zone(attributes.timeZoneID))
        }
    }
}

/// The phrase: local script first, then the gloss (design §9.6). A placeholder
/// while the place card loads; a short note if it couldn't.
struct ActivityPhraseLines: View {
    enum Style {
        case lockScreen
        case island
    }

    let state: RyokoActivityAttributes.ContentState
    var style: Style = .lockScreen

    var body: some View {
        Group {
            if let phrase = state.phrase {
                VStack(alignment: .leading, spacing: 2) {
                    ActivityLocalText(phrase.local, languageTag: phrase.lang)
                        .font(localFont)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(phrase.gloss)
                        .font(glossFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if state.isLoading {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A phrase for this place")
                        .font(localFont)
                    Text("What it means, in your language")
                        .font(glossFont)
                }
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading a phrase")
            } else {
                Text("Open Ryoko for what to say here")
                    .font(glossFont)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localFont: Font {
        switch style {
        case .lockScreen: .title3.weight(.semibold)
        case .island: .headline
        }
    }

    private var glossFont: Font {
        switch style {
        case .lockScreen: .subheadline
        case .island: .caption
        }
    }
}

/// The place's local time, kept current by the system (a Live Activity's view
/// is otherwise only redrawn when the app updates it).
///
/// `Text(.currentDate, format:)` formats in the environment's time zone and
/// ignores the style's own (checked in the iOS 27 simulator: Tokyo showed the
/// device's time), so the zone goes into the environment too.
struct ActivityClock: View {
    let timeZoneID: String

    var body: some View {
        Text(.currentDate, format: ActivityFormat.clockStyle(timeZoneID))
            .environment(\.timeZone, ActivityFormat.zone(timeZoneID))
    }
}

/// Local script tagged with its language (design §7.9), so Chinese and Japanese
/// get the right glyphs and VoiceOver reads them in that language. The app's
/// `LocalText` does the same; it isn't in the extension.
struct ActivityLocalText: View {
    private let text: String
    private let languageTag: String

    init(_ text: String, languageTag: String) {
        self.text = text
        self.languageTag = languageTag
    }

    var body: some View {
        let tag = LangCode(tag: languageTag)?.tag ?? languageTag
        var attributed = AttributedString(text)
        attributed.languageIdentifier = tag
        return Text(attributed)
            .typesettingLanguage(Locale.Language(identifier: tag))
    }
}

nonisolated enum ActivityFormat {
    /// The place's time zone, or the device's for an unknown identifier.
    static func zone(_ timeZoneID: String) -> TimeZone {
        TimeZone(identifier: timeZoneID) ?? .current
    }

    /// `7:42 PM` in the place's zone.
    static func clockStyle(_ timeZoneID: String) -> Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone(timeZoneID)
        return style
    }

    /// "Previewing · Sat 7:00 PM" (the committed time, in the place's zone), or
    /// "You're here" for the live place.
    static func situationLine(
        _ attributes: RyokoActivityAttributes,
        _ state: RyokoActivityAttributes.ContentState
    ) -> String {
        guard attributes.isPreview else { return "You're here" }
        guard let date = state.previewDate else { return "Previewing" }
        var style = Date.FormatStyle().weekday(.abbreviated).hour().minute()
        style.timeZone = zone(attributes.timeZoneID)
        return "Previewing · \(date.formatted(style))"
    }
}

#if DEBUG
/// Sample activities for SwiftUI previews and the app's DEBUG gallery. Typed by
/// hand, matching the contract fixtures.
nonisolated enum ActivitySamples {
    static let tokyo = RyokoActivityAttributes(
        placeName: "Menya Kaze",
        city: "Tokyo",
        categorySymbol: CategorySlug.ramen.sfSymbol,
        timeZoneID: "Asia/Tokyo",
        isPreview: true
    )

    static let shanghai = RyokoActivityAttributes(
        placeName: "Heytea (Jing'an Kerry Centre)",
        city: "Shanghai",
        categorySymbol: CategorySlug.tea.sfSymbol,
        timeZoneID: "Asia/Shanghai",
        isPreview: false
    )

    static let tokyoPhrase = ActivityPhrase(
        id: "pc-tk-1",
        lang: "ja",
        local: "すみません、食券の買い方を教えてください。",
        gloss: "Excuse me, could you show me how to buy a meal ticket?"
    )

    static let shanghaiPhrase = ActivityPhrase(
        id: "pc-sh-1",
        lang: "zh-Hans",
        local: "一杯招牌拿铁，少糖。",
        gloss: "One house latte, less sugar."
    )

    /// 7 PM tomorrow in Tokyo, roughly: only the weekday and time are shown.
    static let previewDate = Date(timeIntervalSinceNow: 24 * 3600)

    static let loading = RyokoActivityAttributes.ContentState.placeholder(previewDate: previewDate)
    static let tokyoReady = RyokoActivityAttributes.ContentState(phrase: tokyoPhrase, isLoading: false, previewDate: previewDate)
    static let shanghaiReady = RyokoActivityAttributes.ContentState(phrase: shanghaiPhrase, isLoading: false, previewDate: nil)
    static let unavailable = RyokoActivityAttributes.ContentState(phrase: nil, isLoading: false, previewDate: nil)
}
#endif
